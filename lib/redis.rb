require 'socket'

class Redis
  VERSION = "1.0.4"

  def self.new(*attrs)
    Client.new(*attrs)
  end
end

begin
  if RUBY_VERSION >= '1.9'
    require 'timeout'
    Redis::Timer = Timeout
  else
    require 'system_timer'
    Redis::Timer = SystemTimer
  end
rescue LoadError
  Redis::Timer = nil
end

require 'redis/client'
require 'redis/pipeline'
require 'redis/subscribe'
