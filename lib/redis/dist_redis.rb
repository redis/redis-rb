Redis.deprecate %q{"redis/dist_redis" is deprecated. Require "redis/distributed" and replace DistRedis for Redis::Distributed.}, caller[0]

require "redis/hash_ring"
require "redis/distributed"

class Redis
  class DistRedis < Redis::Distributed
    def initialize(*args)
      Redis.deprecate "DistRedis is deprecated in favor of Redis::Distributed.", caller[1]
      super(*args)
    end
  end
end

# For backwards compatibility
DistRedis = Redis::DistRedis
