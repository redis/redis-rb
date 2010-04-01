require 'socket'

class Redis
  VERSION = "1.0.0"

  def self.new(*attrs)
    Client.new(*attrs)
  end
end

begin
  if RUBY_VERSION >= '1.9'
    require 'timeout'
    Redis::RedisTimer = Timeout
  else
    require 'system_timer'
    Redis::RedisTimer = SystemTimer
  end
rescue LoadError
  Redis::RedisTimer = nil
end

require 'redis/client'
require 'redis/pipeline'
