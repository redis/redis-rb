require_relative 'helper'
require_relative 'lint/hyper_log_log'

class TestCommandsOnHyperLogLog < Minitest::Test
  include Helper::Client
  include Lint::HyperLogLog
end
