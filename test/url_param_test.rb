require_relative "helper"

class TestUrlParam < Test::Unit::TestCase

  include Helper::Client

  def test_url_defaults_to_______________
    redis = Redis.new

    assert_equal "127.0.0.1", redis._client.host
    assert_equal 6379, redis._client.port
    assert_equal 0, redis._client.db
    assert_equal nil, redis._client.password
  end

  def test_allows_to_pass_in_a_url
    redis = Redis.new :url => "redis://:secr3t@foo.com:999/2"

    assert_equal "foo.com", redis._client.host
    assert_equal 999, redis._client.port
    assert_equal 2, redis._client.db
    assert_equal "secr3t", redis._client.password
  end

  def test_allows_to_pass_in_a_url_with_string_key
    redis = Redis.new "url" => "redis://:secr3t@foo.com:999/2"

    assert_equal "foo.com", redis._client.host
    assert_equal 999, redis._client.port
    assert_equal 2, redis._client.db
    assert_equal "secr3t", redis._client.password
  end

  def test_unescape_password_from_url
    redis = Redis.new :url => "redis://:secr3t%3A@foo.com:999/2"

    assert_equal "secr3t:", redis._client.password
  end

  def test_unescape_password_from_url_with_string_key
    redis = Redis.new "url" => "redis://:secr3t%3A@foo.com:999/2"

    assert_equal "secr3t:", redis._client.password
  end

  def test_does_not_unescape_password_when_explicitly_passed
    redis = Redis.new :url => "redis://:secr3t%3A@foo.com:999/2", :password => "secr3t%3A"

    assert_equal "secr3t%3A", redis._client.password
  end

  def test_does_not_unescape_password_when_explicitly_passed_with_string_key
    redis = Redis.new :url => "redis://:secr3t%3A@foo.com:999/2", "password" => "secr3t%3A"

    assert_equal "secr3t%3A", redis._client.password
  end

  def test_override_url_if_path_option_is_passed
    redis = Redis.new :url => "redis://:secr3t@foo.com/foo:999/2", :path => "/tmp/redis.sock"

    assert_equal "/tmp/redis.sock", redis._client.path
    assert_equal nil, redis._client.host
    assert_equal nil, redis._client.port
  end

  def test_override_url_if_path_option_is_passed_with_string_key
    redis = Redis.new :url => "redis://:secr3t@foo.com/foo:999/2", "path" => "/tmp/redis.sock"

    assert_equal "/tmp/redis.sock", redis._client.path
    assert_equal nil, redis._client.host
    assert_equal nil, redis._client.port
  end

  def test_overrides_url_if_another_connection_option_is_passed
    redis = Redis.new :url => "redis://:secr3t@foo.com:999/2", :port => 1000

    assert_equal "foo.com", redis._client.host
    assert_equal 1000, redis._client.port
    assert_equal 2, redis._client.db
    assert_equal "secr3t", redis._client.password
  end

  def test_overrides_url_if_another_connection_option_is_passed_with_string_key
    redis = Redis.new :url => "redis://:secr3t@foo.com:999/2", "port" => 1000

    assert_equal "foo.com", redis._client.host
    assert_equal 1000, redis._client.port
    assert_equal 2, redis._client.db
    assert_equal "secr3t", redis._client.password
  end

  def test_does_not_overrides_url_if_a_nil_option_is_passed
    redis = Redis.new :url => "redis://:secr3t@foo.com:999/2", :port => nil

    assert_equal "foo.com", redis._client.host
    assert_equal 999, redis._client.port
    assert_equal 2, redis._client.db
    assert_equal "secr3t", redis._client.password
  end

  def test_does_not_overrides_url_if_a_nil_option_is_passed_with_string_key
    redis = Redis.new :url => "redis://:secr3t@foo.com:999/2", "port" => nil

    assert_equal "foo.com", redis._client.host
    assert_equal 999, redis._client.port
    assert_equal 2, redis._client.db
    assert_equal "secr3t", redis._client.password
  end

  def test_does_not_modify_the_passed_options
    options = { :url => "redis://:secr3t@foo.com:999/2" }

    Redis.new(options)

    assert({ :url => "redis://:secr3t@foo.com:999/2" } == options)
  end

  def test_uses_redis_url_over_default_if_available
    ENV["REDIS_URL"] = "redis://:secr3t@foo.com:999/2"

    redis = Redis.new

    assert_equal "foo.com", redis._client.host
    assert_equal 999, redis._client.port
    assert_equal 2, redis._client.db
    assert_equal "secr3t", redis._client.password

    ENV.delete("REDIS_URL")
  end

  def test_defaults_to_localhost
    redis = Redis.new(:url => "redis:///")

    assert_equal "127.0.0.1", redis._client.host
  end
end
