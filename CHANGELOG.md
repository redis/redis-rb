# 3.0 (unreleased)

* The repository now lives at [https://github.com/redis/redis-rb](https://github.com/redis/redis-rb).
  Thanks, Ezra!

* Added support for `PEXPIRE`, `PTTL`, `PEXPIREAT`, `PSETEX`,
  `INCRYBYFLOAT`, `HINCRYBYFLOAT` and `TIME` (Redis 2.6).

* `Redis.current` is now thread unsafe, because the client itself is thread safe.

    In the future you'll be able to do something like:

        Redis.current = Redis::Pool.connect

    This makes `Redis.current` actually usable in multi-threaded environments,
    while not affecting those running a single thread.

* Change API for `BLPOP`, `BRPOP` and `BRPOPLPUSH`. Both `BLPOP` and
  `BRPOP` now take a single argument equal to a string key, or an array
  with string keys, followed by an optional hash with a `:timeout` key.
  `BRPOPLPUSH` also takes an optional hash with a `:timeout` key as last
  argument for consistency. By default, these commands use a timeout of
  `0` to not time out.

* When `SORT` is passed multiple key patterns to get via the `:get`
  option, it now returns an array per result element, holding all `GET`
  substitutions.

* The `MSETNX` command now returns a boolean.

* The `ZRANGE`, `ZREVRANGE`, `ZRANGEBYSCORE` and `ZREVRANGEBYSCORE` commands
  now return an array containing `[String, Float]` pairs when
  `:with_scores => true` is passed.

* The `ZINCRBY` and `ZSCORE` commands now return a `Float` score instead
  of a string holding a representation of the score.

* The client now raises custom exceptions where it makes sense.

    If by any chance you were rescuing low-level exceptions (`Errno::*`),
    you should now rescue as follows:

        Errno::ECONNRESET    -> Redis::ConnectionError
        Errno::EPIPE         -> Redis::ConnectionError
        Errno::ECONNABORTED  -> Redis::ConnectionError
        Errno::EBADF         -> Redis::ConnectionError
        Errno::EINVAL        -> Redis::ConnectionError
        Errno::EAGAIN        -> Redis::TimeoutError
        Errno::ECONNREFUSED  -> Redis::CannotConnectError

* Always raise exceptions originating from erroneous command invocation
  inside pipelines and MULTI/EXEC blocks.

    The old behavior (swallowing exceptions) could cause application bugs
    to go unnoticed.

* Implement futures for assigning values inside pipelines and MULTI/EXEC
  blocks. Futures are assigned their value after the pipeline or
  MULTI/EXEC block has executed.

    ```ruby
    $redis.pipelined do
      @future = $redis.get "key"
    end

    puts @future.value
    ```

* Ruby 1.8.6 is officially not supported.

* Support `ZCOUNT` in `Redis::Distributed` (Michael Dungan).

* Pipelined commands now return the same replies as when called outside
  a pipeline.

    In the past, pipelined replies were returned without post-processing.

* Support `SLOWLOG` command (Michael Bernstein).

* Calling `SHUTDOWN` effectively disconnects the client (Stefan Kaes).

* Basic support for mapping commands so that they can be renamed on the
  server.

* Connecting using a URL now checks that a host is given.

    It's just a small sanity check, cf. #126

* Support variadic commands introduced in Redis 2.4.

# 2.2.2

* Added method `Redis::Distributed#hsetnx`.

# 2.2.1

* Internal API: Client#call and family are now called with a single array
  argument, since splatting a large number of arguments (100K+) results in a
  stack overflow on 1.9.2.

* The `INFO` command can optionally take a subcommand. When the subcommand is
  `COMMANDSTATS`, the client will properly format the returned statistics per
  command. Subcommands for `INFO` are available since Redis v2.3.0 (unstable).

* Change `IO#syswrite` back to the buffered `IO#write` since some Rubies do
  short writes for large (1MB+) buffers and some don't (see issue #108).

# 2.2.0

* Added method `Redis#without_reconnect` that ensures the client will not try
  to reconnect when running the code inside the specified block.

* Thread-safe by default. Thread safety can be explicitly disabled by passing
  `:thread_safe => false` as argument.

* Commands called inside a MULTI/EXEC no longer raise error replies, since a
  successful EXEC means the commands inside the block were executed.

* MULTI/EXEC blocks are pipelined.

* Don't disconnect on error replies.

* Use `IO#syswrite` instead of `IO#write` because write buffering is not
  necessary.

* Connect to a unix socket by passing the `:path` option as argument.

* The timeout value is coerced into a float, allowing sub-second timeouts.

* Accept both `:with_scores` _and_ `:withscores` as argument to sorted set
  commands.

* Use [hiredis](https://github.com/pietern/hiredis-rb) (v0.3 or higher) by
  requiring "redis/connection/hiredis".

* Use [em-synchrony](https://github.com/igrigorik/em-synchrony) by requiring
  "redis/connection/synchrony".

# 2.1.1

See commit log.
