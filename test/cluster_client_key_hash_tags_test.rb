# frozen_string_literal: true

require_relative 'helper'

# ruby -w -Itest test/cluster_client_key_hash_tags_test.rb
class TestClusterClientKeyHashTags < Test::Unit::TestCase
  include Helper::Cluster

  def build_described_class
    option = Redis::Cluster::Option.new(cluster: ['redis://127.0.0.1:7000'])
    node = Redis::Cluster::Node.new(option.per_node_key)
    details = Redis::Cluster::CommandLoader.load(node)
    Redis::Cluster::Command.new(details)
  end

  def test_key_extraction
    described_class = build_described_class

    assert_equal 'dogs:1', described_class.extract_first_key(%w[get dogs:1])
    assert_equal 'user1000', described_class.extract_first_key(%w[get {user1000}.following])
    assert_equal 'user1000', described_class.extract_first_key(%w[get {user1000}.followers])
    assert_equal 'foo{}{bar}', described_class.extract_first_key(%w[get foo{}{bar}])
    assert_equal '{bar', described_class.extract_first_key(%w[get foo{{bar}}zap])
    assert_equal 'bar', described_class.extract_first_key(%w[get foo{bar}{zap}])

    assert_equal '', described_class.extract_first_key([:get, ''])
    assert_equal '', described_class.extract_first_key([:get, nil])
    assert_equal '', described_class.extract_first_key([:get])

    assert_equal '', described_class.extract_first_key([:set, '', 1])
    assert_equal '', described_class.extract_first_key([:set, nil, 1])
    assert_equal '', described_class.extract_first_key([:set])

    # Keyless commands
    assert_equal '', described_class.extract_first_key([:auth, 'password'])
    assert_equal '', described_class.extract_first_key(%i[client kill])
    assert_equal '', described_class.extract_first_key(%i[cluster addslots])
    assert_equal '', described_class.extract_first_key(%i[command])
    assert_equal '', described_class.extract_first_key(%i[command count])
    assert_equal '', described_class.extract_first_key(%i[config get])
    assert_equal '', described_class.extract_first_key(%i[debug segfault])
    assert_equal '', described_class.extract_first_key([:echo, 'Hello World'])
    assert_equal '', described_class.extract_first_key([:flushall, 'ASYNC'])
    assert_equal '', described_class.extract_first_key([:flushdb, 'ASYNC'])
    assert_equal '', described_class.extract_first_key([:info, 'cluster'])
    assert_equal '', described_class.extract_first_key(%i[memory doctor])
    assert_equal '', described_class.extract_first_key([:ping, 'Hi'])
    assert_equal '', described_class.extract_first_key([:psubscribe, 'channel'])
    assert_equal '', described_class.extract_first_key([:pubsub, 'channels', '*'])
    assert_equal '', described_class.extract_first_key([:publish, 'channel', 'Hi'])
    assert_equal '', described_class.extract_first_key([:punsubscribe, 'channel'])
    assert_equal '', described_class.extract_first_key([:subscribe, 'channel'])
    assert_equal '', described_class.extract_first_key([:unsubscribe, 'channel'])
    assert_equal '', described_class.extract_first_key(%w[script exists sha1 sha1])
    assert_equal '', described_class.extract_first_key([:select, 1])
    assert_equal '', described_class.extract_first_key([:shutdown, 'SAVE'])
    assert_equal '', described_class.extract_first_key([:slaveof, '127.0.0.1', 6379])
    assert_equal '', described_class.extract_first_key([:slowlog, 'get', 2])
    assert_equal '', described_class.extract_first_key([:swapdb, 0, 1])
    assert_equal '', described_class.extract_first_key([:wait, 1, 0])

    # 2nd argument is not a key
    assert_equal 'key1', described_class.extract_first_key([:eval, 'script', 2, 'key1', 'key2', 'first', 'second'])
    assert_equal '', described_class.extract_first_key([:eval, 'return 0', 0])
    assert_equal 'key1', described_class.extract_first_key([:evalsha, 'sha1', 2, 'key1', 'key2', 'first', 'second'])
    assert_equal '', described_class.extract_first_key([:evalsha, 'return 0', 0])
    assert_equal 'key1', described_class.extract_first_key([:migrate, '127.0.0.1', 6379, 'key1', 0, 5000])
    assert_equal 'key1', described_class.extract_first_key([:memory, :usage, 'key1'])
    assert_equal 'key1', described_class.extract_first_key([:object, 'refcount', 'key1'])
    assert_equal 'mystream', described_class.extract_first_key([:xread, 'COUNT', 2, 'STREAMS', 'mystream', 0])
    assert_equal 'mystream', described_class.extract_first_key([:xreadgroup, 'GROUP', 'mygroup', 'Bob', 'COUNT', 2, 'STREAMS', 'mystream', '>'])
  end

  def test_whether_the_command_effect_is_readonly_or_not
    described_class = build_described_class

    assert_equal true,  described_class.should_send_to_master?([:set])
    assert_equal false, described_class.should_send_to_slave?([:set])

    assert_equal false, described_class.should_send_to_master?([:get])
    assert_equal true,  described_class.should_send_to_slave?([:get])

    target_version('3.2.0') do
      assert_equal false, described_class.should_send_to_master?([:info])
      assert_equal false, described_class.should_send_to_slave?([:info])
    end
  end
end
