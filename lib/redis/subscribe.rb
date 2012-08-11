class Redis
  class SubscribedClient
    def initialize(client)
      @client = client
    end

    def call(command)
      @client.process([command])
    end

    def subscribe(*channels, &block)
      subscription("subscribe", "unsubscribe", channels, block)
    end

    def psubscribe(*channels, &block)
      subscription("psubscribe", "punsubscribe", channels, block)
    end

    def unsubscribe(*channels)
      call([:unsubscribe, *channels])
    end

    def punsubscribe(*channels)
      call([:punsubscribe, *channels])
    end

  protected

    def subscription(start, stop, channels, block)
      sub = Subscription.new(&block)

      begin
        @client.call_loop([start, *channels]) do |line|
          type, *rest = line
          sub.callbacks[type].call(*rest)
          break if type == stop && rest.last == 0
        end
      ensure
        send(stop)
      end
    end
  end

  class Subscription
    attr :callbacks

    def initialize
      @callbacks = Hash.new do |hash, key|
        hash[key] = lambda { |*_| }
      end

      yield(self)
    end

    def subscribe(&block)
      @callbacks["subscribe"] = block
    end

    def unsubscribe(&block)
      @callbacks["unsubscribe"] = block
    end

    def message(&block)
      @callbacks["message"] = block
    end

    def psubscribe(&block)
      @callbacks["psubscribe"] = block
    end

    def punsubscribe(&block)
      @callbacks["punsubscribe"] = block
    end

    def pmessage(&block)
      @callbacks["pmessage"] = block
    end
  end
end
