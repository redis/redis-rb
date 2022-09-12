# frozen_string_literal: true

require "helper"

# ruby -w -Itest test/cluster_client_transactions_test.rb
class TestClusterClientTransactions < Minitest::Test
  include Helper::Cluster

  def test_cluster_client_does_not_support_transaction
    assert_raises(Redis::Cluster::AmbiguousNodeError) do
      redis.multi { |r| r.set('key', 'foo') }
    end
  end
end
