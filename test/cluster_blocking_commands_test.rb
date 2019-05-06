# frozen_string_literal: true

require_relative 'helper'
require_relative 'lint/blocking_commands'

# ruby -w -Itest test/cluster_blocking_commands_test.rb
class TestClusterBlockingCommands < Minitest::Test
  include Helper::Cluster
  include Lint::BlockingCommands

  def mock(options = {}, &blk)
    commands = build_mock_commands(options)
    redis_cluster_mock(commands, { timeout: LOW_TIMEOUT }, &blk)
  end
end
