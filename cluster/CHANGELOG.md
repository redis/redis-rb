# Unreleased

- **Breaking**: the client now negotiates RESP3 (`HELLO 3`) by default; pass `protocol: 2` to keep
  RESP2. The only command whose return value changes is GEO — `GEOPOS` and `GEOSEARCH`/`GEORADIUS`
  with `WITHCOORD` now return coordinates as `Float` instead of `String`. Nodes without RESP3
  (Redis < 6.0, or anything replying `NOPROTO`) transparently fall back to RESP2. See
  [the RESP3 migration guide](../specs/migration-resp3.md).
- **Breaking**: now requires Ruby 3.3 or newer, tracking the Ruby versions still under official
  maintenance. See https://www.ruby-lang.org/en/downloads/branches/.
