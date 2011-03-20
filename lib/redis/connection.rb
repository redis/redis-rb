# Not requiring the pure Ruby connection class when ::Hiredis is defined saves
# about ~100KB RSS on MRI 1.8.7 and ~150KB RSS on MRI 1.9.2.

require "redis/connection/command_helper"

if !defined?(::Hiredis) && !defined?(EventMachine)
  require "redis/connection/ruby"
end