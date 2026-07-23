# Unreleased

- Add first-class support for the `HIMPORT` command family (Redis 8.10): `himport_prepare`,
  `himport_discard` and `himport_discard_all` execute on all master nodes (per the commands'
  `request_policy:all_shards` tip) and return a single aggregated reply; `himport_set` routes by its
  key's hash slot with MOVED/ASK handling preserved. Fieldset loss (node failover, topology reload,
  redirection to a fresh connection) is repaired automatically by re-fanning out the last prepared
  schema and retrying the SET once; disable with `himport_auto_prepare: false`. Partial fan-out
  failures raise `Redis::Cluster::CommandErrorCollection`.
- **Breaking**: the client now negotiates RESP3 (`HELLO 3`) by default; pass `protocol: 2` to keep
  RESP2. The only command whose return value changes is GEO — `GEOPOS` and `GEOSEARCH`/`GEORADIUS`
  with `WITHCOORD` now return coordinates as `Float` instead of `String`. Nodes without RESP3
  (Redis < 6.0, or anything replying `NOPROTO`) transparently fall back to RESP2. See
  [the RESP3 migration guide](../specs/migration-resp3.md).
- **Breaking**: now requires Ruby 3.3 or newer, tracking the Ruby versions still under official
  maintenance. See https://www.ruby-lang.org/en/downloads/branches/.
- Pin `redis-cluster-client` to `~> 0.16.0` (patch-only), so bug/security patches flow automatically
  while minor/major upgrades are gated behind a deliberate release.
