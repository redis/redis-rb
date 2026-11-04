# frozen_string_literal: true

class Redis
  module Commands
    module Server
      # Asynchronously rewrite the append-only file.
      #
      # @return [String] `OK`
      def bgrewriteaof
        send_command([:bgrewriteaof])
      end

      # Asynchronously save the dataset to disk.
      #
      # @return [String] `OK`
      def bgsave
        send_command([:bgsave])
      end

      # Get or set server configuration parameters.
      #
      # @param [Symbol] action e.g. `:get`, `:set`, `:resetstat`
      # @return [String, Hash] string reply, or hash when retrieving more than one
      #   property with `CONFIG GET`
      def config(action, *args)
        send_command([:config, action] + args) do |reply|
          if reply.is_a?(Array) && action == :get
            Hashify.call(reply)
          else
            reply
          end
        end
      end

      # Manage client connections.
      #
      # @param [String, Symbol] subcommand e.g. `kill`, `list`, `getname`, `setname`
      # @return [String, Hash] depends on subcommand
      def client(subcommand, *args)
        send_command([:client, subcommand] + args) do |reply|
          if subcommand.to_s == "list"
            reply.lines.map do |line|
              entries = line.chomp.split(/[ =]/)
              Hash[entries.each_slice(2).to_a]
            end
          else
            reply
          end
        end
      end

      # Return the number of keys in the selected database.
      #
      # @return [Integer]
      def dbsize
        send_command([:dbsize])
      end

      # Remove all keys from all databases.
      #
      # @param [Hash] options
      #   - `:async => Boolean`: async flush (default: false)
      # @return [String] `OK`
      def flushall(options = nil)
        if options && options[:async]
          send_command(%i[flushall async])
        else
          send_command([:flushall])
        end
      end

      # Remove all keys from the current database.
      #
      # @param [Hash] options
      #   - `:async => Boolean`: async flush (default: false)
      # @return [String] `OK`
      def flushdb(options = nil)
        if options && options[:async]
          send_command(%i[flushdb async])
        else
          send_command([:flushdb])
        end
      end

      # Get information and statistics about the server.
      #
      # @example Default sections
      #   redis.info
      # @example One section
      #   redis.info(:commandstats)
      #     # => { "get" => { "calls" => "2", ... }, ... }
      # @example Several sections at once (Redis 7.0)
      #   redis.info(:server, :clients)
      #
      # @param [Array<String, Symbol>] sections zero or more sections, e.g. `server`, `clients`,
      #   `commandstats`, `all`, `everything`. Passing more than one section requires Redis 7.0.
      # @return [Hash<String, String>] the parsed `INFO` output. When `commandstats` is the only
      #   section, the reply is nested per command instead: `{ "get" => { "calls" => "2", ... } }`.
      def info(*sections)
        sections.flatten!(1)
        sections.compact!
        send_command([:info].concat(sections)) do |reply|
          if reply.is_a?(String)
            reply = HashifyInfo.call(reply)

            if sections.size == 1 && sections.first.to_s == "commandstats"
              # Extract nested hashes for INFO COMMANDSTATS
              reply = Hash[reply.map do |k, v|
                v = v.split(",").map { |e| e.split("=") }
                [k[/^cmdstat_(.*)$/, 1], Hash[v]]
              end]
            end
          end

          reply
        end
      end

      # Get the UNIX time stamp of the last successful save to disk.
      #
      # @return [Integer]
      def lastsave
        send_command([:lastsave])
      end

      # Listen for all requests received by the server in real time.
      #
      # There is no way to interrupt this command.
      #
      # @yield a block to be called for every line of output
      # @yieldparam [String] line timestamp and command that was executed
      def monitor
        synchronize do |client|
          client = client.pubsub
          client.call_v([:monitor])
          loop do
            yield client.next_event
          end
        end
      end

      # Synchronously save the dataset to disk.
      #
      # @return [String]
      def save
        send_command([:save])
      end

      # Block until the write commands previously sent on this connection have been fsynced to
      # the append-only file of the local server and/or of the given number of replicas.
      #
      # The reply always reports how many local servers and replicas had fsynced the writes when
      # the command returned, whether or not the requested levels were reached, so compare it
      # against what you asked for. Inside `multi` the command does not block.
      #
      # On `Redis::Cluster` the command is sent to every primary and each count is the minimum
      # across them (the server's `agg_min` policy): `local` is `1` only if every primary
      # fsynced, and `replicas` is the fewest acks any shard received. This per-connection
      # guarantee does not hold inside `pipelined`/`multi` on cluster: `WAITAOF` carries no
      # `write` flag, so the driver routes it to an arbitrary node (a random primary, or a
      # replica when `replica: true`) rather than the node(s) that carried the pipeline's
      # writes, so the reply is shape-correct but unrelated to those writes.
      #
      # @example Wait for the local AOF fsync
      #   redis.set("foo", "bar")
      #   redis.waitaof(1, 0, 0)
      #     # => [1, 0]
      # @example Wait at most one second for one replica
      #   redis.waitaof(0, 1, 1000)
      #     # => [1, 0]
      #
      # @param [Integer] numlocal `1` to wait for the local AOF fsync, `0` to skip it. Requires
      #   `appendonly yes` on the server when set.
      # @param [Integer] numreplicas number of replicas that must acknowledge the fsync
      # @param [Integer] timeout maximum time to wait in milliseconds, `0` blocks indefinitely
      #
      # @return [Array<Integer>] `[local, replicas]`: the number of local servers (`0` or `1`) and
      #   replicas that had fsynced the writes
      def waitaof(numlocal, numreplicas, timeout)
        timeout = Integer(timeout)
        command = [:waitaof, Integer(numlocal), Integer(numreplicas), timeout]
        send_blocking_command(command, timeout / 1000.0)
      end

      # Start a hot-key tracking session (Redis 8.6).
      #
      # Keys are ranked by the share of CPU time and/or network bytes they consume while the
      # session runs. The session is server-wide state shared by every connection, and only one
      # can run at a time, so the command family is only available on a single-node client:
      # `Redis::Cluster` and `Redis::Distributed` raise `NotImplementedError`.
      #
      # @example Track the top 10 keys by CPU time and network bytes
      #   redis.hotkeys_start(metrics: [:cpu, :net], count: 10)
      #     # => "OK"
      # @example Track CPU time for one minute, sampling one command in five
      #   redis.hotkeys_start(metrics: :cpu, duration: 60, sample: 5)
      #     # => "OK"
      #
      # @param [Symbol, String, Array<Symbol, String>] metrics one or both of `:cpu` and `:net`
      # @param [Integer, nil] count keys to report per metric, `1` to `64` (server default `10`)
      # @param [Integer, nil] duration stop the session after this many seconds, `1` to `1_000_000`;
      #   without it the session runs until #hotkeys_stop
      # @param [Integer, nil] sample track one command in `sample` (server default `1`: every command)
      # @param [Array<Integer>, nil] slots cluster mode only: hash slots to track, all of them owned
      #   by the receiving node; the server rejects the option outside cluster mode
      # @return [String] `"OK"`
      # @raise [Redis::CommandError] when a session is already in progress or a value is out of range
      def hotkeys_start(metrics:, count: nil, duration: nil, sample: nil, slots: nil)
        metrics = Array(metrics).map { |metric| metric.to_s.upcase }
        raise ArgumentError, "metrics must not be empty" if metrics.empty?

        args = [:hotkeys, "START", "METRICS", metrics.size].concat(metrics)
        args << "COUNT" << Integer(count) if count
        args << "DURATION" << Integer(duration) if duration
        args << "SAMPLE" << Integer(sample) if sample
        slots = Array(slots)
        args.push("SLOTS", slots.size, *slots.map { |slot| Integer(slot) }) unless slots.empty?
        send_command(args)
      end

      # Return the results of the running or most recent hot-key tracking session (Redis 8.6).
      #
      # @example
      #   redis.hotkeys_get
      #     # => { "tracking-active" => 1, "sample-ratio" => 1, "selected-slots" => [[0, 16383]],
      #     #      "all-commands-all-slots-us" => 73, "net-bytes-all-commands-all-slots" => 311,
      #     #      "collection-start-time-unix-ms" => 1793782936885, "collection-duration-ms" => 4,
      #     #      "total-cpu-time-user-ms" => 0, "total-cpu-time-sys-ms" => 0, "total-net-bytes" => 311,
      #     #      "by-cpu-time-us" => [["product:1", 69], ["product:2", 4]],
      #     #      "by-net-bytes" => [["product:1", 285], ["product:2", 26]] }
      #
      # @return [Hash{String => Object}] the reply fields, keyed by the server's names. Always
      #   present: `tracking-active` (`1` or `0`), `sample-ratio`, `selected-slots` (`[first, last]`
      #   slot ranges), `all-commands-all-slots-us`, `net-bytes-all-commands-all-slots`,
      #   `collection-start-time-unix-ms` and `collection-duration-ms`. With the `:cpu` metric:
      #   `total-cpu-time-user-ms`, `total-cpu-time-sys-ms` and `by-cpu-time-us`; with `:net`:
      #   `total-net-bytes` and `by-net-bytes`. The `by-*` lists are `[key, Integer]` pairs,
      #   hottest first, with at most `count` entries (possibly none). When `slots:` was given to
      #   #hotkeys_start the per-slot counters `all-commands-selected-slots-us`,
      #   `net-bytes-all-commands-selected-slots` and, with sampling,
      #   `sampled-commands-selected-slots-us`, `net-bytes-sampled-commands-selected-slots` are added.
      # @return [nil] when no session was started, or after #hotkeys_reset
      def hotkeys_get
        send_command([:hotkeys, "GET"], &HashifyHotkeys)
      end

      # Stop the running hot-key tracking session, keeping its results for #hotkeys_get (Redis 8.6).
      #
      # @return [String] `"OK"`
      # @return [nil] when no session is active
      def hotkeys_stop
        send_command([:hotkeys, "STOP"])
      end

      # Release the resources of a stopped hot-key tracking session (Redis 8.6).
      #
      # @return [String] `"OK"`
      # @raise [Redis::CommandError] while a session is active; call #hotkeys_stop first
      def hotkeys_reset
        send_command([:hotkeys, "RESET"])
      end

      # Synchronously save the dataset to disk and then shut down the server.
      #
      # @example Default: save if a save point is configured, then exit
      #   redis.shutdown
      #     # => nil
      # @example Skip the RDB save and don't wait for lagging replicas (Redis 7.0)
      #   redis.shutdown(save: false, now: true)
      # @example Cancel an in-progress shutdown (Redis 7.0)
      #   redis.shutdown(abort: true)
      #     # => "OK"
      #
      # @param [Boolean, nil] save `true` forces an RDB save (`SAVE`), `false` skips it
      #   (`NOSAVE`); `nil` leaves the decision to the server's save points
      # @param [Boolean] now skip waiting for lagging replicas (Redis 7.0)
      # @param [Boolean] force ignore errors that would normally prevent the shutdown, such as a
      #   failed RDB or AOF write (Redis 7.0)
      # @param [Boolean] abort cancel a shutdown that is waiting for replicas (Redis 7.0)
      #
      # @return [nil] when the server shut down (the connection is closed without a reply)
      # @return [String] `OK` when `abort:` cancelled a pending shutdown
      def shutdown(save: nil, now: false, force: false, abort: false)
        args = [:shutdown]
        args << (save ? "SAVE" : "NOSAVE") unless save.nil?
        args << "NOW" if now
        args << "FORCE" if force
        args << "ABORT" if abort

        synchronize do |client|
          client.disable_reconnection do
            client.call_v(args)
          rescue ConnectionError
            # This means Redis has probably exited.
            nil
          end
        end
      end

      # Make the server a slave of another instance, or promote it as master.
      def slaveof(host, port)
        send_command([:slaveof, host, port])
      end

      # Interact with the slowlog (get, len, reset)
      #
      # @param [String] subcommand e.g. `get`, `len`, `reset`
      # @param [Integer] length maximum number of entries to return
      # @return [Array<String>, Integer, String] depends on subcommand
      def slowlog(subcommand, length = nil)
        args = [:slowlog, subcommand]
        args << Integer(length) if length
        send_command(args)
      end

      # Internal command used for replication.
      def sync
        send_command([:sync])
      end

      # Return the server time.
      #
      # @example
      #   r.time # => [ 1333093196, 606806 ]
      #
      # @return [Array<Integer>] tuple of seconds since UNIX epoch and
      #   microseconds in the current second
      def time
        send_command([:time]) do |reply|
          reply&.map(&:to_i)
        end
      end

      def debug(*args)
        send_command([:debug] + args)
      end
    end
  end
end
