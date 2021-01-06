# frozen_string_literal: true

module Lint
  module Authentication
    def test_auth_with_password
      mock(auth: ->(*_) { '+OK' }) do |r|
        assert_equal 'OK', r.auth('mysecret')
      end

      mock(auth: ->(*_) { '-ERR some error' }) do |r|
        assert_raises(Redis::BaseError) { r.auth('mysecret') }
      end
    end

    def test_auth_for_acl
      target_version "6.0.0" do
        with_acl do |username, password|
          assert_raises(Redis::BaseError) { redis.auth(username, 'wrongpassword') }
          assert_equal 'OK', redis.auth(username, password)
          assert_equal 'PONG', redis.ping
          assert_raises(Redis::BaseError) { redis.echo('foo') }
        end
      end
    end

    def mock(*args, &block)
      redis_mock(*args, &block)
    end
  end
end
