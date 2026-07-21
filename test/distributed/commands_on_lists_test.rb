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

  def test_lmovem
    target_version "8.9" do
      assert_raises Redis::Distributed::CannotDistribute do
        r.lmovem('foo', 'bar', 'LEFT', 'RIGHT')
      end
    end
  end

  def test_lmovem_count_obo
    target_version "8.9" do
      assert_raises Redis::Distributed::CannotDistribute do
        r.lmovem('foo', 'bar', 'LEFT', 'LEFT', count: 3, order: 'OBO')
      end
    end
  end

  def test_lmovem_count_bulk
    target_version "8.9" do
      assert_raises Redis::Distributed::CannotDistribute do
        r.lmovem('foo', 'bar', 'LEFT', 'LEFT', count: 3, order: 'BULK')
      end
    end
  end

  def test_lmovem_exactly
    target_version "8.9" do
      assert_raises Redis::Distributed::CannotDistribute do
        r.lmovem('foo', 'bar', 'LEFT', 'RIGHT', exactly: 2, order: 'BULK')
      end
    end
  end

  def test_lmovem_argument_errors
    target_version "8.9" do
      assert_raises Redis::Distributed::CannotDistribute do
        r.lmovem('foo', 'bar', 'LEFT', 'RIGHT', count: 1, order: 'BULK')
      end
    end
  end

  def test_lmovem_with_key_tags
    target_version "8.9" do
      r.rpush('{tag}foo', %w[1 2 3])

      assert_equal %w[1 2], r.lmovem('{tag}foo', '{tag}bar', 'LEFT', 'RIGHT', count: 2, order: 'BULK')
      assert_equal %w[1 2], r.lrange('{tag}bar', 0, -1)
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
