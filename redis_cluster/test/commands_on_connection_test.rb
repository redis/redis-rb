# frozen_string_literal: true

require "helper"
require 'lint/authentication'

# ruby -w -Itest test/cluster_commands_on_connection_test.rb
# @see https://redis.io/commands#connection
class TestClusterCommandsOnConnection < Minitest::Test
  include Helper::Cluster
  include Lint::Authentication

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
    assert_raises(Redis::CommandError, 'ERR SELECT is not allowed in cluster mode') do
      redis.select(1)
    end
  end

  def test_swapdb
    assert_raises(Redis::CommandError, 'ERR SWAPDB is not allowed in cluster mode') do
      redis.swapdb(1, 2)
    end
  end

  def mock(*args, &block)
    redis_cluster_mock(*args, &block)
  end
end
