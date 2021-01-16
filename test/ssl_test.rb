# frozen_string_literal: true

require_relative "helper"

class SslTest < Minitest::Test
  include Helper::Client

  driver(:ruby) do
    def test_connection_to_non_ssl_server
      assert_raises(Redis::CannotConnectError) do
        redis = Redis.new(OPTIONS.merge(ssl: true, timeout: LOW_TIMEOUT))
        redis.ping
      end
    end

    def test_verified_ssl_connection
      RedisMock.start({ ping: proc { "+PONG" } }, ssl_server_opts("trusted")) do |port|
        redis = Redis.new(port: port, ssl: true, ssl_params: { ca_file: ssl_ca_file })
        assert_equal redis.ping, "PONG"
      end
    end

    def test_unverified_ssl_connection
      assert_raises(OpenSSL::SSL::SSLError) do
        RedisMock.start({ ping: proc { "+PONG" } }, ssl_server_opts("untrusted")) do |port|
          redis = Redis.new(port: port, ssl: true, ssl_params: { ca_file: ssl_ca_file })
          redis.ping
        end
      end
    end

    def test_verify_certificates_by_default
      assert_raises(OpenSSL::SSL::SSLError) do
        RedisMock.start({ ping: proc { "+PONG" } }, ssl_server_opts("untrusted")) do |port|
          redis = Redis.new(port: port, ssl: true)
          redis.ping
        end
      end
    end

    def test_ssl_blocking
      RedisMock.start({}, ssl_server_opts("trusted")) do |port|
        redis = Redis.new(port: port, ssl: true, ssl_params: { ca_file: ssl_ca_file })
        assert_equal redis.set("boom", "a" * 10_000_000), "OK"
      end
    end
  end

  driver(:hiredis, :synchrony) do
    def test_ssl_not_implemented_exception
      assert_raises(NotImplementedError) do
        RedisMock.start({ ping: proc { "+PONG" } }, ssl_server_opts("trusted")) do |port|
          redis = Redis.new(port: port, ssl: true, ssl_params: { ca_file: ssl_ca_file })
          redis.ping
        end
      end
    end
  end

  if ENV['BUILD_TLS'] == 'yes'
    driver(:ruby) do
      NON_TLS_PORT = 6381
      TLS_PORT = 6383

      def test_verified_ssl_connection_between_client_and_server
        redis = Redis.new(port: TLS_PORT, ssl: true, ssl_params: client_ssl_params_for_mutual_tls('trusted'))
        assert_equal redis.ping, 'PONG'
        redis.quit
      end

      def test_unverified_ssl_client
        assert_raises(OpenSSL::SSL::SSLError) do
          redis = Redis.new(port: TLS_PORT, ssl: true, ssl_params: client_ssl_params_for_mutual_tls('untrusted'))
          redis.ping
        end
      end

      def test_connection_to_non_ssl_port
        assert_raises(Redis::CannotConnectError) do
          redis = Redis.new(port: NON_TLS_PORT, ssl: true, ssl_params: client_ssl_params_for_mutual_tls('trusted'), timeout: LOW_TIMEOUT)
          redis.ping
        end
      end

      def test_verified_ssl_connection_with_blocking
        redis = Redis.new(port: TLS_PORT, ssl: true, ssl_params: client_ssl_params_for_mutual_tls('trusted'))
        assert_equal redis.set('boom', 'a' * 10_000_000), 'OK'
        redis.quit
      end
    end
  end

  private

  def ssl_server_opts(prefix)
    { ssl: true, ssl_params: load_cert_files(prefix) }
  end

  def client_ssl_params_for_mutual_tls(prefix)
    load_cert_files(prefix).merge(ca_file: ssl_ca_file(prefix))
  end

  def load_cert_files(prefix)
    cert = File.join(cert_path, "#{prefix}-cert.crt")
    key  = File.join(cert_path, "#{prefix}-cert.key")
    { cert: OpenSSL::X509::Certificate.new(File.read(cert)),
      key: OpenSSL::PKey::RSA.new(File.read(key)) }
  end

  def ssl_ca_file(prefix = 'trusted')
    File.join(cert_path, "#{prefix}-ca.crt")
  end

  def cert_path
    File.expand_path('support/ssl', __dir__)
  end
end
