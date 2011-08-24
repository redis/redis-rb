class Redis
  class Error < RuntimeError
  end

  class ProtocolError < Error
    def initialize(reply_type)
      super(<<-EOS.gsub(/(?:^|\n)\s*/, " "))
      Got '#{reply_type}' as initial reply byte.
      If you're running in a multi-threaded environment, make sure you
      pass the :thread_safe option when initializing the connection.
      If you're in a forking environment, such as Unicorn, you need to
      connect to Redis after forking.
      EOS
    end
  end

  class CannotDistribute < Error
    def initialize(command)
      @command = command
    end

    def message
      "#{@command.to_s.upcase} cannot be used in Redis::Distributed because the keys involved need to be on the same server or because we cannot guarantee that the operation will be atomic."
    end
  end
end
