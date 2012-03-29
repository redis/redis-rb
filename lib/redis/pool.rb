require "connection_pool"

class Redis::Pool < Redis
  def initialize(options = {})
    @pool = ConnectionPool.new(:size => options.delete(:size)) { Redis::Client.new(options) }
    @id = "Redis::Pool::#{object_id}"

    super
  end

  def synchronize
    @pool.with do |client|
      _with_client(client) { yield(client) }
    end
  end

  def pipelined
    pipeline = Pipeline.new

    _with_client(pipeline) do |client|
      yield(client)
    end

    synchronize do |client|
      client.call_pipeline(pipeline)
    end
  end

  def multi
    raise ArgumentError, "Redis::Pool#multi can only be called with a block" unless block_given?

    pipeline = Pipeline::Multi.new

    _with_client(pipeline) do |client|
      yield(client)
    end

    synchronize do |client|
      client.call_pipeline(pipeline)
    end
  end

protected
  def _with_client(client)
    Thread.current[@id] = client
    yield(client)
  ensure
    Thread.current[@id] = nil
  end
end
