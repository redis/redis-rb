require_relative 'helper'
require_relative 'lint/blocking_commands'

class TestDistributedBlockingCommands < Test::Unit::TestCase
  include Helper::Distributed
  include Lint::BlockingCommands

  def test_blpop_raises
    assert_raises(Redis::Distributed::CannotDistribute) do
      r.blpop(%w[key1 key4])
    end
  end

  def test_blpop_raises_with_old_prototype
    assert_raises(Redis::Distributed::CannotDistribute) do
      r.blpop('key1', 'key4', 0)
    end
  end

  def test_brpop_raises
    target_version('3.2.0') do
      # There is a bug Redis 3.0's COMMAND command
      assert_raises(Redis::Distributed::CannotDistribute) do
        r.brpop(%w[key1 key4])
      end
    end
  end

  def test_brpop_raises_with_old_prototype
    target_version('3.2.0') do
      # There is a bug Redis 3.0's COMMAND command
      assert_raises(Redis::Distributed::CannotDistribute) do
        r.brpop('key1', 'key4', 0)
      end
    end
  end

  def test_brpoplpush_raises
    assert_raises(Redis::Distributed::CannotDistribute) do
      r.brpoplpush('key1', 'key4')
    end
  end

  def test_brpoplpush_raises_with_old_prototype
    assert_raises(Redis::Distributed::CannotDistribute) do
      r.brpoplpush('key1', 'key4', 0)
    end
  end
end
