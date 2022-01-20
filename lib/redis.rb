# frozen_string_literal: true

require "monitor"
require "redis/errors"
require "redis/commands"

class Redis
  BASE_PATH = __dir__
  @exists_returns_integer = true

  class << self
    attr_reader :exists_returns_integer
    attr_accessor :silence_deprecations

    def exists_returns_integer=(value)
      unless value
        deprecate!(
          "`Redis#exists(key)` will return an Integer by default in redis-rb 4.3. The option to explicitly " \
          "disable this behaviour via `Redis.exists_returns_integer` will be removed in 5.0. You should use " \
          "`exists?` instead."
        )
      end

      @exists_returns_integer = value
    end

    def deprecate!(message)
      ::Kernel.warn(message) unless silence_deprecations
    end

    attr_writer :current
  end

  def self.current
    @current ||= Redis.new
  end

  include Commands
  include MonitorMixin

  # Create a new client instance
  #
  # @param [Hash] options
  # @option options [String] :url (value of the environment variable REDIS_URL) a Redis URL, for a TCP connection:
  #   `redis://:[password]@[hostname]:[port]/[db]` (password, port and database are optional), for a unix socket
  #    connection: `unix://[path to Redis socket]`. This overrides all other options.
  # @option options [String] :host ("127.0.0.1") server hostname
  # @option options [Integer] :port (6379) server port
  # @option options [String] :path path to server socket (overrides host and port)
  # @option options [Float] :timeout (5.0) timeout in seconds
  # @option options [Float] :connect_timeout (same as timeout) timeout for initial connect in seconds
  # @option options [String] :username Username to authenticate against server
  # @option options [String] :password Password to authenticate against server
  # @option options [Integer] :db (0) Database to select after initial connect
  # @option options [Symbol] :driver Driver to use, currently supported: `:ruby`, `:hiredis`, `:synchrony`
  # @option options [String] :id ID for the client connection, assigns name to current connection by sending
  #   `CLIENT SETNAME`
  # @option options [Hash, Integer] :tcp_keepalive Keepalive values, if Integer `intvl` and `probe` are calculated
  #   based on the value, if Hash `time`, `intvl` and `probes` can be specified as a Integer
  # @option options [Integer] :reconnect_attempts Number of attempts trying to connect
  # @option options [Boolean] :inherit_socket (false) Whether to use socket in forked process or not
  # @option options [Array] :sentinels List of sentinels to contact
  # @option options [Symbol] :role (:master) Role to fetch via Sentinel, either `:master` or `:slave`
  # @option options [Array<String, Hash{Symbol => String, Integer}>] :cluster List of cluster nodes to contact
  # @option options [Boolean] :replica Whether to use readonly replica nodes in Redis Cluster or not
  # @option options [Class] :connector Class of custom connector
  #
  # @return [Redis] a new client instance
  def initialize(options = {})
    @options = options.dup
    @cluster_mode = options.key?(:cluster)
    client = @cluster_mode ? Cluster : Client
    @original_client = @client = client.new(options)
    @queue = Hash.new { |h, k| h[k] = [] }

    super() # Monitor#initialize
  end

  def synchronize
    mon_synchronize { yield(@client) }
  end

  # Run code with the client reconnecting
  def with_reconnect(val = true, &blk)
    synchronize do |client|
      client.with_reconnect(val, &blk)
    end
  end

  # Run code without the client reconnecting
  def without_reconnect(&blk)
    with_reconnect(false, &blk)
  end

  # Test whether or not the client is connected
  def connected?
    @original_client.connected?
  end

  # Disconnect the client as quickly and silently as possible.
  def close
    @original_client.disconnect
  end
  alias disconnect! close

  # Queues a command for pipelining.
  #
  # Commands in the queue are executed with the Redis#commit method.
  #
  # See http://redis.io/topics/pipelining for more details.
  #
  def queue(*command)
    ::Redis.deprecate!(
      "Redis#queue is deprecated and will be removed in Redis 5.0.0. Use Redis#pipelined instead." \
      "(called from: #{caller(1, 1).first})"
    )

    synchronize do
      @queue[Thread.current.object_id] << command
    end
  end

  # Sends all commands in the queue.
  #
  # See http://redis.io/topics/pipelining for more details.
  #
  def commit
    ::Redis.deprecate!(
      "Redis#commit is deprecated and will be removed in Redis 5.0.0. Use Redis#pipelined instead. " \
      "(called from: #{Kernel.caller(1, 1).first})"
    )

    synchronize do |client|
      begin
        pipeline = Pipeline.new(client)
        @queue[Thread.current.object_id].each do |command|
          pipeline.call(command)
        end

        client.call_pipelined(pipeline)
      ensure
        @queue.delete(Thread.current.object_id)
      end
    end
  end

  def _client
    @client
  end

  # Watch the given keys to determine execution of the MULTI/EXEC block.
  #
  # Using a block is optional, but is necessary for thread-safety.
  #
  # An `#unwatch` is automatically issued if an exception is raised within the
  # block that is a subclass of StandardError and is not a ConnectionError.
  #
  # @example With a block
  #   redis.watch("key") do
  #     if redis.get("key") == "some value"
  #       redis.multi do |multi|
  #         multi.set("key", "other value")
  #         multi.incr("counter")
  #       end
  #     else
  #       redis.unwatch
  #     end
  #   end
  #     # => ["OK", 6]
  #
  # @example Without a block
  #   redis.watch("key")
  #     # => "OK"
  #
  # @param [String, Array<String>] keys one or more keys to watch
  # @return [Object] if using a block, returns the return value of the block
  # @return [String] if not using a block, returns `OK`
  #
  # @see #unwatch
  # @see #multi
  def watch(*keys)
    synchronize do |client|
      res = client.call([:watch, *keys])

      if block_given?
        begin
          yield(self)
        rescue ConnectionError
          raise
        rescue StandardError
          unwatch
          raise
        end
      else
        res
      end
    end
  end

  # Forget about all watched keys.
  #
  # @return [String] `OK`
  #
  # @see #watch
  # @see #multi
  def unwatch
    synchronize do |client|
      client.call([:unwatch])
    end
  end

  def pipelined(&block)
    deprecation_displayed = false
    if block&.arity == 0
      Pipeline.deprecation_warning(Kernel.caller_locations(1, 5))
      deprecation_displayed = true
    end

    synchronize do |prior_client|
      begin
        pipeline = Pipeline.new(prior_client)
        @client = deprecation_displayed ? pipeline : DeprecatedPipeline.new(pipeline)
        pipelined_connection = PipelinedConnection.new(pipeline)
        yield pipelined_connection
        prior_client.call_pipeline(pipeline)
      ensure
        @client = prior_client
      end
    end
  end

  # Mark the start of a transaction block.
  #
  # Passing a block is optional.
  #
  # @example With a block
  #   redis.multi do |multi|
  #     multi.set("key", "value")
  #     multi.incr("counter")
  #   end # => ["OK", 6]
  #
  # @example Without a block
  #   redis.multi
  #     # => "OK"
  #   redis.set("key", "value")
  #     # => "QUEUED"
  #   redis.incr("counter")
  #     # => "QUEUED"
  #   redis.exec
  #     # => ["OK", 6]
  #
  # @yield [multi] the commands that are called inside this block are cached
  #   and written to the server upon returning from it
  # @yieldparam [Redis] multi `self`
  #
  # @return [String, Array<...>]
  #   - when a block is not given, `OK`
  #   - when a block is given, an array with replies
  #
  # @see #watch
  # @see #unwatch
  def multi
    synchronize do |prior_client|
      if !block_given?
        prior_client.call([:multi])
      else
        begin
          @client = Pipeline::Multi.new(prior_client)
          yield(self)
          prior_client.call_pipeline(@client)
        ensure
          @client = prior_client
        end
      end
    end
  end

  def id
    @original_client.id
  end

  def inspect
    "#<Redis client v#{Redis::VERSION} for #{id}>"
  end

  def dup
    self.class.new(@options)
  end

  def connection
    return @original_client.connection_info if @cluster_mode

    {
      host: @original_client.host,
      port: @original_client.port,
      db: @original_client.db,
      id: @original_client.id,
      location: @original_client.location
    }
  end

  private

  def send_command(command, &block)
    synchronize do |client|
      client.call(command, &block)
    end
  end

  def send_blocking_command(command, timeout, &block)
    synchronize do |client|
      client.call_with_timeout(command, timeout, &block)
    end
  end

  def _subscription(method, timeout, channels, block)
    return @client.call([method] + channels) if subscribed?

    begin
      original, @client = @client, SubscribedClient.new(@client)
      if timeout > 0
        @client.send(method, timeout, *channels, &block)
      else
        @client.send(method, *channels, &block)
      end
    ensure
      @client = original
    end
  end
end

require_relative "redis/version"
require_relative "redis/connection"
require_relative "redis/client"
require_relative "redis/cluster"
require_relative "redis/pipeline"
require_relative "redis/subscribe"
