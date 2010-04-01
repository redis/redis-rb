require 'socket'

module RedisRb
  VERSION = "1.0.0"
end

begin
  if RUBY_VERSION >= '1.9'
    require 'timeout'
    RedisRb::RedisTimer = Timeout
  else
    require 'system_timer'
    RedisRb::RedisTimer = SystemTimer
  end
rescue LoadError
  RedisRb::RedisTimer = nil
end

require 'redis/client'
require 'redis/pipeline'

# For backwards compatibility
Redis = RedisRb::Client
