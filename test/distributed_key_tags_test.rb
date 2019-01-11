require_relative "helper"

class TestDistributedKeyTags < Test::Unit::TestCase
  include Helper
  include Helper::Distributed

  def test_hashes_consistently
    r1 = build_another_client
    r2 = build_another_client
    r3 = build_another_client

    assert_equal r1.node_for('foo').id, r2.node_for('foo').id
    assert_equal r1.node_for('foo').id, r3.node_for('foo').id
  end

  def test_allows_clustering_of_keys
    r.add_node("redis://127.0.0.1:#{PORT}/14")
    r.flushdb

    100.times do |i|
      r.set "{foo}users:#{i}", i
    end

    assert_equal([0, 0, 100], r.nodes.map { |node| node.call(%i[keys *]).size })
  end

  def test_distributes_keys_if_no_clustering_is_used
    r.add_node("redis://127.0.0.1:#{PORT}/14")
    r.flushdb

    r.set 'users:1', 1
    r.set 'users:4', 4

    assert_equal([1, 1, 0], r.nodes.map { |node| node.call(%i[keys *]).size })
  end

  def test_allows_passing_a_custom_tag_extractor
    r = build_another_client(distributed: { nodes: NODES, tag: /^(.+?):/ })
    r.add_node("redis://127.0.0.1:#{PORT}/14")
    r.flushdb

    100.times do |i|
      r.set "foo:users:#{i}", i
    end

    assert_equal([0, 0, 100], r.nodes.map { |node| node.call(%i[keys *]).size })
  end
end
