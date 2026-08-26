# frozen_string_literal: true

class Redis
  class SubscribedClient
    # How long each of the subscription loop's guarded reads may block (see
    # #next_event): the upper bound on how long a cross-thread write (e.g. an
    # unsubscribe from another thread) can wait for the monitor.
    READ_SLICE = 0.05
    private_constant :READ_SLICE

    def initialize(client)
      @client = client
      @write_monitor = Monitor.new
      # Heuristic only (plain increments, no extra lock): tells the subscribed
      # thread's read loop that a writer is waiting on the monitor, so it yields
      # between slices instead of immediately re-acquiring (MRI mutexes barge).
      @pending_writes = 0
      @closed = false
    end

    def call_v(command)
      @pending_writes += 1
      @write_monitor.synchronize do
        # Checked under the same monitor #close holds: a write must never reach
        # a connection whose teardown is freeing (or has freed) it — with the
        # hiredis driver that read-then-write is a native use-after-free
        # (SIGSEGV in redisBufferWrite), not a rescuable exception.
        raise SubscriptionError, "This client is closed" if @closed

        @client.call_v(command)
      end
    ensure
      @pending_writes -= 1
    end

    def subscribe(*channels, &block)
      subscription("subscribe", "unsubscribe", channels, block)
    end

    def subscribe_with_timeout(timeout, *channels, &block)
      subscription("subscribe", "unsubscribe", channels, block, timeout)
    end

    def psubscribe(*channels, &block)
      subscription("psubscribe", "punsubscribe", channels, block)
    end

    def psubscribe_with_timeout(timeout, *channels, &block)
      subscription("psubscribe", "punsubscribe", channels, block, timeout)
    end

    def ssubscribe(*channels, &block)
      subscription("ssubscribe", "sunsubscribe", channels, block)
    end

    def ssubscribe_with_timeout(timeout, *channels, &block)
      subscription("ssubscribe", "sunsubscribe", channels, block, timeout)
    end

    def unsubscribe(*channels)
      call_v([:unsubscribe, *channels])
    end

    def punsubscribe(*channels)
      call_v([:punsubscribe, *channels])
    end

    def sunsubscribe(*channels)
      call_v([:sunsubscribe, *channels])
    end

    def close
      # Serialized with every write (see #call_v) and with the subscribed
      # thread's guarded reads (see #next_event): freeing the connection under
      # an in-flight write or read crashes the process on the hiredis driver —
      # the racing operation either completes first or observes the closed
      # client and raises.
      @pending_writes += 1
      @write_monitor.synchronize do
        @closed = true
        @client.close
      end
    ensure
      @pending_writes -= 1
    end

    protected

    def subscription(start, stop, channels, block, timeout = 0)
      sub = Subscription.new(&block)

      case start
      when "ssubscribe" then channels.each { |c| call_v([start, c]) } # avoid cross-slot keys
      else call_v([start, *channels])
      end

      while event = next_event(timeout)
        if event.is_a?(::RedisClient::CommandError)
          raise Client::ERROR_MAPPING.fetch(event.class), event.message
        end

        type, *rest = event
        if callback = sub.callbacks[type]
          callback.call(*rest)
        end
        break if type == stop && rest.last == 0
      end
      # No need to unsubscribe here. The real client closes the connection
      # whenever an exception is raised (see #ensure_connected).
    end

    # Reads the next subscription event. The blocking (no-timeout) form reads in
    # short monitor-guarded slices rather than one indefinite read: on a
    # connection error the driver's read path DISCONNECTS the connection object
    # in place (the hiredis driver nulls its native context mid-teardown), and a
    # cross-thread write racing that teardown — an unsubscribe from another
    # thread, or #close — dereferences the freed/nulled context: a native
    # use-after-free the write monitor alone cannot prevent, because the
    # teardown happens inside the read, not inside #close. Guarding each slice
    # with the same monitor writers hold means reads, writes and close can
    # never overlap; a writer waits at most one slice. Blocking semantics are
    # preserved: a slice timeout just reads again, and never leaks the nil the
    # with-timeout variants use as their loop exit.
    def next_event(timeout)
      return @client.next_event(timeout) if timeout > 0

      loop do
        event = @write_monitor.synchronize do
          raise SubscriptionError, "This client is closed" if @closed

          @client.next_event(READ_SLICE)
        end
        return event if event

        # MRI mutexes barge: releasing and immediately re-acquiring beats a
        # thread already waiting, so a pending writer could starve behind an
        # idle subscription. Yield the scheduler slot when one is queued.
        Thread.pass if @pending_writes > 0
      end
    end
  end

  class Subscription
    attr_reader :callbacks

    def initialize
      @callbacks = {}
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

    def ssubscribe(&block)
      @callbacks["ssubscribe"] = block
    end

    def sunsubscribe(&block)
      @callbacks["sunsubscribe"] = block
    end

    def smessage(&block)
      @callbacks["smessage"] = block
    end
  end
end
