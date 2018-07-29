# frozen_string_literal: true

require_relative 'helper'
require_relative 'lint/blocking_commands'

# ruby -w -Itest test/cluster_blocking_commands_test.rb
class TestClusterBlockingCommands < Test::Unit::TestCase
  include Helper::Cluster
  include Lint::BlockingCommands

  def mock(options = {}, &blk)
    commands = build_mock_commands(options)
    redis_cluster_mock(commands, &blk)
  end
end
