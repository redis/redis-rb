require "redis/errors"
require "socket"
require "cgi"

class Redis
  class Client

    DEFAULTS = {
      :url => lambda { ENV["REDIS_URL"] },
      :scheme => "redis",
      :host => "127.0.0.1",
      :port => 6379,
      :path => nil,
      :timeout => 5.0,
      :password => nil,
      :db => 0,
      :driver => nil,
      :id => nil,
      :tcp_keepalive => 0,
      :reconnect_attempts => 1,
      :inherit_socket => false
    }

    def options
      Marshal.load(Marshal.dump(@options))
    end

    def scheme
      @options[:scheme]
    end

    def host
      @options[:host]
    end

    def port
      @options[:port]
    end

    def path
      @options[:path]
    end

    def timeout
      @options[:timeout]
    end

    def password
      @options[:password]
    end

    def db
      @options[:db]
    end

    def db=(db)
      @options[:db] = db.to_i
    end

    def driver
      @options[:driver]
    end

    def inherit_socket?
      @options[:inherit_socket]
    end

    attr_accessor :logger
    attr_reader :connection
    attr_reader :command_map

    def initialize(options = {})
      @options = _parse_options(options)
      @reconnect = true
      @logger = @options[:logger]
      @connection = nil
      @command_map = {}
    end

    def connect
      @pid = Process.pid

      # Don't try to reconnect when the connection is fresh
      with_reconnect(false) do
        establish_connection
        call [:auth, password] if password
        call [:select, db] if db != 0
      end

      self
    end

    def id
      @options[:id] || "redis://#{location}/#{db}"
    end

    def location
      path || "#{host}:#{port}"
    end

    def call(command, &block)
      reply = process([command]) { read }
      raise reply if reply.is_a?(CommandError)

      if block
        block.call(reply)
      else
        reply
      end
    end

    def call_loop(command)
      error = nil

      result = without_socket_timeout do
        process([command]) do
          loop do
            reply = read
            if reply.is_a?(CommandError)
              error = reply
              break
            else
              yield reply
            end
          end
        end
      end

      # Raise error when previous block broke out of the loop.
      raise error if error

      # Result is set to the value that the provided block used to break.
      result
    end

    def call_pipeline(pipeline)
      with_reconnect pipeline.with_reconnect? do
        begin
          pipeline.finish(call_pipelined(pipeline.commands)).tap do
            self.db = pipeline.db if pipeline.db
          end
        rescue ConnectionError => e
          return nil if pipeline.shutdown?
          # Assume the pipeline was sent in one piece, but execution of
          # SHUTDOWN caused none of the replies for commands that were executed
          # prior to it from coming back around.
          raise e
        end
      end
    end

    def call_pipelined(commands)
      return [] if commands.empty?

      # The method #ensure_connected (called from #process) reconnects once on
      # I/O errors. To make an effort in making sure that commands are not
      # executed more than once, only allow reconnection before the first reply
      # has been read. When an error occurs after the first reply has been
      # read, retrying would re-execute the entire pipeline, thus re-issuing
      # already successfully executed commands. To circumvent this, don't retry
      # after the first reply has been read successfully.

      result = Array.new(commands.size)
      reconnect = @reconnect

      begin
        process(commands) do
          result[0] = read

          @reconnect = false

          (commands.size - 1).times do |i|
            result[i + 1] = read
          end
        end
      ensure
        @reconnect = reconnect
      end

      result
    end

    def call_with_timeout(command, timeout, &blk)
      with_socket_timeout(timeout) do
        call(command, &blk)
      end
    rescue ConnectionError
      retry
    end

    def call_without_timeout(command, &blk)
      call_with_timeout(command, 0, &blk)
    end

    def process(commands)
      logging(commands) do
        ensure_connected do
          commands.each do |command|
            if command_map[command.first]
              command = command.dup
              command[0] = command_map[command.first]
            end

            write(command)
          end

          yield if block_given?
        end
      end
    end

    def connected?
      !! (connection && connection.connected?)
    end

    def disconnect
      connection.disconnect if connected?
    end

    def reconnect
      disconnect
      connect
    end

    def io
      yield
    rescue TimeoutError => e1
      # Add a message to the exception without destroying the original stack
      e2 = TimeoutError.new("Connection timed out")
      e2.set_backtrace(e1.backtrace)
      raise e2
    rescue Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED, Errno::EBADF, Errno::EINVAL => e
      raise ConnectionError, "Connection lost (%s)" % [e.class.name.split("::").last]
    end

    def read
      io do
        connection.read
      end
    end

    def write(command)
      io do
        connection.write(command)
      end
    end

    def with_socket_timeout(timeout)
      connect unless connected?

      begin
        connection.timeout = timeout
        yield
      ensure
        connection.timeout = self.timeout if connected?
      end
    end

    def without_socket_timeout(&blk)
      with_socket_timeout(0, &blk)
    end

    def with_reconnect(val=true)
      begin
        original, @reconnect = @reconnect, val
        yield
      ensure
        @reconnect = original
      end
    end

    def without_reconnect(&blk)
      with_reconnect(false, &blk)
    end

  protected

    def logging(commands)
      return yield unless @logger && @logger.debug?

      begin
        commands.each do |name, *args|
          logged_args = args.map do |a|
            case
            when a.respond_to?(:inspect) then a.inspect
            when a.respond_to?(:to_s)    then a.to_s
            else
              # handle poorly-behaved descendants of BasicObject
              klass = a.instance_exec { (class << self; self end).superclass }
              "\#<#{klass}:#{a.__id__}>"
            end
          end
          @logger.debug("[Redis] command=#{name.to_s.upcase} args=#{logged_args.join(' ')}")
        end

        t1 = Time.now
        yield
      ensure
        @logger.debug("[Redis] call_time=%0.2f ms" % ((Time.now - t1) * 1000)) if t1
      end
    end

    def establish_connection
      @connection = @options[:driver].connect(@options.dup)

    rescue TimeoutError
      raise CannotConnectError, "Timed out connecting to Redis on #{location}"
    rescue Errno::ECONNREFUSED
      raise CannotConnectError, "Error connecting to Redis on #{location} (ECONNREFUSED)"
    end

    def ensure_connected
      attempts = 0

      begin
        attempts += 1

        if connected?
          unless inherit_socket? || Process.pid == @pid
            raise InheritedError,
              "Tried to use a connection from a child process without reconnecting. " +
              "You need to reconnect to Redis after forking " +
              "or set :inherit_socket to true."
          end
        else
          connect
        end

        yield
      rescue ConnectionError, InheritedError
        disconnect

        if attempts <= @options[:reconnect_attempts] && @reconnect
          retry
        else
          raise
        end
      rescue Exception
        disconnect
        raise
      end
    end

    def _parse_options(options)
      defaults = DEFAULTS.dup
      options = options.dup

      defaults.keys.each do |key|
        # Fill in defaults if needed
        if defaults[key].respond_to?(:call)
          defaults[key] = defaults[key].call
        end

        # Symbolize only keys that are needed
        options[key] = options[key.to_s] if options.has_key?(key.to_s)
      end

      url = options[:url] || defaults[:url]

      # Override defaults from URL if given
      if url
        require "uri"

        uri = URI(url)

        if uri.scheme == "unix"
          defaults[:path]   = uri.path
        else
          # Require the URL to have at least a host
          raise ArgumentError, "invalid url" unless uri.host

          defaults[:scheme]   = uri.scheme
          defaults[:host]     = uri.host
          defaults[:port]     = uri.port if uri.port
          defaults[:password] = CGI.unescape(uri.password) if uri.password
          defaults[:db]       = uri.path[1..-1].to_i if uri.path
        end
      end

      # Use default when option is not specified or nil
      defaults.keys.each do |key|
        options[key] = defaults[key] if options[key].nil?
      end

      if options[:path]
        options[:scheme] = "unix"
        options.delete(:host)
        options.delete(:port)
      else
        options[:host] = options[:host].to_s
        options[:port] = options[:port].to_i
      end

      options[:timeout] = options[:timeout].to_f
      options[:db] = options[:db].to_i
      options[:driver] = _parse_driver(options[:driver]) || Connection.drivers.last

      case options[:tcp_keepalive]
      when Hash
        [:time, :intvl, :probes].each do |key|
          unless options[:tcp_keepalive][key].is_a?(Fixnum)
            raise "Expected the #{key.inspect} key in :tcp_keepalive to be a Fixnum"
          end
        end

      when Fixnum
        if options[:tcp_keepalive] >= 60
          options[:tcp_keepalive] = {:time => options[:tcp_keepalive] - 20, :intvl => 10, :probes => 2}

        elsif options[:tcp_keepalive] >= 30
          options[:tcp_keepalive] = {:time => options[:tcp_keepalive] - 10, :intvl => 5, :probes => 2}

        elsif options[:tcp_keepalive] >= 5
          options[:tcp_keepalive] = {:time => options[:tcp_keepalive] - 2, :intvl => 2, :probes => 1}
        end
      end

      options
    end

    def _parse_driver(driver)
      driver = driver.to_s if driver.is_a?(Symbol)

      if driver.kind_of?(String)
        begin
          require "redis/connection/#{driver}"
          driver = Connection.const_get(driver.capitalize)
        rescue LoadError, NameError
          raise RuntimeError, "Cannot load driver #{driver.inspect}"
        end
      end

      driver
    end
  end
end
