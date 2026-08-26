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
      # Exact count of writers waiting for (or holding) the monitor — mutations
      # under their own tiny lock so a lost update cannot skew it for good. The
      # subscribed thread's read loop consults it (bare read: worst case one
      # stale slice) and DESCHEDULES while writers are queued: MRI mutexes
      # barge, and on MRI 3.2 the releasing reader reliably re-wins the monitor
      # over an already-woken writer — a mere Thread.pass hint does not hand
      # over, and a single write could starve behind consecutive read slices
      # for hundreds of milliseconds (measured: 13/40 writes > 100ms on 3.2,
      # 0/40 with the sleep-based wait; 3.3+ schedulers hand over either way).
      @pending_writes = 0
      @pending_writes_lock = Mutex.new
      @closed = false
    end

    def call_v(command)
      @pending_writes_lock.synchronize { @pending_writes += 1 }
      @write_monitor.synchronize do
        # Checked under the same monitor #close holds: a write must never reach
        # a connection whose teardown is freeing (or has freed) it — with the
        # hiredis driver that read-then-write is a native use-after-free
        # (SIGSEGV in redisBufferWrite), not a rescuable exception.
        raise SubscriptionError, "This client is closed" if @closed

        @client.call_v(command)
      end
    ensure
      @pending_writes_lock.synchronize { @pending_writes -= 1 }
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
      @pending_writes_lock.synchronize { @pending_writes += 1 }
      @write_monitor.synchronize do
        @closed = true
        @client.close
      end
    ensure
      @pending_writes_lock.synchronize { @pending_writes -= 1 }
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
        # Writer priority, bounded: writes are brief and rare, so a queued
        # writer gets the monitor before the next read slice starts. sleep —
        # unlike Thread.pass, which is a hint MRI 3.2's scheduler ignores in
        # favor of the barging re-acquirer — deterministically deschedules this
        # thread so the writer actually runs. Bounded, so a counter defect
        # could only ever throttle reads, never stop them.
        50.times do
          break if @pending_writes.zero?

          sleep 0.001
        end
        event = @write_monitor.synchronize do
          raise SubscriptionError, "This client is closed" if @closed

          @client.next_event(READ_SLICE)
        end
        return event if event
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
