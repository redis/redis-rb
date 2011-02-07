require "timeout"

class Redis
  class Connection < ::Hiredis::Ext::Connection

    def connect(*args)
      super
    rescue Errno::ETIMEDOUT
      raise Timeout::Error
    end

    def connect_unix(*args)
      super
    rescue Errno::ETIMEDOUT
      raise Timeout::Error
    end

    def read(*args)
      super
    rescue RuntimeError => err
      raise ::Redis::ProtocolError.new(err.message)
    end
  end
end
