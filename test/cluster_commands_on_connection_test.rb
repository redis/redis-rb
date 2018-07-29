# frozen_string_literal: true

require_relative 'helper'

# ruby -w -Itest test/cluster_commands_on_connection_test.rb
# @see https://redis.io/commands#connection
class TestClusterCommandsOnConnection < Test::Unit::TestCase
  include Helper::Cluster

  def test_auth
    redis_cluster_mock(auth: ->(*_) { '+OK' }) do |redis|
      assert_equal 'OK', redis.auth('my-password-123')
    end
  end

  def test_echo
    assert_equal 'hogehoge', redis.echo('hogehoge')
  end

  def test_ping
    assert_equal 'hogehoge', redis.ping('hogehoge')
  end

  def test_quit
    redis2 = build_another_client
    assert_equal 'OK', redis2.quit
  end

  def test_select
    assert_raise(Redis::CommandError, 'ERR SELECT is not allowed in cluster mode') do
      redis.select(1)
    end
  end

  def test_swapdb
    assert_raise(Redis::CommandError, 'ERR SWAPDB is not allowed in cluster mode') do
      redis.swapdb(1, 2)
    end
  end
end
