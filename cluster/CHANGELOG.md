# Unreleased

- **Experimental**: add first-class support for the `HIMPORT` command family (Redis 8.10) — the
  client API may change in a future minor release without a major version bump: `himport_prepare`,
  `himport_discard` and `himport_discard_all` execute on all master nodes (per the commands'
  `request_policy:all_shards` tip) and return a single aggregated reply; `himport_set` routes by its
  key's hash slot with MOVED/ASK handling preserved. Routing is performed natively by
  redis-cluster-client, which since 0.16.6 parses command tips and per-subcommand key specs (see
  the pin entry below). Fieldset loss (node failover, topology reload, redirection to a
  fresh connection) is repaired automatically by re-fanning out the last prepared schema and
  retrying the SET once; disable with `himport_auto_prepare: false`. Partial fan-out failures raise
  `Redis::Cluster::CommandErrorCollection`. Inside `multi`, an `himport_set` pins the transaction to
  its key's slot and an accompanying `himport_prepare` executes on that same pinned connection.
- **Breaking**: redis-cluster-client 0.16.6+ routes commands by their server-declared command tips
  (`request_policy`/`response_policy`), which changes the behavior of a few commands that were
  previously sent to one arbitrary node:
  - `SLOWLOG GET` now returns an **array with one entry list per master** (previously a single
    node's entry list) — the only reply-*shape* change.
  - `SLOWLOG LEN` and `LATENCY RESET` still return an `Integer`, but now the **sum across all
    masters** instead of one node's value.
  - `FUNCTION LOAD`/`DELETE`/`FLUSH`/`RESTORE` now execute on **all masters** (reply unchanged).
    This corrects a bug where functions were loaded onto a single arbitrary node and `FCALL`
    failed for keys owned by the other masters.
  - Container commands with keys in subcommands (e.g. `XINFO STREAM`) now route directly to the
    key's slot owner and can pin a `multi` transaction (previously they raised
    `Redis::Cluster::TransactionConsistencyError`).
  Everything covered by the driver's legacy routing table (`PING`, `DBSIZE`, `KEYS`, `FLUSHALL`,
  `SCRIPT`, `CONFIG`, `CLIENT`, `ACL`, `MEMORY`, `INFO`, multi-key commands, …) is unchanged.
- **Breaking**: the client now negotiates RESP3 (`HELLO 3`) by default; pass `protocol: 2` to keep
  RESP2. The only command whose return value changes is GEO — `GEOPOS` and `GEOSEARCH`/`GEORADIUS`
  with `WITHCOORD` now return coordinates as `Float` instead of `String`. Nodes without RESP3
  (Redis < 6.0, or anything replying `NOPROTO`) transparently fall back to RESP2. See
  [the RESP3 migration guide](../specs/migration-resp3.md).
- **Breaking**: now requires Ruby 3.2 or newer.
- Pin `redis-cluster-client` to the exact version `0.16.7`: the driver ships behavior changes in
  patch releases (see the command-tips entry above), so upgrades — including patches — are gated
  behind a deliberate, suite-verified release.
