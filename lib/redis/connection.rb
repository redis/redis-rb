# Not requiring the pure Ruby connection class when ::Hiredis is defined saves
# about ~100KB RSS on MRI 1.8.7 and ~150KB RSS on MRI 1.9.2.

require "redis/connection/synchrony" if defined?(EventMachine::Synchrony)
require "redis/connection/hiredis" if defined?(::Hiredis)
require "redis/connection/ruby"