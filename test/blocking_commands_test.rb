require_relative 'helper'
require_relative 'lint/blocking_commands'

class TestBlockingCommands < Minitest::Test
  include Helper::Client
  include Lint::BlockingCommands

  def assert_takes_longer_than_client_timeout
    timeout = LOW_TIMEOUT
    delay = timeout * 5

    mock(delay: delay) do |r|
      t1 = Time.now
      yield(r)
      t2 = Time.now

      assert timeout == r._client.timeout
      assert delay <= (t2 - t1)
    end
  end

  def test_blpop_disable_client_timeout
    assert_takes_longer_than_client_timeout do |r|
      assert_equal %w[foo 0], r.blpop('foo')
    end
  end

  def test_brpop_disable_client_timeout
    assert_takes_longer_than_client_timeout do |r|
      assert_equal %w[foo 0], r.brpop('foo')
    end
  end

  def test_brpoplpush_disable_client_timeout
    assert_takes_longer_than_client_timeout do |r|
      assert_equal '0', r.brpoplpush('foo', 'bar')
    end
  end

  def test_brpoplpush_in_transaction
    results = r.multi do
      r.brpoplpush('foo', 'bar')
      r.brpoplpush('foo', 'bar', timeout: 2)
    end
    assert_equal [nil, nil], results
  end

  def test_brpoplpush_in_pipeline
    mock do |r|
      results = r.pipelined do
        r.brpoplpush('foo', 'bar')
        r.brpoplpush('foo', 'bar', timeout: 2)
      end
      assert_equal ['0', '2'], results
    end
  end
end
