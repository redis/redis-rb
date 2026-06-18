# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require "minitest/autorun"
require "mocha/minitest"

$VERBOSE = true

ENV["DRIVER"] ||= "ruby"
ENV["PROTOCOL"] ||= "3"

require "redis"
Redis.silence_deprecations = true

require "redis/distributed"

require_relative "support/redis_mock"

if ENV["DRIVER"] == "hiredis"
  require "hiredis-client"
end

PORT         = 6381
# Port the module test suite connects to. On Redis >= 8 the modules are in core, so this is
# the standalone instance (6381); on 7.2/7.4 CI points it at the dedicated Redis Stack
# instance (6383) via REDIS_MODULES_PORT.
MODULES_PORT = Integer(ENV['REDIS_MODULES_PORT'] || PORT)
DB           = 15
TIMEOUT      = Float(ENV['TIMEOUT'] || 1.0)
LOW_TIMEOUT  = Float(ENV['LOW_TIMEOUT'] || 0.01) # for blocking-command tests
PROTOCOL     = Integer(ENV['PROTOCOL']) # RESP protocol the test client uses (3 by default, 2 for compat runs)
OPTIONS      = { port: PORT, db: DB, timeout: TIMEOUT }.freeze

if ENV['REDIS_SOCKET_PATH'].nil?
  sock_file = File.expand_path('../tmp/redis.sock', __dir__)

  unless File.exist?(sock_file)
    abort "Couldn't locate the redis unix socket at #{sock_file}, did you run `make start` (or `docker compose --profile standalone up -d --wait`)?"
  end

  ENV['REDIS_SOCKET_PATH'] = sock_file
end

Dir[File.expand_path('lint/**/*.rb', __dir__)].sort.each do |f|
  require f
end

