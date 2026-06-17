# Migrating to redis-rb 6.0 (RESP3 by default)

redis-rb 6.0 negotiates the **RESP3** protocol (`HELLO 3`) by default. Previous
versions always used RESP2. This guide covers everything that changes for you.

The short version: **the only command whose return value changes is GEO**
(coordinates become `Float` instead of `String`). Everything else returns the
same Ruby objects as before, and servers too old for RESP3 keep working
automatically. If you want the exact previous behavior, pass `protocol: 2`.

## 1. GEO coordinates are now Floats

`GEOPOS` and `GEOSEARCH` / `GEORADIUS` with `WITHCOORD` return each
longitude/latitude as a `Float` instead of a `String`:

```ruby
# redis-rb 5.x (RESP2)
r.geopos("Sicily", "Palermo")
# => [["13.36138933897018433", "38.11555639549629859"]]

# redis-rb 6.0 (RESP3)
r.geopos("Sicily", "Palermo")
# => [[13.36138933897018433, 38.11555639549629859]]
```

The same applies to the coordinate pair returned by `GEOSEARCH`/`GEORADIUS`
when called with `withcoord: true`.

Note that **only the coordinates change**:

- `GEODIST` and `WITHDIST` distances remain `String`.
- `WITHHASH` values remain `Integer`.

If you already converted coordinates with `.to_f`, no change is needed —
`Float#to_f` returns itself.

## 2. Everything else returns the same values

All other wrapped commands reshape RESP3 replies back to the Ruby objects you
got under RESP2, so no code changes are required for:

- Hash-returning commands: `HGETALL`, `CONFIG GET`, `XINFO`, `XPENDING`, …
- `*WITHSCORES` / score-returning commands: `ZRANGE … with_scores`, `ZSCORE`,
  `ZPOPMAX`/`ZPOPMIN`, `ZMPOP`, `ZSCAN`, `ZINCRBY`, `INCRBYFLOAT`,
  `HINCRBYFLOAT` (scores stay `Float`, including `inf` → `Float::INFINITY`).
- Boolean-returning commands: `SISMEMBER`, `HEXISTS`, `EXPIRE`, `SET … nx:`, …
  (still `true`/`false`).
- `HRANDFIELD … with_values`, `ZRANDMEMBER … with_scores` (still paired arrays).
- Sets (`SMEMBERS`, `SINTER`, …) — still `Array`.
- Pub/Sub messages — still `["message", channel, payload]`.
- `SENTINEL` subcommands — still arrays of hashes / hashes.

## 3. Old servers keep working (automatic RESP2 fallback)

Servers that don't support RESP3 are detected on connect and the client
transparently reconnects as RESP2 — you don't need to configure anything. This
covers:

- **Redis < 6.0**, which has no `HELLO` command at all.
- Any server replying `NOPROTO` to `HELLO 3`.

The fallback applies to every client type (standalone, `Redis::Distributed`,
sentinel, and `Redis::Cluster`) and every execution path (single commands,
`pipelined`, `multi`, `watch`, and pub/sub).

When a fallback happens, the client emits a one-time warning so the protocol
switch isn't silent:

```
Redis: redis://127.0.0.1:6379 does not support RESP3 (the HELLO 3 handshake
failed); falling back to RESP2. Pass `protocol: 2` to select RESP2 explicitly
and silence this warning.
```

Passing `protocol: 2` (see below) skips the RESP3 handshake entirely, so it both
selects RESP2 and suppresses the warning.

## 4. Staying on RESP2

If you'd rather not adopt RESP3 yet, pass `protocol: 2` and behavior is
identical to redis-rb 5.x:

```ruby
Redis.new(protocol: 2, url: "redis://...")
```

This is also the simplest way to preserve the old shapes for **raw / unwrapped
commands** (see below).

## 5. Caveat: raw and unwrapped commands

redis-rb reshapes the commands it wraps, but if you send a command it does not
wrap — via `redis.call(...)` or an unknown method handled by `method_missing` —
you now receive the **native RESP3 value**, because there is no reshape in
between:

| Server reply type | RESP2 (5.x)      | RESP3 (6.0)       |
|-------------------|------------------|-------------------|
| map               | flat `Array`     | `Hash`            |
| double            | `String`         | `Float`           |
| boolean           | `Integer` (1/0)  | `true` / `false`  |
| big number        | `String`         | `Integer`         |
| set               | `Array`          | `Array`           |
| verbatim string   | `String`         | `String`          |
| null              | `nil`            | `nil`             |

This typically affects introspection commands you call raw, such as
`CLIENT INFO`, `MEMORY STATS`, `ACL GETUSER`, `COMMAND DOCS`, or
`FUNCTION STATS`. If you depend on the RESP2 shape for one of these, call it on
a `protocol: 2` client.
