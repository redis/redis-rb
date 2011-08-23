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
end
