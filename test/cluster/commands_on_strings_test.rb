# frozen_string_literal: true

require "helper"

# ruby -w -Itest test/cluster_commands_on_strings_test.rb
# @see https://redis.io/commands#string
class TestClusterCommandsOnStrings < Minitest::Test
  include Helper::Cluster
  include Lint::Strings

  def mock(*args, &block)
    redis_cluster_mock(*args, &block)
  end
end
