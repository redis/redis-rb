# frozen_string_literal: true

require "helper"

# ruby -w -Itest test/cluster_commands_on_sets_test.rb
# @see https://redis.io/commands#set
class TestClusterCommandsOnSets < Minitest::Test
  include Helper::Cluster
  include Lint::Sets

  def test_sdiff
    assert_raises(Redis::CommandError) { super }
  end

  def test_sdiffstore
    assert_raises(Redis::CommandError) { super }
  end

  def test_sinter
    assert_raises(Redis::CommandError) { super }
  end

  def test_sinterstore
    assert_raises(Redis::CommandError) { super }
  end

  def test_smove
    assert_raises(Redis::CommandError) { super }
  end

  def test_sunion
    assert_raises(Redis::CommandError) { super }
  end

  def test_sunionstore
    assert_raises(Redis::CommandError) { super }
  end
end
