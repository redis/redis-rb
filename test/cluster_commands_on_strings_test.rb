# frozen_string_literal: true

require_relative 'helper'
require_relative 'lint/strings'

# ruby -w -Itest test/cluster_commands_on_strings_test.rb
# @see https://redis.io/commands#string
class TestClusterCommandsOnStrings < Test::Unit::TestCase
  include Helper::Cluster
  include Lint::Strings

  def mock(*args, &block)
    redis_cluster_mock(*args, &block)
  end
end
