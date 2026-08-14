# Keyspace Notifications Support in redis-rb

A guide to how redis-rb exposes **Redis Keyspace Notifications** — server-published pub/sub events
about changes to the dataset — including the **Subkey Notifications** introduced in Redis 8.8, and
the cluster-aware manager in the `redis-clustering` gem.

If you read only one thing: keyspace notifications ride on ordinary pub/sub, but "we already have
pub/sub" is not enough. Channel names and payloads have server-defined wire formats (some
binary-safe and length-prefixed), delivery is **fire-and-forget**, and in **cluster** the events
are node-local — a naive `subscribe` receives only a fraction of them. redis-rb ships tested
builders, a binary-safe parser, and managers so you don't have to reimplement any of that.

---

## 1. What the server provides

When enabled, Redis publishes an event for every effective change to the dataset. Classic
notifications come in two flavors per event:

| Family | Channel | Message payload |
| --- | --- | --- |
| keyspace | `__keyspace@<db>__:<key>` | `<event>` (e.g. `set`, `del`, `expired`) |
| keyevent | `__keyevent@<db>__:<event>` | `<key>` |

Redis 8.8 adds four **subkey** families that identify which elements *inside* a value changed
(v1 server scope: hash fields; the model is generic for future types):

| Family | Channel | Message payload |
| --- | --- | --- |
| subkeyspace | `__subkeyspace@<db>__:<key>` | `<event>\|<len>:<subkey>[,<len>:<subkey>...]` |
| subkeyevent | `__subkeyevent@<db>__:<event>` | `<key_len>:<key>\|<len>:<subkey>[,...]` |
| subkeyspaceitem | `__subkeyspaceitem@<db>__:<key>\n<subkey>` | `<event>` |
| subkeyspaceevent | `__subkeyspaceevent@<db>__:<event>\|<key>` | `<len>:<subkey>[,...]` |

Keys and subkeys may contain **arbitrary bytes** — including `:`, `|`, `,` and `\n` — which is why
subkey payloads are length-prefixed and must not be parsed with naive string splitting. Notes:

- Subkeys are an **ordered list and may contain duplicates**; both are preserved.
- A single subkey still uses the full length-prefixed encoding (`hset|4:name`).
- `subkeyspaceitem` is only emitted for keys that contain no `\n` (its channel builder rejects them).
- Event names are **opaque strings** — new server events flow through without a gem update.

### Delivery semantics

- **Fire-and-forget.** Pub/sub has no persistence: events published while you were disconnected are
  lost forever. Design consumers to reconcile after gaps (see `on_reconnect` below).
- Events fire only when a key is **actually modified** (`SREM` of a missing member emits nothing).
- `expired` fires when Redis actually deletes the key (lazily or via the expiry cycle), which can
  lag the logical TTL.

## 2. Enabling notifications (server-side; the gem will not do it for you)

Notifications are **off by default** and controlled by the `notify-keyspace-events` server config:

```
redis-cli config set notify-keyspace-events KEA        # classic: most events
redis-cli config set notify-keyspace-events KEASTIV    # classic + Redis 8.8 subkey families
```

Flags: `K` keyspace, `E` keyevent, `A` = "all types" alias (`g$lshztdxea`), plus per-type flags
(`g` generic, `$` string, `l` list, `s` set, `h` hash, `z` zset, `t` stream, `a` array, `d` module,
`x` expired, `e` evicted) and the non-`A` extras (`m` key-miss, `n` new-key, `o` overwritten,
`c` type-changed). Subkey families use `S` (subkeyspace), `T` (subkeyevent), `I` (subkeyspaceitem),
`V` (subkeyspaceevent). Two gotchas verified against Redis 8.8:

- At least one of `K`/`E` must be present for any *classic* event to fire.
- The subkey flags are **not sufficient on their own**: the data-type flag must also be set
  (`STIV` alone emits nothing for hashes; `STIVh` or `KEASTIV` works).

