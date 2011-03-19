# Not requiring the pure Ruby connection class when ::Hiredis is defined saves
# about ~100KB RSS on MRI 1.8.7 and ~150KB RSS on MRI 1.9.2.

require "redis/connection/command_helper"

if defined?(EventMachine::Synchrony)
  require "redis/connection/synchrony"
elsif defined?(::Hiredis)
  require "redis/connection/hiredis"
else
  require "redis/connection/ruby"
end