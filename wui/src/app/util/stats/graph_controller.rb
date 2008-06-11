require 'util/stats/Stats'

class GraphController < ApplicationController
  layout nil

  # generate layout for avaialability bar graphs
  def availability_graph
    @id = params[:id]
    @target = params[:target]

    # TODO: make this configurable
    aggregate_subpools = false
    if ['cpu', 'memory'].include?(@target)
      pool = HardwarePool.find(@id, :include => :hosts)
      if (aggregate_subpools)
        pools = pool.full_set({:include => :hosts, :conditions => "type='HardwarePool'"})
        vmpools = pool.full_set({:include => :vms, :conditions => "type='VmResourcePool'"})
      else
        pools = [pool]
        vmpools = pool.children({:include => :vms, :conditions => "type='VmResourcePool'"})
      end
      if @target == 'cpu'
        @label = "CPUs"
        used= vmpools.inject(0){ |sum, pool| sum+pool.allocated_resources[:current][:cpus] }
        total= pools.inject(0){ |sum, pool| sum+pool.hosts.total_cpus }
      elsif @target == 'memory'
        @label = "MB of Memory"
        used= vmpools.inject(0){ |sum, pool| sum+pool.allocated_resources[:current][:memory] }
        total= pools.inject(0){ |sum, pool| sum+pool.hosts.total_memory }
      end
    elsif ['vcpu', 'vram'].include?(@target)
      pool = VmResourcePool.find(@id)
      pools = aggregate_subpools ? pool.full_set({:include => :hosts}) : [pool]
      if @target == 'vcpu'
        @label = "VCPUs"
        resource_key = :cpus
      elsif @target == 'vram'
        @label = "MB of VMemory"
        resource_key = :memory
      end
      unlimited = false
      total=0
      used= pools.inject(0) { |sum, pool| sum+pool.allocated_resources[:current][resource_key] }
      pools.each do |pool| 
        resource = pool.total_resources[resource_key]
        if resource
          total +=resource
        else
          unlimited = true
        end
      end
      total = 0 if unlimited
    end

    # bit of a hack to convert memory from kb to mb
    if @target == 'memory' || @target == 'vram'
        used  /= 1024
        total /= 1024
    end

    @availability_graph_data = { 'Used' => used, 'Total' => total, 'Available' => total - used}
  end

  # generate layout for history graphs
  def history_graphs
    @id = params[:id]
    @poolType = params[:poolType]
    @peak_history = { :color => 'red',  :values => [], :dataPoints => [] }
    @avg_history  = { :color => 'blue', :values => [], :dataPoints => [] }
  end

  # retrieves data for history graphs
  def history_graph_data
    history_graphs
    target = params[:target]
    poolType = params[:poolType]
    devclass = DEV_KEY_CLASSES[target]
    avgcounter  = DEV_KEY_AVGCOUNTERS[target]
    peakcounter = nil
    @pool = Pool.find(@id)
    
    hosts = @pool.hosts
    # temporary workaround for vm resource history 
    # graph until we have a more reqs / long term solution
    if poolType == "vm"
        hosts = []
        @pool.vms.each { |vm|
            if !vm.host.nil?
                hosts.push vm.host
            end
        }
    end

    requestList = [ ]
    @pool.hosts.each { |host|
        if target == "cpu"
            0.upto(host.num_cpus - 1){ |x|
                requestList.push( StatsRequest.new(host.hostname, devclass, x, avgcounter, 0, 604800, RRDResolution::Medium, DataFunction::Average) ) #, # one weeks worth of data
                requestList.push( StatsRequest.new(host.hostname, devclass, x, avgcounter, 0, 604800, RRDResolution::Medium, DataFunction::Peak) ) #, # one weeks worth of data
                                  # StatsRequest.new (@pool.id.to_s, devclass, x, peakcounter, firstday.to_i - 3600, 604800, 3600))
            }
        else
            requestList.push( StatsRequest.new(host.hostname, devclass, 0, avgcounter, 0, 604800, RRDResolution::Medium, DataFunction::Average) ) #, 
            requestList.push( StatsRequest.new(host.hostname, devclass, 0, avgcounter, 0, 604800, RRDResolution::Medium, DataFunction::Peak) ) #, 
                           # StatsRequest.new (@pool.id.to_s, devclass, 0, peakcounter, firstday.to_i - 3600, 604800, 3600))
        end
    }

    times = []
    statsList = getStatsData?( requestList )
    statsList.each { |stat|
        if stat.get_status? == StatsStatus::SUCCESS
            myfunc = stat.get_function?
            counter  = stat.get_counter?
            dat = stat.get_data?
            dat.each{ |data|
                value    = data.get_value?
                value = 0 if value.nan?
                valueindex = ((data.get_timestamp?.to_i - dat[0].get_timestamp?.to_i) / 2230).to_i  # 86400 secs per day / 40 intervals per day = 2160 secs per intervals
                times.size.upto(valueindex) { |x|
                    time = Time.at(dat[0].get_timestamp?.to_i + valueindex * 2230)
                    times.push Date::ABBR_MONTHNAMES[time.month] + ' ' + time.day.to_s 
                }
                @avg_history[:values].size.upto(valueindex)  {  |x|  
                    @avg_history[:values].push 0 
                    @avg_history[:dataPoints].push 0 
                    @peak_history[:values].push 0 
                    @peak_history[:dataPoints].push 0 
                }
#                if counter == avgcounter
                if myfunc == DataFunction::Average
                    @avg_history[:values][valueindex] += value.to_i
                    @avg_history[:dataPoints][valueindex] += 1
#                elsif counter == peakcounter
                elsif myfunc == DataFunction::Peak
                    @peak_history[:values][valueindex] += value.to_i
                    @peak_history[:dataPoints][valueindex] += 1
                end
            }
        else
            RAILS_DEFAULT_LOGGER.warn("unable to find collectd/rrd stats for " + stat.get_node?.to_s)
        end
    }

    total_peak = 200 # TODO set to 0

    # avgerage out history for each day
    0.upto(@avg_history[:values].size - 1){ |x|
        (@avg_history[:values][x] /= @avg_history[:dataPoints][x]) if (@avg_history[:dataPoints][x] != 0)
        total_peak = @avg_history[:values][x] if @avg_history[:values][x] > total_peak # TODO move below, change to peak
    }
    0.upto(@peak_history[:values].size - 1){ |x|
        (@peak_history[:values][x] /= @peak_history[:dataPoints][x]) if (@peak_history[:dataPoints][x] != 0)
    }

    scale = []
    if target == "cpu"
        -5.upto(105){ |x|
            scale.push x.to_s if x % 5 == 0
        }
    elsif target == "memory"
        (@pool.hosts.total_memory / 262144).times { |x| # (1048576 kb / gb) / 4
            scale.push((x * 262144).to_s)
        }
    elsif target == "load"
        0.upto(total_peak){|x|
            scale.push x.to_s if x % 5 == 0
        }
    end

    graph_object = {
       :timepoints => times,
       :scale => scale,
       :dataset => 
        [
            {
                :name => target + "peak",
                :values => @peak_history[:values],
                :stroke => @peak_history[:color],
                :strokeWidth => 1
            },
            {
                :name => target + "average",
                :values => @avg_history[:values], 
                :stroke => @avg_history[:color],
                :strokeWidth => 1
            }
       ]
    }
    render :json => graph_object
  end


  # generate data for load graphs
  def load_graph_data
    @id     = params[:id]
    target = params[:target]

    load_value = 0
    if target == 'host'
        load_value = Host.find(@id).load_average
    elsif target == 'vm'
        load_value = Vm.find(@id).host.load_average
    elsif target == 'resource'
        VmResourcePool.find(@id).vms.each { |vm|
            load_value += vm.host.load_average
        }
    end

    if load_value.nil?
        load_value = 0
    elsif load_value > 10 # hack to cap it as we have nothing to compare against
        load_value = 10 
    end
    load_remaining = 10 - load_value
    
    graph_object = {
       :timepoints => [],
       :dataset => 
        [
            {
                :name => target,
                :values => [load_value],
                :fill => 'blue',
                :stroke => 'lightgray',
                :strokeWidth => 1
            },
            {
                :name => target + "remaining",
                :values => [load_remaining],
                :fill => 'white',
                :stroke => 'lightgray',
                :strokeWidth => 1
            }
       ]
    }
    render :json => graph_object

  end
  
  # generate layout for snapshot graphs
  def snapshot_graph
    @id = params[:id]
    @target = params[:target]
    @poolType = params[:poolType]

    @snapshots   = { :avg   => { 'load' => 0, 'cpu' => 0, 'netin' => 0, 'netout' => 0, 'memory' => 0 }, # average values to be plotted on the graph
                     :scale => { 'load' => 10, 'cpu' => 100, 'memory' => 0, 'netin' => 1000, 'netout' => 1000}, # values which to scale graphs against
                     :peak  => { 'load' => 0, 'cpu' => 0, 'netin' => 0, 'netout' => 0, 'memory' => 0 }}
    @data_points = { :avg   => { 'load' => 0, 'cpu' => 0, 'netin' => 0, 'netout' => 0, 'memory' => 0 },
                     :scale => { 'load' => 10, 'cpu' => 100, 'memory' => 0, 'netin' => 1000, 'netout' => 1000}, 
                     :peak  => { 'load' => 0, 'cpu' => 0, 'netin' => 0, 'netout' => 0, 'memory' => 0 }}


    # XXX DIRTYHACK hard-code nic bandwidth to 1000 to make graphs look decent
    # until we have real hardware discovery
    requestList = []
    if @target == 'host'
        host =  Host.find(@id)
        requestList += _create_host_snapshot_requests(host.hostname)
        @snapshots[:scale]['memory'] = host.memory_in_mb
        host.nics.each{ |nic|
            @snapshots[:scale]['netin'] += 1000
            @snapshots[:scale]['netout'] += 1000
            # @snapshots[:scale]['netin']  += nic.bandwidth 
            # @snapshots[:scale]['netout'] += nic.bandwidth
        }
    elsif @poolType == 'vm'
        Pool.find(@id).vms.each{ |vm|
            if !vm.host.nil?
                requestList += _create_host_snapshot_requests(vm.host.hostname)
                @snapshots[:scale]['memory'] = vm.host.memory_in_mb
                vm.host.nics.each{ |nic|
                    @snapshots[:scale]['netin'] += 1000
                    @snapshots[:scale]['netout'] += 1000
                    # @snapshots[:scale]['netin']  += nic.bandwidth
                    # @snapshots[:scale]['netout'] += nic.bandwidth
                }
            end
        }
    else
        Pool.find(@id).hosts.each{ |host|
            requestList += _create_host_snapshot_requests(host.hostname)
            @snapshots[:scale]['memory'] = host.memory_in_mb
            host.nics.each{ |nic|
              @snapshots[:scale]['netin'] += 1000
              @snapshots[:scale]['netout'] += 1000
              # @snapshots[:scale]['netin']  += nic.bandwidth
              # @snapshots[:scale]['netout'] += nic.bandwidth
            }
        }
    end
    
    statsList = getStatsData?( requestList )
    statsList.each { |stat|
        if stat.get_status? == StatsStatus::SUCCESS
            stat.get_data?.each{ |data|
                value = data.get_value?
                if !value.nan?
                    devClass = stat.get_devClass?
                    counter  = stat.get_counter?
                    if devClass == DEV_KEY_CLASSES["load"]
                        if counter == DEV_KEY_AVGCOUNTERS["load"]
                            @snapshots[:avg]["load"] += value.to_i
                            @data_points[:avg]["load"] += 1
                        # elsif counter == DEV_KEY_PEAKCOUNTERS["load"]
                        #    @snapshots[:peak]["load"] += value.to_i
                        #    @data_points[:peak]["load"] += 1
                        end
                    elsif devClass == DEV_KEY_CLASSES["cpu"]
                        if counter == DEV_KEY_AVGCOUNTERS["cpu"]
                            @snapshots[:avg]["cpu"] += 100 - value.to_i
                            @data_points[:avg]["cpu"] += 1
                        #elsif counter == DEV_KEY_PEAKCOUNTERS["cpu"]
                        #    @snapshots[:peak]["cpu"] =  100 - value.to_i
                        #    @data_points[:peak]["cpu"] += 1
                        end
                    elsif devClass == DEV_KEY_CLASSES["netout"]
                        if counter == DEV_KEY_AVGCOUNTERS["netout"]
                            @snapshots[:avg]["netout"] += (value.to_i * 8 / 1024 / 1024).to_i # mbits
                            @data_points[:avg]["netout"] += 1
                        #elsif counter == DEV_KEY_PEAKCOUNTERS["netout"]
                        #    @snapshots[:peak]["netout"] += (value.to_i * 8 / 1024 / 1024).to_i #mbits
                        #    @data_points[:peak]["netout"] += 1
                        elsif counter == DEV_KEY_AVGCOUNTERS["netin"]
                            @snapshots[:avg]["netin"] += (value.to_i * 8 / 1024 / 1024).to_i # mbits
                            @data_points[:avg]["netin"] += 1
                        #elsif counter == DEV_KEY_PEAKCOUNTERS["netin"]
                        #    @snapshots[:peak]["netin"] += (value.to_i * 8 / 1024 / 1024).to_i # mbits
                        #    @data_points[:peak]["netin"] += 1
                        end
                    elsif devClass == DEV_KEY_CLASSES["memory"]
                        if counter == DEV_KEY_AVGCOUNTERS["memory"]
                            @snapshots[:avg]["memory"] += (value.to_i / 1000000).to_i
                            @data_points[:avg]["memory"] += 1
                        #elsif counter == DEV_KEY_PEAKCOUNTERS["memory"]
                        #    @snapshots[:peak]["memory"] += (value.to_i / 1000000).to_i
                        #    @data_points[:peak]["memory"] += 1
                        end
                    end
                end
            }
        else
            RAILS_DEFAULT_LOGGER.warn("unable to find collectd/rrd stats for " + stat.get_node?.to_s)
        end
    }
    @snapshots[:avg]['load'] /= @data_points[:avg]['load']  if @data_points[:avg]['load'] != 0
    @snapshots[:avg]['cpu'] /= @data_points[:avg]['cpu']  if @data_points[:avg]['cpu'] != 0
    @snapshots[:avg]['memory'] /= @data_points[:avg]['memory']  if @data_points[:avg]['memory'] != 0
    @snapshots[:avg]['netin'] /= @data_points[:avg]['netin']  if @data_points[:avg]['netin'] != 0
    @snapshots[:avg]['netout'] /= @data_points[:avg]['netout']  if @data_points[:avg]['netout'] != 0
  end

  private

      DEV_KEY_CLASSES  = { 'cpu' => DevClass::CPU, 'memory' => DevClass::Memory, 'disk' => DevClass::Disk, 'load' => DevClass::Load, 'netin' => DevClass::NIC, 'netout' => DevClass::NIC }
      DEV_CLASS_KEYS   = DEV_KEY_CLASSES.invert

      # TODO this needs fixing / completing (cpu: more than user time? disk: ?, load: correct?, nics: correct?)
      DEV_KEY_AVGCOUNTERS = { 'cpu' => CpuCounter::Idle, 'memory' => MemCounter::Used, 'disk' => DiskCounter::Ops_read, 'load' => LoadCounter::Load_1min, 'netin' => NicCounter::Octets_rx, 'netout' => NicCounter::Octets_tx }
      DEV_AVGCOUNTER_KEYS = DEV_KEY_AVGCOUNTERS.invert

      # TODO 
      DEV_KEY_PEAKCOUNTERS = { 'cpu' => nil, 'memory' => nil, 'disk' => nil, 'load' => nil, 'netin' => nil, 'netout' => nil }
      DEV_PEAKCOUNTER_KEYS = DEV_KEY_PEAKCOUNTERS.invert

      def _create_host_snapshot_requests(hostname)
        requestList = []
        requestList << StatsRequest.new(hostname, DEV_KEY_CLASSES['memory'],0, DEV_KEY_AVGCOUNTERS['memory'], 0, 600, RRDResolution::Default) 
        requestList << StatsRequest.new(hostname, DEV_KEY_CLASSES['load'], 0, DEV_KEY_AVGCOUNTERS['load'], 0, 600, RRDResolution::Default) # RRDResolution::Long ?
        requestList << StatsRequest.new(hostname, DEV_KEY_CLASSES['cpu'],  0, DEV_KEY_AVGCOUNTERS['cpu'], 0, 600, RRDResolution::Default)   # TODO more than 1 cpu
        requestList << StatsRequest.new(hostname, DEV_KEY_CLASSES['netout'],0, DEV_KEY_AVGCOUNTERS['netout'], 0, 600, RRDResolution::Default) 
        requestList << StatsRequest.new(hostname, DEV_KEY_CLASSES['netin'],0, DEV_KEY_AVGCOUNTERS['netin'], 0, 600, RRDResolution::Default) 
        return requestList
      end

end