This gem deliberately provides **no API to set this config** (matching redis-py): `CONFIG` is often
restricted on managed Redis, and runtime `CONFIG SET` does not survive restarts or reach nodes that
join later. Treat it as infrastructure configuration. **Cluster warning:** set it in the config of
**every node, replicas included** — `Redis::Cluster#config(:set, ...)` only reaches the currently
connected primaries, and a replica promoted by failover would otherwise emit nothing.

Do **not** PUBLISH to notification channels yourself. The server owns these channel names; manual
publishes confuse every consumer and are unsupported.

## 3. Where it lives

```
lib/redis/keyspace_notifications.rb            # namespace, ParseError, Redis#keyspace_notifications
lib/redis/keyspace_notifications/
  channels.rb        # channel/pattern builders for all six families
  notification.rb    # Notification value object (family, db, event, key, subkeys, ...)
  parser.rb          # binary-safe (channel, payload) -> Notification parser
  manager.rb         # standalone manager: own connection + listener thread + handlers

cluster/lib/redis/cluster/keyspace_notifications.rb   # cluster manager: all-primaries fan-out
cluster/lib/redis/cluster/keyspace_notifications/node_listener.rb
```

The layering:

```
Layer 2:  Manager (Redis#keyspace_notifications)      Cluster manager (Redis::Cluster#keyspace_notifications)
             one dedicated connection + thread            one NodeListener (connection + thread) per primary
             handler registry, auto-resubscribe           canonical registry, reactive refresh, one dispatcher
                        │                                                   │
Layer 1:  Channels (builders)  +  Parser  +  Notification   ← pure, reusable anywhere
                        │
Layer 0:  the existing subscribe/psubscribe DSL (lib/redis/subscribe.rb) — unchanged
```

## 4. Layer 1 — builders and parser with the plain pub/sub DSL

Use this when you want full control of the subscription loop:

```ruby
channels = Redis::KeyspaceNotifications::Channels
pattern  = channels.keyspace("user:*", db: 0)   # => "__keyspace@0__:user:*"

redis.psubscribe(pattern) do |on|
  on.pmessage do |matched, channel, payload|
    n = Redis::KeyspaceNotifications::Parser.parse(channel, payload, pattern: matched)
    next if n.nil? # not a notification channel

    puts "#{n.event} on #{n.key} (db #{n.db}), subkeys: #{n.subkeys.inspect}"
  end
end
```

- Builders: `keyspace(key, db: 0)`, `keyevent(event, db: 0)`, `subkeyspace(key, db: 0)`,
  `subkeyevent(event, db: 0)`, `subkeyspaceitem(key, subkey, db: 0)`,
  `subkeyspaceevent(event, key, db: 0)`. `db:` accepts an Integer or `"*"`; key/event arguments may
  contain globs for `psubscribe`. All return BINARY-encoded strings.
- `Parser.parse(channel, payload, pattern: nil)` returns a `Notification`, `nil` for channels that
  aren't notification channels, and raises `Redis::KeyspaceNotifications::ParseError` (carrying the
  raw `channel`/`payload`) for a malformed body on a notification channel.
- `Notification` exposes `family` (Symbol), `db`, `event`, `key`, `subkeys` (frozen Array),
  `channel`, `payload`, `pattern`, plus `subkey` and `subkey_family?`. `key`/`subkeys` are
  BINARY-encoded (keys are bytes on the wire); `force_encoding("UTF-8")` if you know better.

## 5. Layer 2 — the standalone manager

```ruby
manager = redis.keyspace_notifications(error_handler: ->(e) { Rails.logger.warn(e) })

manager.subscribe_keyevent("expired", db: 0) { |n| cache.delete(n.key) }
manager.subscribe_keyspace("user:*")         { |n| audit(n.key, n.event) }
manager.subscribe_subkeyspace("session:*")   { |n| n.subkeys.each { |f| invalidate_field(n.key, f) } } # 8.8+
manager.on_reconnect { cache.clear }  # events during the gap are lost — reconcile

# ... later
manager.close
```

