<!-- GitHub release body. Format rules (reference: the published 6.0.0 release):
     - No `# title` line: the release title (`X.Y.Z`, no `v`) is set by `--title`.
     - GitHub renders single newlines in a release body as line breaks, so NEVER hard-wrap:
       every paragraph and every bullet is exactly one line, however long. No indented
       continuation lines.
     - Section headings are `###` with the emoji shown below; sub-groups are `####`.
     - Keep only the sections that have entries, in this order. Do not add other sections
       (no Gemfile snippet, no "Dependency updates", no "Full changelog"): dependency pins go
       under Maintenance.
     - Bullets come from the `# X.Y.Z` section of CHANGELOG.md, unwrapped, each naming its Redis
       server version in parentheses and ending with `(#PR)`. Cluster-specific ones from
       cluster/CHANGELOG.md go under a `#### Cluster gem (`redis-clustering`) only` sub-group of
       the section they belong to.
     - Delete this comment. -->
This is a <major / minor / patch> release of the `redis` and `redis-clustering` gems. <The two or three headline changes, each naming the Redis server version it needs. No reasoning, no history.>

Requires **Ruby 3.2+** and works with **Redis server 6.0+**. <Say that newer commands need the server version named next to them.>

### 🔥 Breaking changes

- ...

#### Cluster gem (`redis-clustering`) only

- ...

### 🚀 New features

- ...

#### Cluster gem (`redis-clustering`) only

- ...

### ⚠️ Experimental

- ...

### 🐛 Bug fixes

- ...

### 🧰 Maintenance

- Pin `redis-client` to `D.E.F` (previously `A.B.C`). (#PR)
- ...

### Upgrade notes

1. <What a user upgrading from the previous release has to check; "Everything else is drop-in." last.>