module Helper
  def run
    if respond_to?(:around)
      around { super }
    else
      super
    end
  end

  def silent
    verbose, $VERBOSE = $VERBOSE, false

    begin
      yield
    ensure
      $VERBOSE = verbose
    end
  end

  class Version
    include Comparable

    attr :parts

    def initialize(version)
      @parts = case version
      when Version
        version.parts
      else
        version.to_s.split(".")
      end
    end

    def <=>(other)
      other = Version.new(other)
      length = [parts.length, other.parts.length].max
      length.times do |i|
        a, b = parts[i], other.parts[i]

        return -1 if a.nil?
        return +1 if b.nil?
        return a.to_i <=> b.to_i if a != b
      end

      0
    end
  end

  module Generic
    include Helper

    attr_reader :log, :redis

    alias r redis

    def setup
      @redis = init _new_client

      # Run GC to make sure orphaned connections are closed.
      GC.start
      super
    end

    def teardown
      redis&.close
      super
    end

    def init(redis)
      redis.select 14
      redis.flushdb
      redis.select 15
      redis.flushdb
      redis
    rescue Redis::CannotConnectError
      puts <<-MSG

        Cannot connect to Redis.

        Make sure Redis is running on localhost, port #{PORT}.
        This testing suite connects to the database 15.

        Try this once:

          $ make clean

        Then run the build again:

          $ make

      MSG
      exit 1
    end

    def redis_mock(commands, options = {})
      RedisMock.start(commands, options) do |port|
        yield _new_client(options.merge(port: port))
      end
    end

    def redis_mock_with_handler(handler, options = {})
      RedisMock.start_with_handler(handler, options) do |port|
        yield _new_client(options.merge(port: port))
      end
    end

    def assert_in_range(range, value)
      assert range.include?(value), "expected #{value} to be in #{range.inspect}"
    end

    def target_version(target)
      if version < target
        skip("Requires Redis > #{target}") if respond_to?(:skip)
      else
        yield
      end
    end

    def with_db(index)
      r.select(index)
      yield
    end

    def omit_version(min_ver)
      skip("Requires Redis > #{min_ver}") if version < min_ver
    end

    # Assert the named Redis module is loaded (e.g. "ReJSON" for RedisJSON), raising if it is
    # not. The module test suite always runs against a server that is expected to have the
    # module — the standalone instance on Redis >= 8 (modules in core) or the dedicated Redis
    # Stack instance on 7.2/7.4 — so a missing module is an infrastructure error we want to
    # surface loudly rather than silently skip. Redis::Distributed doesn't expose #call, so
    # probe one node.
    def require_module(name)
      client = redis.respond_to?(:call) ? redis : redis.nodes.first
      # MODULE LIST returns each module as a flat [k, v, ...] array under RESP2 and as a native
      # Hash under RESP3.
      loaded = client.call("MODULE", "LIST").map { |mod| (mod.is_a?(Hash) ? mod : Hash[*mod])["name"] }
      return if loaded.include?(name)

      raise "Redis module #{name.inspect} is not loaded but the module test suite requires it. " \
            "Bring up a module-capable server (Redis >= 8, or `make start_modules` for a Redis " \
            "Stack instance). Modules loaded: #{loaded.inspect}."
    end

    def version
      Version.new(redis.info['redis_version'])
    end

    def with_acl
      admin = _new_client
      admin.acl('SETUSER', 'johndoe', 'on',
                '+ping', '+select', '+command', '+cluster|slots', '+cluster|nodes', '+cluster|shards', '+readonly',
                '>mysecret')
      yield('johndoe', 'mysecret')
    ensure
      admin.acl('DELUSER', 'johndoe')
      admin.close
    end

    def with_default_user_password
      admin = _new_client
      admin.acl('SETUSER', 'default', '>mysecret')
      yield('default', 'mysecret')
    ensure
      admin.acl('SETUSER', 'default', 'nopass')
      admin.close
    end
  end

  module Client
    include Generic

    private

    def _format_options(options)
      OPTIONS.merge(options)
    end

    def _new_client(options = {})
      Redis.new(_format_options(options).merge(driver: ENV["DRIVER"], protocol: PROTOCOL))
    end
  end

  # Client for the module test suite. Connects to MODULES_PORT: the core `standalone` instance
  # on Redis >= 8 (modules in core), or the dedicated Redis Stack instance on 7.2/7.4.
  module Modules
    include Generic

    private

    def _format_options(options)
      OPTIONS.merge(port: MODULES_PORT).merge(options)
    end

    def _new_client(options = {})
      Redis.new(_format_options(options).merge(driver: ENV["DRIVER"], protocol: PROTOCOL))
    end
  end

  module Sentinel
    include Generic

    MASTER_PORT = PORT.to_s
    SLAVE_PORT = '6382'
    SENTINEL_PORT = '6400'
    SENTINEL_PORTS = %w[6400 6401 6402].freeze
    MASTER_NAME = 'master1'
    LOCALHOST = '127.0.0.1'

    def build_sentinel_client(options = {})
      opts = { host: LOCALHOST, port: SENTINEL_PORT, timeout: TIMEOUT }
      Redis.new(opts.merge(options).merge(driver: ENV["DRIVER"], protocol: PROTOCOL))
    end

    def build_slave_role_client(options = {})
      _new_client(options.merge(role: :slave))
    end

    private

    def wait_for_quorum
      redis = build_sentinel_client
      50.times do
        if redis.sentinel('ckquorum', MASTER_NAME).start_with?('OK 3 usable Sentinels')
          return
        else
          sleep 0.1
        end
      rescue
        sleep 0.1
      end
      raise "ckquorum timeout"
    end

    def _format_options(options = {})
      {
        url: "redis://#{MASTER_NAME}",
        sentinels: [{ host: LOCALHOST, port: SENTINEL_PORT }],
        role: :master, timeout: TIMEOUT,
      }.merge(options)
    end

    def _new_client(options = {})
      Redis.new(_format_options(options).merge(driver: ENV['DRIVER'], protocol: PROTOCOL))
    end
  end

  module Distributed
    include Generic

    NODES = ["redis://127.0.0.1:#{PORT}/#{DB}"].freeze

    def version
      Version.new(redis.info.first["redis_version"])
    end

    private

    def _format_options(options)
      {
        timeout: OPTIONS[:timeout],
      }.merge(options)
    end

    def _new_client(options = {})
      Redis::Distributed.new(NODES, _format_options(options).merge(driver: ENV["DRIVER"], protocol: PROTOCOL))
    end
  end

  # Like Helper::Distributed, but the single ring node is the module-capable server
  # (MODULES_PORT): the standalone instance on Redis >= 8, or the dedicated Redis Stack
  # instance on 7.2/7.4. Used by the distributed JSON test so it routes to a node that
  # actually has the module loaded — the plain `standalone` is core-only on Redis < 8.
  module DistributedModules
    include Distributed

    NODES = ["redis://127.0.0.1:#{MODULES_PORT}/#{DB}"].freeze

    private

    def _new_client(options = {})
      Redis::Distributed.new(NODES, _format_options(options).merge(driver: ENV["DRIVER"], protocol: PROTOCOL))
    end
  end
end
