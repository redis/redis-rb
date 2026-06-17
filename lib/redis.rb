# frozen_string_literal: true

require "redis-client"

require "monitor"
require "redis/errors"
require "redis/commands"

class Redis
  BASE_PATH = __dir__
  Deprecated = Class.new(StandardError)

  class << self
    attr_accessor :silence_deprecations, :raise_deprecations

    def deprecate!(message)
      unless silence_deprecations
        if raise_deprecations
          raise Deprecated, message
        else
          ::Kernel.warn(message)
        end
      end
    end
  end

  # soft-deprecated
  # We added this back for older sidekiq releases
  module Connection
    class << self
      def drivers
        [RedisClient.default_driver]
      end
    end
  end

  include Commands

  SERVER_URL_OPTIONS = %i(url host port path).freeze

  # Create a new client instance
  #
  # @param [Hash] options
  # @option options [String] :url (value of the environment variable REDIS_URL) a Redis URL, for a TCP connection:
  #   `redis://:[password]@[hostname]:[port]/[db]` (password, port and database are optional), for a unix socket
  #    connection: `unix://[path to Redis socket]`. This overrides all other options.
  # @option options [String] :host ("127.0.0.1") server hostname
  # @option options [Integer] :port (6379) server port
  # @option options [String] :path path to server socket (overrides host and port)
  # @option options [Float] :timeout (1.0) timeout in seconds
  # @option options [Float] :connect_timeout (same as timeout) timeout for initial connect in seconds
  # @option options [String] :username Username to authenticate against server
  # @option options [String] :password Password to authenticate against server
  # @option options [Integer] :db (0) Database to select after connect and on reconnects
  # @option options [Symbol] :driver Driver to use, currently supported: `:ruby`, `:hiredis`
  # @option options [Integer] :protocol (3) RESP protocol version to negotiate (`HELLO`). Defaults
  #   to RESP3; set to `2` for RESP2. Servers without RESP3 support automatically fall back to RESP2.
  # @option options [String] :id ID for the client connection, assigns name to current connection by sending
  #   `CLIENT SETNAME`
  # @option options [Integer, Array<Integer, Float>] :reconnect_attempts Number of attempts trying to connect,
  #   or a list of sleep duration between attempts.
  # @option options [Boolean] :inherit_socket (false) Whether to use socket in forked process or not
  # @option options [String] :name The name of the server group to connect to.
  # @option options [Array] :sentinels List of sentinels to contact
  #
  # @return [Redis] a new client instance
  def initialize(options = {})
    @monitor = Monitor.new
    @options = options.dup
    @options[:reconnect_attempts] = 1 unless @options.key?(:reconnect_attempts)
    if ENV["REDIS_URL"] && SERVER_URL_OPTIONS.none? { |o| @options.key?(o) }
      @options[:url] = ENV["REDIS_URL"]
    end
    # Kept as state, not just a local: the RESP3->RESP2 fallback rebuilds @client and must re-apply
    # socket inheritance, otherwise fork safety would be silently lost after a downgrade.
    @inherit_socket = @options.delete(:inherit_socket)
    @subscription_client = nil

    @client = build_client
  end

  # Run code without the client reconnecting
  def without_reconnect(&block)
    @client.disable_reconnection(&block)
  end

  # Test whether or not the client is connected
  def connected?
    @client.connected? || @subscription_client&.connected?
  end

  # Disconnect the client as quickly and silently as possible.
  def close
    @client.close
    @subscription_client&.close
  end
  alias disconnect! close

  def with
    yield self
  end

  def _client
    @client
  end

  def pipelined(exception: true)
    synchronize do |client|
      client.pipelined(exception: exception) do |raw_pipeline|
        yield PipelinedConnection.new(raw_pipeline, exception: exception)
      end
    end
  end

  def id
    @client.id || @client.server_url
  end

  def inspect
    "#<Redis client v#{Redis::VERSION} for #{id}>"
  end

  def dup
    self.class.new(@options)
  end

  def connection
    {
      host: @client.host,
      port: @client.port,
      db: @client.db,
      id: id,
      location: "#{@client.host}:#{@client.port}"
    }
  end

  private

  # Builds @client from @options and applies any instance-level settings (socket inheritance) that
  # live outside @options. Used both at construction and when the RESP3->RESP2 fallback rebuilds the
  # client, so those settings survive a protocol downgrade.
  def build_client
    client = initialize_client(@options)
    client.inherit_socket! if @inherit_socket
    client
  end

  def initialize_client(options)
    if options.key?(:cluster)
      raise "Redis Cluster support was moved to the `redis-clustering` gem."
    end

    if options.key?(:sentinels)
      Client.sentinel(**options).new_client
    else
      Client.config(**options).new_client
    end
  end

  # All access to @client funnels through here: it serializes on @monitor and applies the RESP3
  # protocol fallback. Routing pipelined/multi/watch (which all call synchronize) through the same
  # path means they fall back to RESP2 against pre-HELLO servers just like single commands do.
  def synchronize
    @monitor.synchronize do
      with_protocol_fallback do
        yield(@client)
      end
    end
  end

  def send_command(command, &block)
    synchronize do |client|
      client.call_v(command, &block)
    end
  rescue ::RedisClient::Error => error
    Client.translate_error!(error)
  end

  def send_blocking_command(command, timeout, &block)
    synchronize do |client|
      client.blocking_call_v(timeout, command, &block)
    end
  end

  # We default to RESP3. Servers that don't support it reject the `HELLO 3` handshake (most
  # notably Redis < 6.0, which has no HELLO command). Rebuild the client as RESP2 once so those
  # servers keep working without the user setting `protocol: 2`.
  #
  # This is the single fallback point for every client type. Each one surfaces the resp3-unsupported
  # error here untranslated (still a RedisClient::Error): standalone/distributed via
  # Redis::Client#call_v et al., sentinel via the plain RedisClient (which never translates), and
  # cluster via Redis::Cluster::Client#handle_errors. Because every @client access — single commands,
  # pipelined, multi, watch, and the pub/sub socket — flows through #synchronize, wrapping it here
  # covers them all.
  #
  # Must be called while holding @monitor: it closes and replaces @client, so it has to be
  # serialized with the command execution that uses @client. The retried block re-reads @client, so
  # callers must reference the rebuilt instance (via the synchronize block argument), not a cached
  # one.
  def with_protocol_fallback
    yield
  rescue ::RedisClient::Error => error
    if @options.fetch(:protocol, 3).to_i == 3 && Client.resp3_unsupported?(error)
      # Fires once per client: after the downgrade @options[:protocol] is 2, so this branch never
      # re-enters. Passing `protocol: 2` explicitly skips it entirely (and silences this warning).
      warn("Redis: #{id} does not support RESP3 (the HELLO 3 handshake failed); falling back to " \
           "RESP2. Pass `protocol: 2` to select RESP2 explicitly and silence this warning.")
      @options = @options.merge(protocol: 2)
      @client.close
      @client = build_client
      retry
    end

    raise
  end

  def _subscription(method, timeout, channels, block)
    if block
      if @subscription_client
        raise SubscriptionError, "This client is already subscribed"
      end

      begin
        # The pub/sub second socket is opened via @client.pubsub, which connects through
        # ensure_connected rather than a command path. Route it through #synchronize so the same
        # RESP3->RESP2 fallback applies when subscribe is the first operation against an old server.
        @subscription_client = SubscribedClient.new(synchronize(&:pubsub))
        if timeout > 0
          @subscription_client.send(method, timeout, *channels, &block)
        else
          @subscription_client.send(method, *channels, &block)
        end
      ensure
        @subscription_client&.close
        @subscription_client = nil
      end
    else
      unless @subscription_client
        raise SubscriptionError, "This client is not subscribed"
      end

      @subscription_client.call_v([method].concat(channels))
    end
  end
end

require "redis/version"
require "redis/client"
require "redis/pipeline"
require "redis/subscribe"
