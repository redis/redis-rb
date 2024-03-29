# frozen_string_literal: true

require "helper"

class TestDistributedInternals < Minitest::Test
  include Helper::Distributed

  def test_provides_a_meaningful_inspect
    nodes = ["redis://127.0.0.1:#{PORT}/15", *NODES]
    redis = Redis::Distributed.new nodes

    assert_equal "#<Redis client v#{Redis::VERSION} for #{redis.nodes.map(&:id).join(', ')}>", redis.inspect
  end

  def test_default_as_urls
    nodes = ["redis://127.0.0.1:#{PORT}/15", *NODES]
    redis = Redis::Distributed.new nodes
    assert_equal(["redis://127.0.0.1:#{PORT}/15", *NODES], redis.nodes.map { |node| node._client.server_url })
  end

  def test_default_as_config_hashes
    nodes = [OPTIONS.merge(host: '127.0.0.1'), OPTIONS.merge(host: 'somehost', port: PORT.next)]
    redis = Redis::Distributed.new nodes
    assert_equal(["redis://127.0.0.1:#{PORT}/15", "redis://somehost:#{PORT.next}/15"], redis.nodes.map { |node| node._client.server_url })
  end

  def test_as_mix_and_match
    nodes = ["redis://127.0.0.1:7389/15", OPTIONS.merge(host: 'somehost'), OPTIONS.merge(host: 'somehost', port: PORT.next)]
    redis = Redis::Distributed.new nodes
    assert_equal(["redis://127.0.0.1:7389/15", "redis://somehost:#{PORT}/15", "redis://somehost:#{PORT.next}/15"], redis.nodes.map { |node| node._client.server_url })
  end

  def test_override_id
    nodes = [OPTIONS.merge(host: '127.0.0.1', id: "test"), OPTIONS.merge(host: 'somehost', port: PORT.next, id: "test1")]
    redis = Redis::Distributed.new nodes
    assert_equal redis.nodes.first._client.id, "test"
    assert_equal redis.nodes.last._client.id,  "test1"
    assert_equal "#<Redis client v#{Redis::VERSION} for #{redis.nodes.map(&:id).join(', ')}>", redis.inspect
  end

  def test_can_be_duped_to_create_a_new_connection
    redis = Redis::Distributed.new(NODES)

    clients = redis.info[0]["connected_clients"].to_i

    r2 = redis.dup
    r2.ping

    assert_equal clients + 1, redis.info[0]["connected_clients"].to_i
  end

  def test_keeps_options_after_dup
    r1 = Redis::Distributed.new(NODES, tag: /^(\w+):/)

    assert_raises(Redis::Distributed::CannotDistribute) do
      r1.sinter("foo", "bar")
    end

    assert_equal [], r1.sinter("baz:foo", "baz:bar")

    r2 = r1.dup

    assert_raises(Redis::Distributed::CannotDistribute) do
      r2.sinter("foo", "bar")
    end

    assert_equal [], r2.sinter("baz:foo", "baz:bar")
  end
end
