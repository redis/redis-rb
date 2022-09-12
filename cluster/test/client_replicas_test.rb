# frozen_string_literal: true

require "helper"

# ruby -w -Itest test/cluster_client_replicas_test.rb
class TestClusterClientReplicas < Minitest::Test
  include Helper::Cluster

  def test_client_can_command_with_replica
    r = build_another_client(replica: true)

    100.times do |i|
      assert_equal 'OK', r.set("key#{i}", i)
    end

    r.wait(1, TIMEOUT.to_i * 1000)

    100.times do |i|
      assert_equal i.to_s, r.get("key#{i}")
    end
  end
end
