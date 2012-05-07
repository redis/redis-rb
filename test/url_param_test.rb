# encoding: UTF-8

require "helper"

class TestUrlParam < Test::Unit::TestCase

  include Helper

  def test_url_defaults_to_______________
    redis = Redis.connect

    assert "127.0.0.1" == redis.client.host
    assert 6379 == redis.client.port
    assert 0 == redis.client.db
    assert nil == redis.client.password
  end

  def test_allows_to_pass_in_a_url
    redis = Redis.connect :url => "redis://:secr3t@foo.com:999/2"

    assert "foo.com" == redis.client.host
    assert 999 == redis.client.port
    assert 2 == redis.client.db
    assert "secr3t" == redis.client.password
  end

  def test_override_url_if_path_option_is_passed
    redis = Redis.connect :url => "redis://:secr3t@foo.com/foo:999/2", :path => "/tmp/redis.sock"

    assert "/tmp/redis.sock" == redis.client.path
    assert nil == redis.client.host
    assert nil == redis.client.port
  end

  def test_overrides_url_if_another_connection_option_is_passed
    redis = Redis.connect :url => "redis://:secr3t@foo.com:999/2", :port => 1000

    assert "foo.com" == redis.client.host
    assert 1000 == redis.client.port
    assert 2 == redis.client.db
    assert "secr3t" == redis.client.password
  end

  def test_does_not_modify_the_passed_options
    options = { :url => "redis://:secr3t@foo.com:999/2" }

    Redis.connect(options)

    assert({ :url => "redis://:secr3t@foo.com:999/2" } == options)
  end

  def test_uses_redis_url_over_default_if_available
    ENV["REDIS_URL"] = "redis://:secr3t@foo.com:999/2"

    redis = Redis.connect

    assert "foo.com" == redis.client.host
    assert 999 == redis.client.port
    assert 2 == redis.client.db
    assert "secr3t" == redis.client.password

    ENV.delete("REDIS_URL")
  end
end
