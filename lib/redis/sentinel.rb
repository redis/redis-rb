class Redis
  class Sentinel
    RECONNECT_WAIT_SECONDS = 0.01
    RECONNECT_TIMEOUT_SECONDS = 0.1
    FAILOVER_TIMEOUT_SECONDS = 0.5
    MAX_RETRIES = 5

    CHECK_FOR_NEW_HOSTS_INTERVAL = 10

    def initialize(sentinels_config, options = {})
      @reconnect_timeout = options.delete(:reconnect_timeout) || RECONNECT_TIMEOUT_SECONDS
      @reconnect_wait = options.delete(:reconnect_wait) || RECONNECT_WAIT_SECONDS
      @failover_timeout = options.delete(:failover_timeout) || FAILOVER_TIMEOUT_SECONDS
      @check_for_new_hosts_interval = options.delete(:check_new_hosts_interval) || CHECK_FOR_NEW_HOSTS_INTERVAL
      @max_reties = options.delete(:max_reties) || MAX_RETRIES

      @last_slave_check_time = 0
      @last_master_check_time = 0

      @master_name = options.delete(:master_name)
      @logger = options[:logger]

      @default_options = options
      @sentinels_config = []
      set_defaults
      sentinels_config.each { |sentinel_config| add_sentinel_config(sentinel_config) }
    end

    def quit
      @master_connection = nil if @master_connection
      @slaves_connections = [] unless @slaves_connections.empty?
      @sentinels_connection = nil if @sentinels_connection
      set_defaults
      nil
    end

    def set(*args, &block)
      auto_retry_with_timeout(:master) do
        master.set(*args, &block)
      end
    end

    def setnx(*args, &block)
      auto_retry_with_timeout(:master) do
        master.setnx(*args, &block)
      end
    end

    def setex(*args, &block)
      auto_retry_with_timeout(:master) do
        master.setex(*args, &block)
      end
    end

    class << self
      private

      def send_to_slave(command)
        class_eval <<-EOS
          def #{command}(*args, &block)
            auto_retry_with_timeout(:slave) do
              slave.#{command}(*args, &block)
            end
          end
        EOS
      end

      def send_to_master(command)
        class_eval <<-EOS
          def #{command}(*args, &block)
            auto_retry_with_timeout(:master) do
              master.#{command}(*args, &block)
            end
          end
        EOS
      end

      def register_read_commands
        command_list = %w( dbsize exists get getbit getrange hexists hget hgetall hkeys hlen hmget hvals keys lindex
                           llen lrange mget randomkey scard sdiff sinter sismember smembers sort srandmember strlen
                           sunion ttl type zcard zcount zrange zrangebyscore zrank zrevrange zscore [] )
        command_list.each do |command|
          send_to_slave command
        end
        nil
      end
    end

    register_read_commands

    # Send everything else to master.
    def method_missing(name, *args, &block) # :nodoc:
      if master.respond_to?(name)
        Sentinel.send(:send_to_master, name)
        send(name, *args, &block)
      else
        super
      end
    end

    def master
      unless @master_connection
        discover_master
      end
      log("Using master #{@master_connection}")
      return @master_connection
    end

    def slave
      _slave = nil
      unless @slaves_connections.empty?
        _slave = get_next_slave_connection
      else
        discover_slaves
        _slave = get_next_slave_connection
      end
      log("Using slave #{_slave}")
      return _slave
    end

    private

    def set_defaults
      @sentinels_connection = nil
      @master_connection = nil
      @slaves_connections = []
      nil
    end

    def auto_retry_with_timeout(type, &block)
      case type
        when :slave
          if Time.now.to_f - @check_for_new_hosts_interval.to_f > @last_slave_check_time
            discover_slaves
            @last_slave_check_time = Time.now.to_f
          end
        when :master
          if Time.now.to_f - @check_for_new_hosts_interval.to_f > @last_master_check_time
            discover_master
            @last_master_check_time = Time.now.to_f
          end
      end
      deadline = @reconnect_timeout.to_f + Time.now.to_f
      begin
        return block.call
      rescue Redis::CannotConnectError => e
        raise e if Time.now.to_f > deadline
        sleep @reconnect_wait
        case type
          when :slave
            discover_slaves
          when :master
            discover_master
        end
        retry
      end
      nil
    end

    def add_sentinel_config(sentinel_config)
      @sentinels_config << sentinel_config
      @sentinels_config.uniq!
      nil
    end

    def connect_to_next_sentinel
      if @sentinels_connection
        @sentinels_connection.quit
        @sentinels_connection = nil
      end
      options = get_next_sentinel_config
      options = { :url => options } if options.is_a?(String)
      options = @default_options.merge(options)
      options.delete(:db)
      @sentinels_connection = Redis.new(options)
      nil
    end

    def get_next_sentinel_config
      return get_next_element(:@sentinels_config)
    end

    def get_next_slave_connection
      return get_next_element(:@slaves_connections)
    end

    def get_next_element instance_variable_name
      tmp_conf = instance_variable_get(instance_variable_name)
      next_element = tmp_conf.shift
      tmp_conf.push next_element
      return next_element
    end

    def get_master_config
      raise Redis::NotConnectedToSentinels.new unless @sentinels_connection
      masters = @sentinels_connection.sentinel('masters')
      master_config = Hash[*masters.rassoc(@master_name)]
      if master_config.empty?
        raise Redis::NoAvailableMasters.new(@master_name)
      end
      is_down, run_id = @sentinels_connection.sentinel('is-master-down-by-addr', master_config['ip'], master_config['port'])
      if is_down == 1 || run_id == '?'
        raise Redis::MasterIsDown.new(master_config['ip'], master_config['port'])
      end
      return master_config
    end

    def get_slaves_config
      raise Redis::NotConnectedToSentinels.new unless @sentinels_connection
      slaves = @sentinels_connection.sentinel('slaves', @master_name)

      slaves.map! do |slave|
        if slave[9] == 'slave'
          Hash[*slave]
        else
          nil
        end
      end.compact!

      if slaves.empty?
        return [get_master_config]
      end

      return slaves
    end

    def discover_master
      master_config = {}
      if @master_connection
        begin
          @master_connection.quit
        rescue Redis::CannotConnectError
        end
        @master_connection = nil
      end
      loop do
        @rescue_counter = 0
        begin
          connect_to_next_sentinel
          master_config = get_master_config
        rescue Redis::NotConnectedToSentinels
          retry
        rescue Redis::MasterIsDown => e
          if @rescue_counter <= @max_reties
            @rescue_counter += 1
            sleep @failover_timeout
            log("Retying to reconnect to Master host: [#{e.host}] port: [#{e.port}] after sleep of #{@failover_timeout} seconds")
            retry
          else
            log('Retry failed')
            raise e
          end
        else
          @master_connection = Redis.new(@default_options.merge({:host => master_config['ip'], :port => master_config['port']}))
          break
        end
      end
      nil
    end

    def discover_slaves
      slaves_config = []
      @slaves_connections.each do |conn|
        begin
          conn.quit
        rescue Redis::CannotConnectError
        end
      end
      @slaves_connections = []
      loop do
        @rescue_counter = 0
        begin
          connect_to_next_sentinel
          slaves_config = get_slaves_config
        rescue Redis::NotConnectedToSentinels
          retry
        rescue Redis::MasterIsDown => e
          if @rescue_counter <= @max_reties
            log(e.message)
            @rescue_counter += 1
            sleep @failover_timeout
            log("Retying to reconnect to Master host: [#{e.host}] port: [#{e.port}] after sleep of #{@failover_timeout} seconds")
            retry
          end
          log('Retry failed')
          raise e
        else
          slaves_config.each do |slave_config|
            @slaves_connections << Redis.new(@default_options.merge({:host => slave_config['ip'], :port => slave_config['port']}))
          end
          break
        end
      end
      nil
    end

    def log(message)
      if @logger && @logger.debug?
        @logger.debug("#{message}")
      end
      nil
    end

  end
end