Semantics worth knowing:

- The manager **owns a dedicated connection** (duplicated from your client's options) and one
  background listener thread; your client stays fully usable. `close` shuts both down.
- Every subscription is issued as a `psubscribe` pattern (a glob-free pattern matches itself), so
  exact channels and patterns mix freely and handler routing is exact per pattern. If several of
  your patterns match one message, each pattern's handler fires once.
- `subscribe` and `unsubscribe` **block until the server acknowledges**, and local state is
  committed only after that acknowledgment: a raised `subscribe` rolls its registration back
  (nothing will fire later), and a raised `unsubscribe` leaves the pattern subscribed on both
  sides (just retry it). Once `subscribe` returns nothing is missed; once `unsubscribe` returns
  nothing more is delivered — in-flight messages for a pattern being unsubscribed go to its
  handler until the server's acknowledgment, never to the default handler afterwards.
- Handlers run on the listener thread: keep them fast, never call blocking commands on the
  manager's connection from them. Handler exceptions and parse errors go to the error handler
  (default: `warn`) and never kill the listener.
- **Concurrent churn on one pattern converges, but is not loss-free:** when subscribe and
  unsubscribe race on the same pattern, local state, server state and delivery always converge
  to a coherent outcome (ack-time invariants repair wire-order races) — but an event published
  during the convergence window can be lost, exactly like during a reconnect gap. Pub/sub is
  fire-and-forget; the guarantee is that the stream recovers, not that no event falls into
  the gap.
- **Auto-resubscribe:** on connection loss the manager reconnects and replays every registered
  pattern, then fires `on_reconnect`. The `reconnect_attempts:` option uses the same semantics as
  the `Redis.new` option of the same name — an Integer (that many immediate retries) or an Array
  of sleep durations between attempts (`[]` disables reconnection). The default is an exponential
  ladder of 10 attempts, 0.5s doubling up to 30s (~2 minutes of patience); the budget resets after
  every healthy session. The gap is inherently lossy — `on_reconnect` is your reconciliation hook.
- Typed helpers (`subscribe_keyspace`, `subscribe_keyevent`, `subscribe_subkeyspace`,
  `subscribe_subkeyevent`, `subscribe_subkeyspaceitem`, `subscribe_subkeyspaceevent`) are
  one-liners over `subscribe` + the builders; `on_notification` sets a default handler;
  `unsubscribe` (no args = all) stops delivery, and unsubscribing the last pattern parks the
  thread until the next `subscribe`.

### Use with `connection_pool`

The strategy is **one manager per process**, regardless of how many pooled connections or
threads operate on the keyspace:

- Pub/sub is a **broadcast, not a work queue**: every subscriber receives every matching event.
  One manager per pooled connection would deliver (and handle) each event N times — duplicated
  traffic and duplicated side effects, never load sharing.
- The manager is **not a poolable resource**: a subscribed connection can't serve commands, and
  a pool's temporary-exclusive checkout model is the opposite of a subscription's
  permanent-exclusive connection. The manager sidesteps this by duplicating the client's
  *options* into a private connection it owns — so `pool.with { |r| r.keyspace_notifications }`
  is a safe construction idiom (nothing of the checked-out client is retained) and the manager
  outlives the checkout.
- Writers need no relationship to the subscriber: any pooled connection can modify keys; the
  server emits each event once and the single manager sees it once.
- Handlers may do Redis work by briefly checking a connection **out of the pool** (never via the
  manager's own connection); they run on the listener thread, so hand heavy work to your own
  queue/workers instead of blocking dispatch.
- **Forking servers** (Puma, Sidekiq, Spring): threads don't survive `fork` — create the manager
  in an after-fork hook, one per worker process. Each process receives every event; for cache
  invalidation that per-process delivery is exactly what you want, and cross-process
  exactly-once processing is an application-level concern (pub/sub cannot provide it).

Runnable demo: `examples/keyspace_notifications_pool.rb`.

## 6. Cluster — why a manager is required, not optional

In a cluster, keyspace notifications are **node-local**: each node publishes events only for keys
it owns and they are *not* forwarded on the cluster bus (unlike regular pub/sub). A plain
`redis.subscribe("__keyevent@0__:expired")` on a `Redis::Cluster` connects to **one** node and
silently receives roughly 1/N of the events — it looks correct in a small test and loses data in
production. The inherited `subscribe`/`psubscribe` are intentionally left untouched; use the
manager for notifications:

```ruby
cluster = Redis::Cluster.new(nodes: nodes)
manager = cluster.keyspace_notifications(error_handler: ->(e, node_key) { log(e, node_key) })

manager.subscribe_keyevent("expired") { |n| cache.delete(n.key) }  # db is always 0 in cluster
# ... after intentionally adding primaries (scale-out):
manager.refresh
```

How it works:

- One dedicated pub/sub connection **per primary** (enumerated via `CLUSTER SLOTS`), each running a
  standalone manager internally; a canonical pattern registry is the source of truth.
- All node listeners funnel into one bounded queue drained by a **single dispatcher thread**:
  handlers need not be thread-safe; per-node ordering is preserved, cross-node ordering is
  unspecified. A slow handler back-pressures the node readers (tune with `queue_size:`).
- **Reactive refresh:** any node connection error signals a dedicated refresher thread, which
  reconciles — re-enumerate primaries, drop vanished/demoted nodes, connect and catch up new
  ones on every registered pattern. It runs off the dispatcher so dispatch keeps draining the
  queue during a refresh (node readers blocked on a full queue must be able to process the
  subscription acks the refresh waits for), and a failed reactive refresh reschedules itself
  with exponential backoff (0.25s doubling to 30s) until it succeeds. There is no proactive
  polling; after a scale-out call `refresh` yourself (a brand-new primary emits no error
  signal). Manual `refresh` raises `Redis::Cluster::KeyspaceNotificationsRefreshError` (with a
  per-node `#errors` hash) if any primary still can't be subscribed.
- Slot migration emits **no** unsubscribe signal, but because every primary is subscribed, keys
  moving between existing primaries keep flowing transparently.
- `unsubscribe` removes registry tracking first — the opposite of the standalone manager's
  ack-then-commit, and deliberate: with N nodes a partial failure is normal, and keeping the
  pattern registered because one node failed would make the next refresh re-subscribe it on the
  N−1 nodes that already unsubscribed. A node whose unsubscribe failed converges on the next
  refresh, whose per-node catch-up also removes patterns that are no longer registered.

## 7. What is *not* supported

- **`Redis::Distributed`**: no notification helpers. Its pub/sub is partial (`psubscribe` raises
  `NotImplementedError`) and subscriptions pin to a node by channel hash, which is incompatible
  with server-defined channel names. The Layer-1 parser/builders still work manually with
  exact-key `subscribe` against a specific node.
- **Setting `notify-keyspace-events`**: see section 2 — operator's job, by design.
- **Publishing to notification channels**: unsupported; don't.

## 8. Testing

- `test/redis/keyspace_notifications/*` — pure unit tests for builders/parser/value object, plus
  manager dispatch/lifecycle tests driven by real server-emitted notifications (key writes with
  `notify-keyspace-events` enabled — nothing is ever published to notification channels manually).
- `test/redis/keyspace_notifications_test.rb` — end-to-end against real server events; subkey
  cases are gated `target_version("8.8")` and need the `KEASTIV` flags.
- `cluster/test/keyspace_notifications_test.rb` — fan-out proof (events from every primary),
  serialized dispatch, reactive refresh after `CLIENT KILL`, resharding and failover coverage.
  Run with `BUNDLE_GEMFILE=cluster/Gemfile bundle exec rake test:cluster`.

See also [adding-commands.md](adding-commands.md) for general conventions and
`examples/keyspace_notifications.rb` for a runnable demo.
