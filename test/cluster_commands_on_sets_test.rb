# frozen_string_literal: true

require_relative 'helper'
require_relative 'lint/sets'

# ruby -w -Itest test/cluster_commands_on_sets_test.rb
# @see https://redis.io/commands#set
class TestClusterCommandsOnSets < Test::Unit::TestCase
  include Helper::Cluster
  include Lint::Sets

  def test_sdiff
    assert_raise(Redis::CommandError) { super }
  end

  def test_sdiffstore
    assert_raise(Redis::CommandError) { super }
  end

  def test_sinter
    assert_raise(Redis::CommandError) { super }
  end

  def test_sinterstore
    assert_raise(Redis::CommandError) { super }
  end

  def test_smove
    assert_raise(Redis::CommandError) { super }
  end

  def test_sunion
    assert_raise(Redis::CommandError) { super }
  end

  def test_sunionstore
    assert_raise(Redis::CommandError) { super }
  end
end
