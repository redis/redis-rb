# frozen_string_literal: true

require "helper"

class TestConnection < Minitest::Test
  include Helper::Client

  def test_provides_a_meaningful_inspect
    assert_equal "#<Redis client v#{Redis::VERSION} for redis://localhost:#{PORT}/15>", r.inspect
  end

  def test_connection_with_user_and_password
    target_version "6.0" do
      with_acl do |username, password|
        redis = Redis.new(OPTIONS.merge(username: username, password: password))
        assert_equal "PONG", redis.ping
      end
    end
  end

  def test_connection_with_default_user_and_password
    target_version "6.0" do
      with_default_user_password do |_username, password|
        redis = Redis.new(OPTIONS.merge(password: password))
        assert_equal "PONG", redis.ping
      end
    end
  end

  def test_connection_information
    assert_equal "localhost",                 r.connection.fetch(:host)
    assert_equal 6381,                        r.connection.fetch(:port)
    assert_equal 15,                          r.connection.fetch(:db)
    assert_equal "localhost:6381",            r.connection.fetch(:location)
    assert_equal "redis://localhost:6381/15", r.connection.fetch(:id)
  end

  def test_reconnect_on_readonly_errors
    tcp_server = TCPServer.new("127.0.0.1", 0)
    tcp_server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
    port = tcp_server.addr[1]

    server_thread = Thread.new do
      session = tcp_server.accept
      io = RubyConnection::BufferedIO.new(session, read_timeout: 1, write_timeout: 1)
      while command = RESP3.load(io)
        case command.first
        when "HELLO"
          session.write("_\r\n")
        when "PING"
          session.write("+PING\r\n")
        when "SET"
          session.write("-READONLY You can't write against a read only replica.\r\n")
        else
          session.write("-ERR Unknown command #{command.first}\r\n")
        end
      end
      session.close
    end

    redis = Redis.new(OPTIONS.merge(host: "127.0.0.1", port: port))
    redis.call("PING")
    assert_raises RedisClient::ReadOnlyError do
      redis.call("SET", "foo", "bar")
    end
    refute_predicate redis, :connected?
  ensure
    server_thread&.kill
  end

  def test_default_id_with_host_and_port
    redis = Redis.new(OPTIONS.merge(host: "host", port: "1234", db: 0))
    assert_equal "redis://host:1234/0", redis.connection.fetch(:id)
  end

  def test_default_id_with_host_and_port_and_ssl
    redis = Redis.new(OPTIONS.merge(host: 'host', port: '1234', db: 0, ssl: true))
    assert_equal "rediss://host:1234/0", redis.connection.fetch(:id)
  end

  def test_default_id_with_host_and_port_and_explicit_scheme
    redis = Redis.new(OPTIONS.merge(host: "host", port: "1234", db: 0))
    assert_equal "redis://host:1234/0", redis.connection.fetch(:id)
  end

  def test_default_id_with_path
    redis = Redis.new(OPTIONS.merge(path: "/tmp/redis.sock", db: 0))
    assert_equal "/tmp/redis.sock/0", redis.connection.fetch(:id)
  end

  def test_default_id_with_path_and_explicit_scheme
    redis = Redis.new(OPTIONS.merge(path: "/tmp/redis.sock", db: 0))
    assert_equal "/tmp/redis.sock/0", redis.connection.fetch(:id)
  end

  def test_override_id
    redis = Redis.new(OPTIONS.merge(id: "test"))
    assert_equal "test", redis.connection.fetch(:id)
  end

  def test_id_inside_multi
    redis         = Redis.new(OPTIONS)
    id            = nil
    connection_id = nil

    redis.multi do
      id            = redis.id
      connection_id = redis.connection.fetch(:id)
    end

    assert_equal "redis://localhost:6381/15", id
    assert_equal "redis://localhost:6381/15", connection_id
  end
end
