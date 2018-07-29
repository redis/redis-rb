# frozen_string_literal: true

require_relative 'helper'
require_relative 'lint/hyper_log_log'

# ruby -w -Itest test/cluster_commands_on_hyper_log_log_test.rb
# @see https://redis.io/commands#hyperloglog
class TestClusterCommandsOnHyperLogLog < Test::Unit::TestCase
  include Helper::Cluster
  include Lint::HyperLogLog

  def test_pfmerge
    assert_raise Redis::CommandError do
      super
    end
  end
end
