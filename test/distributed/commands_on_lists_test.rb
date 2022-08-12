# frozen_string_literal: true

require "helper"

class TestDistributedCommandsOnLists < Minitest::Test
  include Helper::Distributed
  include Lint::Lists

  def test_lmove
    target_version "6.2" do
      assert_raises Redis::Distributed::CannotDistribute do
        r.lmove('foo', 'bar', 'LEFT', 'RIGHT')
      end
    end
  end

  def test_rpoplpush
    assert_raises Redis::Distributed::CannotDistribute do
      r.rpoplpush('foo', 'bar')
    end
  end

  def test_brpoplpush
    assert_raises Redis::Distributed::CannotDistribute do
      r.brpoplpush('foo', 'bar', timeout: 1)
    end
  end
end
