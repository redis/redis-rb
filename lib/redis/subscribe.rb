# frozen_string_literal: true

class Redis
  class SubscribedClient
    # Upper bound on each guarded read (see #next_event) — and therefore on how
    # long a cross-thread write can wait for the monitor.
    READ_SLICE = 0.05
    private_constant :READ_SLICE

    def initialize(client)
      @client = client
      @write_monitor = Monitor.new
      # Count of writers waiting for (or holding) the monitor; mutations under
      # their own lock so it cannot drift. The read loop deschedules while
      # writers are queued — MRI mutexes barge, and on MRI 3.2 a writer can
      # otherwise starve behind consecutive read slices (Thread.pass is not a
      # handoff there).
      @pending_writes = 0
      @pending_writes_lock = Mutex.new
      @closed = false
    end

    def call_v(command)
      @pending_writes_lock.synchronize { @pending_writes += 1 }
      @write_monitor.synchronize do
        # A write must never reach a connection whose teardown is freeing it:
        # on the hiredis driver that is a native use-after-free (SIGSEGV), not
        # a rescuable exception.
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
      # Serialized with every write and guarded read: freeing the connection
      # under either crashes the process on the hiredis driver.
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

    # Reads the next subscription event in short monitor-guarded slices rather
    # than one indefinite read: on a connection error the driver's read path
    # disconnects the connection object in place (hiredis nulls its native
    # context), so an unguarded read racing a cross-thread write or #close is a
    # native use-after-free. Slicing under the writers' monitor means reads,
    # writes and close never overlap; a writer waits at most one slice.
    # Blocking semantics are preserved (a slice timeout just reads again); the
    # timed form keeps the caller's overall deadline, nil meaning "no event
    # within the requested timeout".
    def next_event(timeout)
      if timeout > 0
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          writer_priority_wait
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return nil if remaining <= 0

          event = guarded_read([remaining, READ_SLICE].min)
          return event if event
        end
      else
        loop do
          writer_priority_wait
          event = guarded_read(READ_SLICE)
          return event if event
        end
      end
    end

    def guarded_read(slice)
      @write_monitor.synchronize do
        raise SubscriptionError, "This client is closed" if @closed

        @client.next_event(slice)
      end
    end

    # Bounded writer priority: a queued writer gets the monitor before the next
    # read slice. sleep deterministically deschedules this thread (Thread.pass
    # is a hint MRI 3.2 ignores in favor of the barging re-acquirer); the bound
    # means a counter defect could only throttle reads, never stop them.
    def writer_priority_wait
      50.times do
        break if @pending_writes.zero?

        sleep 0.001
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
