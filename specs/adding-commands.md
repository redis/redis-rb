# Adding a New Command to redis-rb

A practical, end-to-end guide for adding support for a new Redis command (or a new wrapper around an existing one). Covers every place you need to touch, the patterns to follow, and the testing matrix that will catch the mistakes most contributors make.

If you read only one thing: in the typical case you edit **two files** (the command module and `distributed.rb`) and add **two or three test files** (one lint module + per-client test stubs). Everything else is automated by the project's structure.

---

## 1. Where the command DSL lives

### File layout

The high-level command DSL is split per Redis category under `lib/redis/commands/`:

```
lib/redis/commands.rb              # the umbrella Commands module
lib/redis/commands/bitmaps.rb
lib/redis/commands/cluster.rb
lib/redis/commands/connection.rb
lib/redis/commands/geo.rb
lib/redis/commands/hashes.rb
lib/redis/commands/hyper_log_log.rb
lib/redis/commands/keys.rb
lib/redis/commands/lists.rb
lib/redis/commands/pubsub.rb
lib/redis/commands/scripting.rb
lib/redis/commands/server.rb
lib/redis/commands/sets.rb
lib/redis/commands/sorted_sets.rb
lib/redis/commands/streams.rb
lib/redis/commands/strings.rb
lib/redis/commands/transactions.rb
```

