## Repository layout

This repository ships **two gems** from one tree:

- `redis` — the high-level standalone/sentinel client. Source under `lib/`, gemspec at `redis.gemspec`.
- `redis-clustering` — the cluster client, a thin subclass that depends on `redis`. Source under `cluster/lib/`, gemspec at `cluster/redis-clustering.gemspec`. It is a separate gem on purpose: passing `cluster:` to `Redis.new` raises (see `lib/redis.rb`).

Cluster code, tests, and CHANGELOG live under `cluster/`. When making changes that span both, edit both — the cluster gem reuses `lib/redis/commands/**` from the main gem but has its own client class (`cluster/lib/redis/cluster/client.rb`) and transaction adapter.

## Common commands

The dev workflow runs Redis in Docker containers via `docker-compose.yml` using the prebuilt `redislabs/client-libs-test` image. Topologies are selected by Docker profiles (`standalone`, `sentinel`, `cluster`, `all`). The `makefile` is a thin shim around `docker compose --profile X up -d --wait` and `down -v`, so the historical target names still work:

```sh
# bring up everything: standalone, replica, 3 sentinels, 6-node cluster
make start_all

# run the full suite (all four test groups)
make test

# stop everything
make stop_all

# one shot: start, test, stop
make all
```

`make test` shells out to `bundle exec rake test`, which runs four `Rake::TestTask` groups defined in `Rakefile`:

```sh
bundle exec rake test:redis        # lib/redis core
bundle exec rake test:distributed  # lib/redis/distributed (client-side sharding)
bundle exec rake test:sentinel     # sentinel-mode tests
bundle exec rake test:cluster      # cluster gem (loads cluster/lib + cluster/test)
```

To run a single test file or method, use Minitest's options via `TESTOPTS`:

```sh
bundle exec rake test:redis TEST=test/redis/commands_on_strings_test.rb
BUNDLE_GEMFILE=cluster/Gemfile bundle exec rake test:cluster TEST=cluster/test/commands_on_strings_test.rb TESTOPTS="--name=/get/"
```

