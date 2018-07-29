require_relative 'helper'
require_relative 'lint/hyper_log_log'

class TestCommandsOnHyperLogLog < Test::Unit::TestCase
  include Helper::Client
  include Lint::HyperLogLog
end
