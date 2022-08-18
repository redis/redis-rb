# frozen_string_literal: true

require "helper"

# ruby -w -Itest test/cluster_commands_on_hashes_test.rb
# @see https://redis.io/commands#hash
class TestClusterCommandsOnHashes < Minitest::Test
  include Helper::Cluster
  include Lint::Hashes
end