The cluster group needs `BUNDLE_GEMFILE=cluster/Gemfile` (the root bundle doesn't include `redis-cluster-client`); CI does the same.

Other useful knobs:

- `REDIS_VERSION=8.X.Y make start_all` — pin the image tag (default is set at the top of `makefile`). Tags are published per Redis minor.patch (e.g. `8.0.6`, `8.2.6`, `8.4.3`, `8.6.3`, `8.8.0`); a bare `8.4` tag generally does not exist.
- `DRIVER=hiredis bundle exec rake test` — run the suite against the `hiredis-client` C-extension driver instead of the pure-Ruby parser (see `test/helper.rb`).
- `PROTOCOL=2 bundle exec rake test` — run the suite over RESP2 instead of the default RESP3 (`test/helper.rb:11`). Reply-reshaping changes should be verified under both protocols (and ideally both drivers).
- `REDIS_SOCKET_PATH=...` — override the Unix socket location. The default expects `tmp/redis.sock`, which the standalone container bind-mounts from `./tmp:/sockets`; `test/helper.rb` aborts if it's missing.
- `bundle exec rubocop` — lint. The Rubocop config is in `.rubocop.yml` (root) and `cluster/.rubocop.yml`.
- `bin/console` — IRB session with `redis` preloaded.

You can also drive `docker compose` directly when you want a single profile up:

```sh
docker compose --profile standalone up -d --wait
docker compose --profile sentinel   up -d --wait
docker compose --profile cluster    up -d --wait
docker compose --profile all down -v
```

The cluster profile's healthcheck waits for `cluster_state:ok` (not just PING) so tests can connect without hitting the historical `InitialSetupError` race. Pre-configured sentinel node directories live under `test/support/sentinel-config/` and are bind-mounted into the sentinel container; the image's entrypoint starts each as a sentinel because their directory names begin with `node-sentinel`.

### macOS / Docker Desktop note

The compose stack uses `network_mode: host` so sentinel and cluster nodes report `127.0.0.1` addresses the test runner on the host can reach. On Linux this works natively. On macOS, Docker Desktop's "host networking" beta must be enabled (Settings → Resources → Network → Enable host networking); without it, the containers are healthy but their ports aren't visible on `127.0.0.1`. AF_UNIX sockets bind-mounted out of the standalone container also don't route through Docker Desktop's VM on macOS, so `test_connecting_to_unix_domain_socket` fails locally but passes on Linux CI.

## Architecture

### Layering

```
Redis (lib/redis.rb)                ergonomics: keyword DSL, reply reshaping, error translation,
   ├ Commands (lib/redis/commands)  pub/sub second-socket, pipelined/multi wrappers,
   ├ Monitor (lock)                 RESP3→RESP2 fallback, HIMPORT fieldset registry
   └ @client : Redis::Client < RedisClient
                                    ↓
              redis-client gem (external, vendored as runtime dep)
                                    ↓
              TCP/TLS/Unix socket
```

The `Redis` class is the public surface. It delegates all network I/O to `Redis::Client`, which inherits from `RedisClient` (in the `redis-client` gem) and only adds:

1. Error translation: maps `RedisClient::*` exceptions to `Redis::*` via `ERROR_MAPPING` in `lib/redis/client.rb`. Every public method on `Redis::Client` is wrapped in a rescue that calls `Client.translate_error!`.
2. A default of `protocol: 3` (RESP3) in `lib/redis/client.rb`; callers can pass `protocol: 2`. Servers without RESP3 (Redis < 6.0, or anything replying `NOPROTO`) are detected on connect and `Redis#with_protocol_fallback` (`lib/redis.rb`) transparently rebuilds `@client` for RESP2 — every `@client` access funnels through `Redis#synchronize`, which is what applies the fallback, so pipelines/multi/watch fall back too. Return values are protocol-invariant except GEO coordinates (`Float` under RESP3).
3. Trivial config delegators (`#host`, `#port`, `#db`, …).

The full command execution flow is: `Redis#some_command` (defined in `lib/redis/commands/<category>.rb`) builds an array → `Redis#send_command` grabs `@monitor` → `Redis::Client#call_v` rescues + re-raises → `RedisClient#call_v` serializes RESP and reads the reply → optional reshape lambda runs → result returned.

### Commands as a module composition

Every Redis command category is a module under `lib/redis/commands/` (strings, lists, hashes, sets, sorted_sets, streams, arrays, scripting, transactions, pubsub, etc.). Module-provided command families live under `lib/redis/commands/modules/` (`json.rb` for `JSON.*`, `search.rb` + `search/` for the Query Engine `FT.*`, whose replies reshape into `Search::SearchResult`/`Search::AggregateResult` objects). They are all `include`d into a parent `Redis::Commands` module (`lib/redis/commands.rb`), which is in turn mixed into:

- `Redis` (`lib/redis.rb`)
- `Redis::PipelinedConnection` (`lib/redis/pipeline.rb`) — used inside `pipelined` and `multi` blocks
- (Indirectly) `Redis::Cluster` via inheritance from `Redis`

This is the **single most important pattern in the codebase**. To add a new command, find the matching `commands/<category>.rb` and add a method that calls `send_command([:cmd, ...])` — that method automatically becomes available on every client type. The mixin classes each provide their own `send_command` and `synchronize` so the same `Commands` methods work in direct calls, pipelines, and transactions.

There is also a catch-all `method_missing` in `lib/redis/commands.rb` that forwards any unknown method as a Redis command — so unwrapped commands "just work."

### Reply reshaping (protocol-aware)

The top of `lib/redis/commands.rb` defines a family of lambdas — `Boolify`, `BoolifySet`, `Hashify`, `Floatify`, `FloatifyPairs`, `HashifyInfo`, `HashifyStreamEntries`, `HashifyClusterNodes`, … — that reshape raw replies into idiomatic Ruby (Hash, Float, boolean, etc.). They are passed as blocks to `send_command`:

```ruby
def incrbyfloat(key, increment)
  send_command([:incrbyfloat, key, Float(increment)], &Floatify)
end
```

Since 6.0 the client negotiates RESP3 by default, so these lambdas are **protocol-aware**: they must accept both the RESP2 wire shape (flat arrays, string-encoded numbers) and the RESP3 one (native maps, doubles, pairs) and converge on the same Ruby value. The pattern is "detect the already-final shape and pass it through" — e.g. `Hashify` returns a `Hash` unchanged and `each_slice(2).to_h`'s a flat array; `FloatifyPairs` skips re-mapping when the reply is already `[[member, Float], ...]`. When adding or changing a lambda, keep both branches, and test the command under both protocols (`PROTOCOL=2` / `PROTOCOL=3`, see below).

When adding a command that needs reply transformation, write or reuse one of these lambdas; do not coerce in the command method itself. See `specs/adding-commands.md` for the full catalog and the end-to-end checklist (the `add-new-command` skill automates this flow from a spec file).

### Connection lifecycle (long-lived, lazy, fork-safe)

- `Redis.new` does **not** open a socket — it's lazy. The first command triggers `RedisClient#ensure_connected`, which runs the `connection_prelude` (HELLO/AUTH, SELECT, CLIENT SETINFO, then CLIENT SETNAME and ROLE) and caches the socket.
- One `Redis` instance owns one socket, guarded by a `Monitor` defined in `lib/redis.rb` and acquired in `Redis#send_command`. The reentrant lock matters for nested `watch { multi { ... } }` patterns; do not "optimize" it to `Mutex` without redesigning that API.
- For concurrent use, wrap with `connection_pool` — the README documents this and it's the only recommended pooling story. The gem itself does not pool.
- Fork safety is handled inside `redis-client` via `PIDCache`: a forked child detects the inherited socket and reconnects on next use. The `inherit_socket` option in `lib/redis.rb` disables that check; almost no callers should use it.

### Pub/Sub — separate socket, same process

`subscribe` / `psubscribe` / `ssubscribe` open a **second** dedicated socket via `@client.pubsub` (in `lib/redis.rb`) wrapped in `SubscribedClient` (`lib/redis/subscribe.rb`). This keeps the command socket usable from other threads while one thread is blocked in the `next_event` loop. The subscription loop on the calling thread is synchronous — if you want it off the main thread, the caller spawns a `Thread`. There's a separate write-monitor on the subscription socket. Sharded pub/sub (`SSUBSCRIBE`) subscribes one channel at a time to avoid cross-slot errors in cluster mode.

### Pipelines and transactions

`pipelined` and `multi` both yield a `Redis::PipelinedConnection` (or `MultiConnection`) that re-includes `Commands` (`lib/redis/pipeline.rb`). Each command inside the block returns a `Redis::Future` that resolves when the batch flushes. `MultiFuture` (in `lib/redis/pipeline.rb`) splits the `EXEC` reply array back across individual command futures. Inside a `MULTI`, blocking commands degrade to non-blocking — that's intentional, matching Redis server semantics.

### HIMPORT — server session state with client-side recovery (experimental)

The `HIMPORT` command family (Redis 8.10) is the one place a command's state outlives a single call: fieldsets are **per-connection server session state**, destroyed by reconnect/failover/`RESET`. `Redis#initialize` keeps a registry of prepared schemas (`@himport_fieldsets`) and the `himport_*` overrides in `lib/redis.rb` repair a lost fieldset reactively — on the server's "no such fieldset" error, re-prepare from the registry and retry the SET exactly once. Recovery is per-fieldset and lazy (there is no reconnect hook); disable with `himport_auto_prepare: false`, in which case re-preparing is the caller's responsibility (the registry has no public reader). The overrides hold `@monitor` across command + registry mutation — don't split them. The cluster subclass adds reply aggregation on top (prepare/discard fan out to all masters).

### Client identification (CLIENT SETINFO)

`Redis::LibIdentity` (`lib/redis/lib_identity.rb`) reports `lib-name=redis-rb lib-ver=<version>` on every connection by **prepending onto `RedisClient::Config` / `RedisClient::SentinelConfig`** and appending a second `SETINFO` pair to the connection prelude (last-write-wins overrides redis-client's own pair; zero extra round trips). The override is gated by a `redis-rb_v<version>` marker in `driver_info`, so applications using redis-client directly are untouched. Downstream gems extend the name via `Redis.new(driver_info: "my-gem_v1.0.0")`; `driver_info: false` disables identification. This couples to redis-client's `connection_prelude` — one of the reasons the gemspec pins redis-client to an exact version; re-audit on every driver bump.

### Cluster gem differences

`cluster/lib/redis/cluster.rb` defines `Redis::Cluster < ::Redis`, so it inherits the full `Commands` surface but swaps `initialize_client` to build a `RedisClient::Cluster` via the `redis-cluster-client` gem. Cluster-specific differences worth knowing:

- `Redis::Cluster::Client` (`cluster/lib/redis/cluster/client.rb`) maintains a **per-node connection pool internally** via `redis-cluster-client`. Do not wrap this in the `connection_pool` gem.
- `watch` **requires a block with an argument** in `cluster/lib/redis/cluster/client.rb`. The block receives a `Redis::Cluster::TransactionAdapter` that pins commands to the same node/slot. Standalone `Redis#watch` accepts the no-block form; cluster does not.
- `Redis::Cluster#connection` raises `NotImplementedError` — there's no single "connection" to report.
- Extra error classes: `InitialSetupError`, `OrchestrationCommandNotSupported`, `CommandErrorCollection`, `AmbiguousNodeError`, `TransactionConsistencyError`, `NodeMightBeDown` (defined in `cluster/lib/redis/cluster.rb`).

### `Redis::Distributed` is not Redis Cluster

`lib/redis/distributed.rb` + `lib/redis/hash_ring.rb` implement **client-side consistent-hash sharding** across N independent standalone Redis servers. It is *not* the Redis Cluster protocol — there are no slot maps, no MOVED/ASK redirects, no automatic resharding. Keys are hashed with CRC32 against an MD5-built ring (160 vnodes/server) and dispatched to one underlying `Redis` instance. Multi-key commands raise `CannotDistribute` since co-location isn't guaranteed.

It is **separately maintained** from `Commands` — `Redis::Distributed` does *not* include the `Commands` mixin; every method is explicitly defined in `distributed.rb` so it can route to the right node via `node_for(key)`. When adding a new Redis command that should be available here, add a corresponding method to `lib/redis/distributed.rb` and a test under `test/distributed/`. The `test:distributed` Rake task runs as part of the default suite, so missing or broken Distributed implementations will fail CI.

It is supported (recent commits add JSON, arrays (`AR*`), HEXPIRE/HPTTL, HSCAN, etc.) and not deprecated. For new applications needing horizontal scaling, `Redis::Cluster` is generally the better choice because the server enforces consistency; `Redis::Distributed` is the right tool when you have N independent standalone Redises and want memcache-style key distribution.

## Conventions

- Every file starts with `# frozen_string_literal: true`. Keep it when editing or creating files.
- Commands take symbols for the verb (`[:incr, key]`); strings and arguments are coerced where needed (`Integer(x)`, `Float(x)`, `value.to_s`). Follow the local pattern in `lib/redis/commands/<category>.rb` when adding new methods.
- Yard-style docstrings (`@param`, `@option`, `@return`, `@example`) are on every public command method. New methods should keep that format.
- Error mapping is centralized in `Redis::Client::ERROR_MAPPING` (and extended in `Redis::Cluster::Client::ERROR_MAPPING`). If you add a new RedisClient error class to handle, add it there rather than catching in individual command methods.
- Test files must live under one of `test/redis`, `test/distributed`, `test/sentinel`, `cluster/test`. The Rakefile fails the build if a `*_test.rb` exists outside those groups.
