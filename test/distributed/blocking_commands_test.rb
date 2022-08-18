# frozen_string_literal: true

require "helper"

class TestDistributedBlockingCommands < Minitest::Test
  include Helper::Distributed
  include Lint::BlockingCommands

  def test_blmove_raises
    target_version "6.2" do
      assert_raises(Redis::Distributed::CannotDistribute) do
        r.blmove('foo', 'bar', 'LEFT', 'RIGHT')
      end
    end
  end

  def test_blpop_raises
    assert_raises(Redis::Distributed::CannotDistribute) do
      r.blpop(%w[foo bar])
    end
  end

  def test_brpop_raises
    assert_raises(Redis::Distributed::CannotDistribute) do
      r.brpop(%w[foo bar])
    end
  end

  def test_brpoplpush_raises
    assert_raises(Redis::Distributed::CannotDistribute) do
      r.brpoplpush('foo', 'bar')
    end
  end
end
