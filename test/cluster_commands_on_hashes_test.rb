# frozen_string_literal: true

require_relative 'helper'
require_relative 'lint/hashes'

# ruby -w -Itest test/cluster_commands_on_hashes_test.rb
# @see https://redis.io/commands#hash
class TestClusterCommandsOnHashes < Minitest::Test
  include Helper::Cluster
  include Lint::Hashes
end
