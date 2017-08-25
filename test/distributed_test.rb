require_relative "helper"

class TestDistributed < Test::Unit::TestCase

  include Helper::Distributed

  def test_handle_multiple_servers
    @r = Redis::Distributed.new ["redis://127.0.0.1:#{PORT}/15", *NODES]

    100.times do |idx|
      @r.set(idx.to_s, "foo#{idx}")
    end

    100.times do |idx|
      assert_equal "foo#{idx}", @r.get(idx.to_s)
    end

    assert_equal "0", @r.keys("*").sort.first
    assert_equal "string", @r.type("1")
  end

  def test_add_nodes
    logger = Logger.new("/dev/null")

    @r = Redis::Distributed.new NODES, :logger => logger, :timeout => 10

    assert_equal "127.0.0.1", @r.nodes[0]._client.host
    assert_equal PORT, @r.nodes[0]._client.port
    assert_equal 15, @r.nodes[0]._client.db
    assert_equal 10, @r.nodes[0]._client.timeout
    assert_equal logger, @r.nodes[0]._client.logger

    @r.add_node("redis://127.0.0.1:6380/14")

    assert_equal "127.0.0.1", @r.nodes[1]._client.host
    assert_equal 6380, @r.nodes[1]._client.port
    assert_equal 14, @r.nodes[1]._client.db
    assert_equal 10, @r.nodes[1]._client.timeout
    assert_equal logger, @r.nodes[1]._client.logger
  end

  def test_pipelining_commands_cannot_be_distributed
    assert_raise Redis::Distributed::CannotDistribute do
      r.pipelined do
        r.lpush "foo", "s1"
        r.lpush "foo", "s2"
      end
    end
  end

  def test_unknown_commands_does_not_work_by_default
    assert_raise NoMethodError do
      r.not_yet_implemented_command
    end
  end
end
