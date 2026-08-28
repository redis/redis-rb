# 6.0.0

## Breaking changes

- Route commands by their server-declared command tips (redis-cluster-client 0.16.6+):
  `SLOWLOG GET` now returns one entry list per master; `SLOWLOG LEN` and `LATENCY RESET` return
  the sum across all masters; `FUNCTION LOAD`/`DELETE`/`FLUSH`/`RESTORE` now execute on all
  masters; commands with keys in subcommands (e.g. `XINFO STREAM`) route to the key's slot owner.
- Use RESP3 (`HELLO 3`) by default; pass `protocol: 2` to keep RESP2. `GEOPOS` and
  `GEOSEARCH`/`GEORADIUS` with `WITHCOORD` now return coordinates as `Float` instead of `String`.
  See [the RESP3 migration guide](../specs/migration-resp3.md). (#1351)
- Require Ruby 3.2+. (#1353, #1365)

## New features

- Add `Redis::Cluster#keyspace_notifications`: a cluster-aware keyspace notification manager
  that subscribes on **every primary** (notifications are node-local in cluster and are not
  forwarded on the cluster bus, so a plain `subscribe` silently receives ~1/N of the events),
  dispatches parsed notifications from a single dispatcher thread, and reconciles reactively on
  node connection errors (`#refresh` is also public for post-scale-out reconciliation). Requires
  `notify-keyspace-events` to be enabled on every node, replicas included. See
  specs/keyspace-notifications/user-guide.md.
- Identify the client to every node via `CLIENT SETINFO` (`lib-name=redis-rb`,
  `lib-ver=<version>`). Extend the reported name with `driver_info:`, or disable with
  `driver_info: false`. (#1369)

## Experimental

- Add `himport_prepare`, `himport_set`, `himport_discard` and `himport_discard_all`
  (Redis 8.10 `HIMPORT`). Prepare/discard fan out to all masters; `himport_set` routes by its
  key's hash slot. Lost fieldsets are re-prepared and retried automatically; disable with
  `himport_auto_prepare: false`. The API may change in a future minor release. (#1364)

## Maintenance

- Pin `redis-cluster-client` to the exact version `0.17.0`.
