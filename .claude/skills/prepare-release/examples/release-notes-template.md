# redis-rb X.Y.Z

<One paragraph: what kind of release this is (major / minor / patch) and the two or three
headline changes, each naming the Redis server version it needs. No reasoning, no history.>

```ruby
gem "redis", "~> X.Y"
# or, for cluster deployments:
gem "redis-clustering", "~> X.Y"
```

Requires **Ruby 3.2+**. <State the minimum Redis server version and that newer commands need
the server version named next to them.>

<!-- Keep only the sections that have entries, in this order. Copy the bullets from the
     `# X.Y.Z` section of CHANGELOG.md (and cluster-specific ones from cluster/CHANGELOG.md),
     grouped by server version where that helps a reader decide what they can use. -->

## Breaking changes

- ...

## New features

### Redis 8.12
- ...

### Redis 8.8
- ...

## Bug fixes

- ...

## Dependency updates

- `redis-client` A.B.C → D.E.F
- `redis-cluster-client` A.B.C → D.E.F

## Full changelog

- [CHANGELOG.md](https://github.com/redis/redis-rb/blob/vX.Y.Z/CHANGELOG.md)
- [cluster/CHANGELOG.md](https://github.com/redis/redis-rb/blob/vX.Y.Z/cluster/CHANGELOG.md)
- Compare: https://github.com/redis/redis-rb/compare/vPREV...vX.Y.Z