Match the category to what the [Redis command reference](https://redis.io/commands/) groups the command under. If in doubt, look at the existing neighbors of the most similar command.

### How they compose

Each file defines a `module` namespaced under `Redis::Commands::<Category>` containing plain instance methods. The umbrella module (`lib/redis/commands.rb:20-37`) `include`s all of them:

```ruby
module Commands
  include Bitmaps
  include Cluster
  include Connection
  include Geo
  include Hashes
  include HyperLogLog
  include Keys
  include Lists
  include Pubsub
  include Scripting
  include Server
  include Sets
  include SortedSets
  include Streams
  include Strings
  include Transactions
  ...
end
```

`Commands` is then mixed in to:

- `Redis` (`lib/redis.rb:37`) — standalone and sentinel-configured clients
- `Redis::PipelinedConnection` and `Redis::MultiConnection` (`lib/redis/pipeline.rb:15`, `:59`) — the block-yielded objects inside `pipelined` / `multi`
- Transitively into `Redis::Cluster` via inheritance (`cluster/lib/redis/cluster.rb:6`: `class Redis::Cluster < ::Redis`)

**Practical consequence:** one method definition in `lib/redis/commands/<category>.rb` becomes callable on every client type and inside every pipeline/transaction. The one exception is `Redis::Distributed`, which does **not** include `Commands` — see §6.

### Anatomy of a command method

The simplest possible command takes a key and returns whatever the server returns:

```ruby
# lib/redis/commands/strings.rb
def get(key)
  send_command([:get, key])
end
```

Three rules apply to every command method:

1. **Build a command array** of the form `[:verb, *args]`. The verb is a `Symbol`; the rest are positional args in the order they go on the wire. `redis-client` will serialize symbols and integers/floats to strings.
2. **Call `send_command`** (or `send_blocking_command` if blocking) — never reach for `@client` directly. The mixing class provides the right implementation: `Redis#send_command` synchronizes and translates errors; `PipelinedConnection#send_command` buffers and returns a `Future`.
3. **Coerce arguments at the boundary** when the type matters. Use `Integer(x)`, `Float(x)`, `value.to_s` to fail fast on bad input. Examples in `lib/redis/commands/strings.rb:27-29`:

   ```ruby
   def decrby(key, decrement)
     send_command([:decrby, key, Integer(decrement)])
   end
   ```

   The `Integer(decrement)` raises `TypeError` for non-numeric input, which is better than letting the server return a confusing protocol error.

### Adding keyword-flag commands

For commands with optional flags (most Redis 6+ commands), follow the `SET` pattern (`lib/redis/commands/strings.rb:83-99`):

```ruby
def set(key, value, ex: nil, px: nil, exat: nil, pxat: nil, nx: nil, xx: nil, keepttl: nil, get: nil)
  args = [:set, key, value.to_s]
  args << "EX" << Integer(ex) if ex
  args << "PX" << Integer(px) if px
  args << "EXAT" << Integer(exat) if exat
  args << "PXAT" << Integer(pxat) if pxat
  args << "NX" if nx
  args << "XX" if xx
  args << "KEEPTTL" if keepttl
  args << "GET" if get

  if nx || xx
    send_command(args, &BoolifySet)
  else
    send_command(args)
  end
end
```

- Use keyword args (`ex: nil`) for flags. Avoid positional booleans.
- Build the array imperatively with `args << "FLAG"`. Don't use conditional array literals — they get unreadable fast.
- Capitalize flag names (`"EX"`, `"NX"`, `"WITHSCORES"`) — Redis is case-insensitive on the wire but the convention is uppercase.
- If the **return shape depends on flags** (e.g., `SET NX` returns `nil` instead of `"OK"` on conflict), branch the `send_command` call as `set` does — pass the appropriate reshape lambda (§4) per branch.

### YARD docstrings

Every public command method carries a YARD docstring with `@param`, `@option` (for keyword args), `@return`, `@example`, and `@see` where relevant. This drives `rubydoc.info` documentation. Match the style of the surrounding methods exactly; the docs are how users learn the API surface.

```ruby
# Increment the integer value of a key by one.
#
# @example
#   redis.incr("value")
#     # => 6
#
# @param [String] key
# @return [Integer] value after incrementing it
def incr(key)
  send_command([:incr, key])
end
```

### What goes in `Commands::<Category>` vs elsewhere

- **Per-key Redis verbs** → the appropriate `Commands::<Category>` module.
- **Connection-lifecycle commands** (AUTH, PING, ECHO, SELECT, QUIT) → `Commands::Connection`. Note that `quit` (`lib/redis/commands/connection.rb:43-50`) deliberately uses `synchronize` directly and swallows `ConnectionError` — these patterns exist for the connection layer specifically.
- **Server-wide commands** (FLUSHALL, BGSAVE, INFO, DEBUG) → `Commands::Server`.
- **Pub/Sub** is special — it goes in `Commands::Pubsub` and routes through `Redis#_subscription` (`lib/redis.rb:166-189`) rather than `send_command`. Only add to this module if you understand the second-socket model; see §3.

---

## 2. Command execution flow

Trace a single `redis.incr("k")` through the stack so you know what each layer does and where to intervene if something is wrong.

```
User call:   redis.incr("k")
              │
              ▼
Commands::Strings#incr                     lib/redis/commands/strings.rb:39
   builds [:incr, "k"], calls send_command
              │
              ▼
Redis#send_command                         lib/redis.rb:152-158
   - acquires @monitor (reentrant lock)
   - rescues RedisClient::Error → Redis::* translation
              │
              ▼
Redis::Client#call_v                       lib/redis/client.rb:96-100
   - rescues RedisClient::Error → translate_error!
              │
              ▼
RedisClient#call_v                         (redis-client gem, external)
   - ensure_connected: opens socket on first use, runs handshake
   - serializes [:incr, "k"] to RESP bytes
   - writes to socket
   - reads RESP reply, returns native Ruby value
              │
              ▼ (raw reply, e.g. Integer 7)
optional reshape block (lambda passed via &)
   e.g. &Floatify, &Hashify, &BoolifySet
              │
              ▼
return value to caller
```

Two important facts about this flow:

- **Connect is lazy.** The first call triggers `RedisClient#ensure_connected`, which opens the socket, runs the `connection_prelude` (HELLO/AUTH, SELECT, CLIENT SETINFO, then CLIENT SETNAME and ROLE), and caches the connection. Subsequent calls reuse it. Don't try to "warm" a connection by calling `Redis.new` and assume the socket is open.
- **`send_command` is private and protocol-coupled.** Don't expose it. If a command needs special pre/post processing, put the logic in the public command method, not by overriding `send_command`.

### Pipelines and transactions

Inside `redis.pipelined { |p| p.incr("k") }`, `p` is a `Redis::PipelinedConnection` that also `include`s `Commands` (`lib/redis/pipeline.rb:15`). The same `incr` method is invoked, but `PipelinedConnection#send_command` (`lib/redis/pipeline.rb:40-47`) buffers the command and returns a `Redis::Future` instead of the value:

```ruby
def send_command(command, &block)
  future = Future.new(command, block, @exception)
  @pipeline.call_v(command) do |result|
    future._set(result)
  end
  @futures << future
  future
end
```

**Implication:** if your command method does *anything* other than `send_command(args, &block)` — for instance, calls a second command, transforms the result before reshape, or branches based on the reply — that logic will execute differently in pipelines. Test the pipelined path explicitly (§6).

### Blocking commands

For commands that block on the server side (BLPOP, BRPOP, XREAD with BLOCK, etc.), use `send_blocking_command` instead of `send_command`. It accepts a `timeout` parameter that's added on top of the connection's read timeout to avoid spurious timeouts:

```ruby
def blpop(*args)
  timeout = args.last.is_a?(Numeric) ? args.pop : 0
  send_blocking_command([:blpop, *args, timeout], timeout)
end
```

`Redis#send_blocking_command` (`lib/redis.rb:160-164`) inflates the client read timeout for the duration of the call. Inside a `multi { }` block, blocking commands are downgraded to non-blocking (`lib/redis/pipeline.rb:64-71`) per Redis server semantics — you don't need to handle that.

---

## 3. Relations with downstream libraries

### The dependency tree

```
redis-rb (this repo, lib/)                  ← high-level DSL
  └─ redis-client (Shopify)                 ← RESP parser, sockets, sentinel, pipelines

redis-clustering (this repo, cluster/)      ← Redis::Cluster < Redis
  ├─ redis (above)                          ← pinned to exact same version
  └─ redis-cluster-client (Shopify)         ← cluster topology, slot routing
       └─ redis-client                      ← shared base
```

Important facts:

- The cluster gem **depends on `redis`** (`cluster/redis-clustering.gemspec:49`: `s.add_runtime_dependency('redis', s.version)`), pinned to the exact same version. Both gemspecs read from the same `lib/redis/version.rb`, so one version bump moves both gems together — you never edit the dependency line by hand.
- `redis-cluster-client` does **not** depend on `redis-rb`. It is a peer driver, not a downstream consumer.
- `redis-cluster-client` is unaware of the redis-rb DSL. It receives command arrays (e.g. `["INCR", "k"]`) and routes them based on the command name, looking up key positions in a catalog built from the Redis server's own `COMMAND` introspection.

### What this means when you add a command

| You add… | Where the change lives | Coordination needed with downstream? |
| --- | --- | --- |
| A Ruby wrapper around an existing Redis verb | `lib/redis/commands/<category>.rb` | None. `redis-client` already knows how to serialize/parse it; `redis-cluster-client` already knows how to route it. |
| A Ruby wrapper around a brand-new Redis verb (newly added in some Redis version) | Same as above | None *at runtime*, provided your Redis server is recent enough that `COMMAND` describes the new verb. For routing-fast-path optimization, `redis-cluster-client` may need a catalog update, but routing is correct either way (it falls back to MOVED-follow). |
| A new client-side reshape of an existing verb | Same as above + a reshape lambda (§4) | None. Reshapes live entirely in redis-rb. |
| Behavior that needs RESP3 protocol features (push messages, native maps, client tracking) | Not supported in redis-rb. Drop down to `RedisClient` directly. | n/a — see CLAUDE.md "RESP2 invariant" |

### The error translation contract

Every error class that crosses the boundary from `redis-client` into `redis-rb` is remapped via `Redis::Client::ERROR_MAPPING` (`lib/redis/client.rb:5-20`). If your new command can raise a `RedisClient::Error` subclass that's not already in the mapping, add an entry. The cluster gem extends this in `Redis::Cluster::Client::ERROR_MAPPING` (`cluster/lib/redis/cluster/client.rb:9-16`) for cluster-only error types — add there too if cluster has a specific case.

Do not catch `RedisClient::Error` inside a command method. Let it propagate to `Redis::Client#call_v` and be translated centrally.

---

## 4. The reshape callback layer

### What it is

Many Redis commands return reply shapes that aren't idiomatic Ruby — flat arrays where a Hash would be natural, string `"3.14"` where a `Float` would be natural, integer `0`/`1` where a `Boolean` would be natural. redis-rb shapes these at the redis-rb layer via small lambda constants at the top of `lib/redis/commands.rb:42-194`.

The lambdas are passed as block arguments to `send_command`:

```ruby
def incrbyfloat(key, increment)
  send_command([:incrbyfloat, key, Float(increment)], &Floatify)
end
```

`send_command` forwards the block to `redis-client`, which calls it on the raw reply before returning. So the user sees `1.23` (a Float), not `"1.23"` (a string).

### The catalog

These are the existing reshape lambdas. **Reuse before you invent.**

| Lambda | Use case | Example |
| --- | --- | --- |
| `Boolify` | Integer `0`/`1` reply → `false`/`true`. Passes `nil` through. | `EXISTS`, `EXPIRE`, `SETNX` |
| `BoolifySet` | `"OK"` → `true`, `nil` → `false`, anything else passes through. For commands like `SET NX/XX` that may not execute. | `SET nx: true` |
| `Hashify` | Flat `[k1, v1, k2, v2]` array → `{ k1 => v1, k2 => v2 }`. | `HGETALL`, `CONFIG GET` |
| `Pairify` | Flat array → array of `[k, v]` pairs. Like `Hashify` but preserves duplicates and ordering. | (less common) |
| `Floatify` | `"inf"`/`"-inf"`/numeric string → `Float`. Pass-through for non-strings. | `INCRBYFLOAT`, `ZSCORE`, `HINCRBYFLOAT` |
| `FloatifyPair` | `[member, score_str]` → `[member, Float]`. | Used inside `FloatifyPairs`. |
| `FloatifyPairs` | Flat `[m1, s1, m2, s2]` → `[[m1, f1], [m2, f2]]`. | `ZRANGE WITHSCORES`, `ZRANGEBYSCORE WITHSCORES` |
| `HashifyInfo` | Parses the `INFO` text format into a Hash. | `INFO` |
| `HashifyStreamEntries` | `XRANGE`/`XREVRANGE` array → array of `[id, {field=>value,...}]`. | `XRANGE` family |
| `HashifyStreams` | `XREAD` reply → `{ stream_name => [entries] }`. | `XREAD`, `XREADGROUP` |
| `HashifyStreamAutoclaim` / `HashifyStreamAutoclaimJustId` | `XAUTOCLAIM` reply shaping. | `XAUTOCLAIM` |
| `HashifyStreamPendings` / `HashifyStreamPendingDetails` | `XPENDING` reply shaping. | `XPENDING` |
| `HashifyClusterNodes` / `HashifyClusterSlots` / `HashifyClusterSlaves` / `HashifyClusterNodeInfo` | Parse `CLUSTER *` replies. | `CLUSTER NODES`, `CLUSTER SLOTS` |
| `Noop` | Identity. Used to satisfy interfaces that require a block. | rare |

### Adding a new lambda

If — and only if — none of the above fits, add a new lambda constant to `lib/redis/commands.rb` near the existing family. Conventions:

- Name it after the *shape* it produces, not the command it belongs to. `Hashify`, `Floatify`, `Pairify` — these names imply the transformation. Naming a lambda `XInfoifier` is wrong; if it parses XINFO, call it `HashifyStreamInfo`.
- Make it a `lambda { |value| ... }` — not a `proc`, not a `Proc.new`. Match the style.
- Handle `nil` explicitly. Most Redis replies can be `nil` (key didn't exist), and your lambda will be called on `nil`. Either pass `nil` through (`return nil if value.nil?`) or define its semantics deliberately.
- Don't depend on instance state. The lambdas are class-level constants — they receive only the reply value, nothing else.

### When to inline vs use a lambda

Use a lambda when:

- The transformation is reused by multiple commands (`Hashify` is shared by HGETALL, CONFIG GET, etc.)
- The transformation is one expression (slice, hash, parse)
- You want it to run inside pipelines automatically (the lambda is invoked when the Future resolves)

Do the work inside the command method instead when:

- The transformation needs other arguments (e.g., `mapped_mget` zips the keys with the reply — see `lib/redis/commands/strings.rb:219-227`):

  ```ruby
  def mapped_mget(*keys)
    mget(*keys) do |reply|
      if reply.is_a?(Array)
        Hash[keys.zip(reply)]
      else
        reply
      end
    end
  end
  ```

  Here the block closes over `keys`, so it can't be a stateless constant lambda.

### Important: do NOT coerce raw bytes back to strings

`redis-client` already decodes RESP strings to Ruby strings. Don't call `value.to_s` or `String(value)` inside a reshape lambda for reply data — it's already a string. Coerce *arguments* before they hit the wire (`value.to_s`, `Integer(x)`); never coerce replies post-hoc.

---

## 5. Redis::Distributed

`Redis::Distributed` is a separate top-level class (`lib/redis/distributed.rb`) implementing client-side consistent-hash sharding across N independent standalone Redis servers. It is **not** the Redis Cluster protocol — there are no slot maps, no MOVED redirects, no automatic resharding. It is supported and actively maintained (it gets new commands in roughly every release).

### Why it needs its own implementation

`Redis::Distributed` does **not** `include Commands`. Every command is hand-written, because each command needs to be explicitly routed to the right underlying `Redis` instance via `node_for(key)`. The ring uses `Zlib.crc32` of the key against an MD5-hashed virtual-node ring (160 vnodes per server, `lib/redis/hash_ring.rb:8`).

Multi-key commands raise `Redis::Distributed::CannotDistribute` because keys may live on different nodes and the operation isn't atomic across nodes.

### The two patterns

**Single-key commands** route to one node:

```ruby
# lib/redis/distributed.rb (typical pattern)
def incr(key)
  node_for(key).incr(key)
end

def set(key, value, **options)
  node_for(key).set(key, value, **options)
end
```

**Multi-key commands** either iterate or raise. Look at how `mget` handles it (in `lib/redis/distributed.rb`, search for `mget`) — it groups keys by node, calls `mget` on each, and reassembles results in original order. If your command can't be safely split across nodes, raise:

```ruby
def sinterstore(destination, *keys)
  ensure_same_node(:sinterstore, [destination, *keys]) do |node|
    node.sinterstore(destination, *keys)
  end
end
```

`ensure_same_node` (defined in `Redis::Distributed`) checks that all keys hash to the same node — if not, it raises `CannotDistribute`. Users can force same-node placement using key tags (`"{group}:key1"`, `"{group}:key2"`) — see `node_for` (`lib/redis/distributed.rb:30-35`).

### Server-wide commands

For commands that don't take a key (FLUSHALL, BGSAVE, INFO, etc.), apply to every node and return a collection:

```ruby
def flushall
  on_each_node :flushall
end
```

`on_each_node` returns an Array with one entry per node, in `@ring.nodes` order. Existing examples at `lib/redis/distributed.rb:55-115`.

### Pub/Sub in Distributed

Pub/Sub in `Redis::Distributed` pins the subscription to a single node based on the channel name. This is structurally limited — patterns that span channels across nodes don't work. If your command interacts with pub/sub, follow the existing `subscribe` / `unsubscribe` patterns in `distributed.rb`.

### Skipping Distributed

Some commands genuinely make no sense in a distributed setting — `MIGRATE`, `WAIT`, `MONITOR`. The convention is to raise `NotImplementedError` (`lib/redis/distributed.rb:104-106`):

```ruby
def monitor
  raise NotImplementedError
end
```

If you're adding a command that fundamentally doesn't work in Distributed, do this rather than omitting it (omission becomes a `NoMethodError` for users, which is worse than an explicit `NotImplementedError`).

---

## 6. Testing

### The four test groups

The Rakefile (`Rakefile:8-32`) defines four `Rake::TestTask` groups, all required to pass by the default `rake test` task:

```
test/redis/              → bundle exec rake test:redis        # standalone
test/distributed/        → bundle exec rake test:distributed  # Redis::Distributed
test/sentinel/           → bundle exec rake test:sentinel     # sentinel mode
cluster/test/            → bundle exec rake test:cluster      # redis-clustering gem
```

The Rakefile **fails the build** if a `*_test.rb` file exists outside these directories (`Rakefile:19-22`). Don't drop tests anywhere else.

### The lint-module pattern (the key idea)

Tests for command behavior are written **once** in a shared lint module under `test/lint/<category>.rb`, then included by each per-client test class. This is the project's most important testing pattern — it lets the same assertions run against standalone, distributed, sentinel, and cluster topologies without copy-paste.

The lint modules already exist for each category:

```
test/lint/strings.rb
test/lint/hashes.rb
test/lint/lists.rb
test/lint/sets.rb
test/lint/sorted_sets.rb
test/lint/hyper_log_log.rb
test/lint/streams.rb
test/lint/value_types.rb
test/lint/blocking_commands.rb
test/lint/authentication.rb
```

A lint module looks like (`test/lint/strings.rb`):

```ruby
module Lint
  module Strings
    def test_set_and_get
      r.set("foo", "s1")
      assert_equal "s1", r.get("foo")
    end

    def test_set_with_ex
      r.set("foo", "bar", ex: 2)
      assert_in_range 0..2, r.ttl("foo")
    end
    ...
  end
end
```

It uses `r` (the test helper's alias for `@redis`, set up in `test/helper.rb:96`). Per-client tests then mix the lint module in alongside the helper for that topology:

```ruby
# test/redis/commands_on_strings_test.rb
class TestCommandsOnStrings < Minitest::Test
  include Helper::Client
  include Lint::Strings
end

# test/distributed/commands_on_strings_test.rb
class TestDistributedCommandsOnStrings < Minitest::Test
  include Helper::Distributed
  include Lint::Strings

  # Plus distributed-specific tests that don't apply to standalone
  def test_mget
    ...
  end
end

# cluster/test/commands_on_strings_test.rb
class TestClusterCommandsOnStrings < Minitest::Test
  include Helper::Cluster
  include Lint::Strings

  def mock(*args, &block)
    redis_cluster_mock(*args, &block)
  end
end
```

**The sentinel test group does not include lint modules** for command behavior — sentinel mode shares the standalone client implementation, so re-running every string test against a sentinel-resolved master adds CI time without finding new bugs. Sentinel tests focus on failover, role checks, and config resolution (see `test/sentinel/`).

### Where to add what

When you add a new command, add tests in this order:

1. **Add lint-module test(s) to `test/lint/<category>.rb`.** Cover:
   - The happy path with a representative argument.
   - Each optional flag your method accepts (one test per non-trivial flag combination).
   - The empty / nil / missing-key case (most Redis commands have a defined nil-reply behavior).
   - Any reshape: assert on the *Ruby type* the user gets, not the raw reply.
2. **Verify the lint module is reused.** Open `test/redis/commands_on_<category>_test.rb` and `cluster/test/commands_on_<category>_test.rb` — they should already `include Lint::<Category>`. If they do, you get standalone + cluster coverage automatically.
3. **Add Distributed-specific tests under `test/distributed/`.** Because Distributed has its own method implementation, the lint module isn't always enough — write tests that exercise routing, the `CannotDistribute` path for unsafe multi-key uses, and any key-tag scenarios.
4. **If the command has cluster-specific behavior** (atypical for ordinary single-key commands), add tests to `cluster/test/commands_on_<category>_test.rb` beyond the included lint module.

### Version constraints

The makefile defaults to building Redis `8.4` from source (`makefile:1`: `REDIS_BRANCH ?= 8.4`), but tests still need to skip cleanly on older versions where appropriate. Two helpers in `test/helper.rb`:

- **`target_version(version) { ... }`** (`test/helper.rb:153-159`) — runs the block only if the server is at least that version, skips otherwise. Use this when most of a test depends on a newer feature:

  ```ruby
  def test_set_with_exat
    target_version "6.2" do
      r.set("foo", "bar", exat: Time.now.to_i + 2)
      assert_in_range 0..2, r.ttl("foo")
    end
  end
  ```

- **`omit_version(min_ver)`** (`test/helper.rb:166-168`) — early-skip the whole test:

  ```ruby
  def test_my_command
    omit_version("7.4")
    r.my_new_command(...)
  end
  ```

Both rely on `version` (which reads `INFO redis_version`, `test/helper.rb:170-172`) and `Helper::Version` for comparison.

**Always gate tests for commands introduced in a specific Redis version.** CI runs against multiple Redis versions (see `.github/workflows/`); ungated tests will break older-version runs.

### Running tests locally

```sh
# Bring up servers (standalone, replica, sentinel quorum, 6-node cluster)
make start_all

# Run everything
make test

# One group
bundle exec rake test:redis
bundle exec rake test:distributed
bundle exec rake test:sentinel
bundle exec rake test:cluster

# Single file
bundle exec rake test:redis TEST=test/redis/commands_on_strings_test.rb

# Single test method (Minitest regex)
bundle exec rake test:redis TEST=test/redis/commands_on_strings_test.rb \
  TESTOPTS="--name=/test_set_with_ex/"

# Run with hiredis instead of pure-Ruby parser
DRIVER=hiredis bundle exec rake test

# Target a different Redis version
REDIS_BRANCH=7.2 make start_all && make test

make stop_all
```

If you see `Couldn't locate the redis unix socket, did you run \`make start\`?`, the test helper checks for `tmp/redis.sock` (`test/helper.rb:29-37`). `make start_all` creates it.

### Mocking when you can't use a real server

For testing protocol edge cases (unexpected replies, parser errors), `test/support/redis_mock.rb` provides `RedisMock.start_with_handler { |port| ... }`. Use it sparingly — most tests benefit from running against real Redis. Look at `test/redis/error_replies_test.rb` for the pattern.

### Pipelined and transactional behavior

If your command does anything beyond a single `send_command` call (multiple commands, post-processing, branching on reply), **add a pipelined test**. Inside a `pipelined` block, intermediate side effects are deferred and the reply is a `Future`, not a value. Bugs here are subtle and easy to miss:

```ruby
def test_my_command_in_pipeline
  result = r.pipelined do |pipe|
    pipe.my_command(...)
  end
  assert_equal expected, result.first
end
```

The same applies to `multi`.

---

## 7. Other conventions

### Frozen string literals

Every Ruby file in the project starts with `# frozen_string_literal: true`. Keep this when editing existing files and add it to new ones. The reshape lambdas and command-array symbols rely on string immutability.

### Symbols vs strings for the verb

By convention the first element of a command array is a **Symbol** (`:incr`, `:set`, `:hgetall`). The rest are strings (or values coerced to strings by `redis-client`'s serializer). Stick to this convention even though strings would work — it's how the existing 100+ commands are written and grep'ing for `:foo` finds the verb usage.

### Rubocop

The project uses Rubocop with `rubocop ~> 1.25.1` (intentionally pinned to an older version — see Gemfile). Run before sending a PR:

```sh
bundle exec rubocop
```

The cluster gem has its own `.rubocop.yml` under `cluster/`; lint both trees if you touched both.

### Deprecation

If your change deprecates an existing method or signature, use `Redis.deprecate!` (`lib/redis.rb:13-25`) to emit a warning. The infrastructure is already there — `Redis.silence_deprecations=` and `Redis.raise_deprecations=` exist to control behavior. Don't roll your own deprecation mechanism.

---

## 8. End-to-end checklist

Use this when adding a new command:

- [ ] Identify the right category file under `lib/redis/commands/`.
- [ ] Implement the method:
  - [ ] Use keyword args for flags.
  - [ ] Coerce inputs (`Integer`, `Float`, `to_s`) at the boundary.
  - [ ] Use `send_command` (or `send_blocking_command`).
  - [ ] Pass an existing reshape lambda if the reply needs shaping; otherwise add a new lambda only if no existing one fits.
  - [ ] Write a YARD docstring with `@param`, `@return`, `@example`.
- [ ] Add Distributed support in `lib/redis/distributed.rb`:
  - [ ] Single-key: `node_for(key).method(...)`.
  - [ ] Multi-key: group by node, use `ensure_same_node`, or raise `CannotDistribute`.
  - [ ] Server-wide: `on_each_node`.
  - [ ] Conceptually incompatible: raise `NotImplementedError`.
- [ ] Add tests:
  - [ ] Add test methods to `test/lint/<category>.rb` (these run for standalone + cluster).
  - [ ] Verify `test/redis/commands_on_<category>_test.rb` and `cluster/test/commands_on_<category>_test.rb` already `include Lint::<Category>`.
  - [ ] Add distributed-specific tests to `test/distributed/commands_on_<category>_test.rb`.
  - [ ] Gate version-specific tests with `target_version` / `omit_version`.
  - [ ] Add a pipelined test if the command does more than `send_command(args, &block)`.
- [ ] If a new error class is needed, add it to `lib/redis/errors.rb` and `Redis::Client::ERROR_MAPPING` (and the cluster equivalent if relevant).
- [ ] Run locally: `make start_all && make test && bundle exec rubocop && make stop_all`.

That's it. The two-gem structure and the lint-module sharing conspire to make the common case (a single Ruby method definition plus tests) the only thing you actually have to write.
