require_relative "helper"

class TestDistributedInternals < Test::Unit::TestCase
  include Helper::Distributed

  def test_provides_a_meaningful_inspect
    expected = "#<Redis client v#{Redis::VERSION} for #{redis.nodes.map(&:id).join(', ')}>"
    assert_equal expected, redis.inspect
  end

  def test_default_as_urls
    expected = ["redis://127.0.0.1:#{PORT}/#{DB}", "redis://127.0.0.1:#{NODE2_PORT}/#{DB}"]
    assert_equal expected, redis.nodes.map(&:id)
  end

  def test_default_as_config_hashes
    nodes = [{ host: '127.0.0.1', port: PORT, db: DB }, { host: '127.0.0.1', port: NODE2_PORT, db: DB }]
    redis = build_another_client(distributed: { nodes: nodes })
    expected = ["redis://127.0.0.1:#{PORT}/#{DB}", "redis://127.0.0.1:#{NODE2_PORT}/#{DB}"]
    assert_equal expected, redis.nodes.map(&:id)
  end

  def test_as_mix_and_match
    nodes = ["redis://127.0.0.1:#{PORT}/#{DB}", { host: '127.0.0.1', port: PORT, db: 14 }, { host: '127.0.0.1', port: NODE2_PORT, db: DB }]
    redis = build_another_client(distributed: { nodes: nodes })
    expected = ["redis://127.0.0.1:#{PORT}/#{DB}", "redis://127.0.0.1:#{PORT}/14", "redis://127.0.0.1:#{NODE2_PORT}/#{DB}"]
    assert_equal expected, redis.nodes.map(&:id)
  end

  def test_override_id
    nodes = [{ host: '127.0.0.1', port: PORT, db: DB, id: 'test1' }, { host: '127.0.0.1', port: NODE2_PORT, db: DB, id: 'test2' }]
    redis = build_another_client(distributed: { nodes: nodes })
    assert_equal redis.nodes.first.id, 'test1'
    assert_equal redis.nodes.last.id,  'test2'
    expected = "#<Redis client v#{Redis::VERSION} for #{redis.nodes.map(&:id).join(', ')}>"
    assert_equal expected, redis.inspect
  end

  def test_can_be_duped_to_create_a_new_connection
    clients = redis.info[0]['connected_clients'].to_i

    r2 = redis.dup
    r2.ping

    assert_equal clients + 1, redis.info[0]['connected_clients'].to_i
  end

  def test_keeps_options_after_dup
    r1 = build_another_client(distributed: { nodes: NODES, tag: /^(\w+):/ })

    assert_raise(Redis::Distributed::CannotDistribute) do
      r1.sinter('key1', 'key4')
    end

    assert_equal [], r1.sinter('baz:foo', 'baz:bar')

    r2 = r1.dup

    assert_raise(Redis::Distributed::CannotDistribute) do
      r2.sinter('key1', 'key4')
    end

    assert_equal [], r2.sinter('baz:foo', 'baz:bar')
  end
end
