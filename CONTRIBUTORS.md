# Contributing to redis-rb

Thanks for your interest in contributing. This guide covers how the repository is laid out, how to run the test suite locally, and what a pull request needs before it can be merged.

## Contributions we need

Bug fixes, support for new Redis commands, documentation improvements and test coverage are all welcome. If you are unsure where to start, look through the [open issues](https://github.com/redis/redis-rb/issues); newly released Redis commands that the gem does not wrap yet are a good first contribution, since the process is well documented below.

Before starting a larger feature, open an issue describing what you want to add and how it should behave. It may already be underway, or there may be design constraints worth knowing first.

## Two gems, one repository

This tree ships two gems. Keep that in mind when deciding which files a change touches:

| Gem | Source | Gemspec | What it is |
|-----|--------|---------|------------|
| `redis` | `lib/` | `redis.gemspec` | Standalone and Sentinel client, plus `Redis::Distributed` (client-side sharding) |
| `redis-clustering` | `cluster/lib/` | `cluster/redis-clustering.gemspec` | `Redis::Cluster`, a thin subclass of `Redis` built on `redis-cluster-client` |

The cluster gem reuses `lib/redis/commands/**` from the main gem, so most command additions land in `lib/` and work on all three client types automatically. Cluster-only behaviour (routing overrides, reply aggregation, transaction adapter) lives under `cluster/lib/`.

`AGENTS.md` at the repository root is a detailed architecture tour (layering, reply reshaping, connection lifecycle, pub/sub, cluster routing). Read it before touching anything beyond a single command method.

## Development setup

You need Ruby 3.2 or newer, Bundler, and Docker with Docker Compose (profiles support).

```sh
git clone https://github.com/<your-user>/redis-rb.git
cd redis-rb
bundle install
BUNDLE_GEMFILE=cluster/Gemfile bundle install   # the cluster gem has its own bundle
```

Redis servers for the test suite run in Docker from the prebuilt `redislabs/client-libs-test` image. Topologies are selected by Compose profile:

```sh
make start_all        # standalone + replica + 3 sentinels + 6-node cluster
make test             # run the whole suite
make stop_all         # tear everything down
make all              # start, test, stop in one go
```

Or drive Compose directly when you only need one topology:

```sh
docker compose --profile standalone up -d --wait
docker compose --profile sentinel   up -d --wait
docker compose --profile cluster    up -d --wait
docker compose --profile modules    up -d --wait   # Redis Stack, only needed for Redis < 8
docker compose --profile all down -v
```

Pin a server version with `REDIS_VERSION=8.4.3 make start_all`. Image tags exist per `major.minor.patch` (for example `7.2.14`, `8.2.6`, `8.8.0`); a bare `8.4` tag generally does not.

### macOS note

The Compose stack uses host networking so sentinel and cluster nodes advertise `127.0.0.1`. On Docker Desktop you must enable **Settings → Resources → Network → Enable host networking**, otherwise the containers come up healthy but their ports are not reachable from the host. The Unix-socket test (`test_connecting_to_unix_domain_socket`) does not work on macOS because bind-mounted AF_UNIX sockets do not cross the Docker Desktop VM boundary; it passes on Linux CI.

## Running tests

`bundle exec rake test` runs five Minitest groups defined in the `Rakefile`:

```sh
bundle exec rake test:redis         # lib/redis core
bundle exec rake test:distributed   # Redis::Distributed
bundle exec rake test:sentinel      # Sentinel mode
bundle exec rake test:modules       # module commands (JSON.*, FT.*, ...)
BUNDLE_GEMFILE=cluster/Gemfile bundle exec rake test:cluster   # cluster gem
```

The cluster group must run with `BUNDLE_GEMFILE=cluster/Gemfile`; the root bundle does not include `redis-cluster-client`.

Run a single file or test with Minitest options:

```sh
bundle exec rake test:redis TEST=test/redis/commands_on_strings_test.rb
bundle exec rake test:redis TEST=test/redis/commands_on_strings_test.rb TESTOPTS="--name=/incr/"
BUNDLE_GEMFILE=cluster/Gemfile bundle exec rake test:cluster TEST=cluster/test/commands_on_strings_test.rb
```

Useful environment knobs:

| Variable | Effect |
|----------|--------|
| `PROTOCOL=2` | Run over RESP2 instead of the default RESP3 |
| `DRIVER=hiredis` | Use the `hiredis-client` C driver instead of the pure-Ruby one |
| `REDIS_VERSION=x.y.z` | Server image tag to boot |
| `REDIS_SOCKET_PATH=...` | Override the Unix socket path (default `tmp/redis.sock`, created by the standalone container) |
| `VERBOSE=1` | Verbose Minitest output |

CI runs every group under **both** RESP3 and RESP2, with both drivers, across MRI 3.2 to 4.0 and TruffleRuby, against several Redis versions from 7.2 to the latest release candidate. Anything that reshapes replies should be checked locally under at least `PROTOCOL=2` and `PROTOCOL=3` before you open a PR.

Test files must live under `test/redis`, `test/distributed`, `test/sentinel`, `test/modules` or `cluster/test`. The Rakefile aborts if a `*_test.rb` exists anywhere else.

### Gating tests by server version

Tests for commands that only exist on newer servers wrap themselves in `target_version` from `test/helper.rb`:

```ruby
def test_hgetex
  target_version "8.0" do
    # ...
  end
end
```

The suite skips the body on older servers, which is what lets the CI matrix include Redis 7.2.

## Linting

```sh
bundle exec rubocop
```

Configuration is in `.rubocop.yml` at the repository root and covers both gems. CI fails on offences. Every Ruby file starts with `# frozen_string_literal: true`; keep it when creating files.

## Adding a new Redis command

This is the most common contribution, so it has its own end-to-end guide: `specs/adding-commands.md`. The short version:

1. Add a method to the matching module under `lib/redis/commands/<category>.rb` that builds the argument array and calls `send_command`. Because `Redis::Commands` is mixed into `Redis`, `Redis::PipelinedConnection` and `Redis::Cluster`, the method is immediately available in direct calls, pipelines, transactions and cluster mode.
2. If the reply needs reshaping into idiomatic Ruby, reuse one of the lambdas at the top of `lib/redis/commands.rb` (`Boolify`, `Hashify`, `Floatify`, ...) or add one. Lambdas must accept both the RESP2 and RESP3 wire shape and return the same Ruby value. Do not coerce inside the command method itself.
3. Add a corresponding method to `lib/redis/distributed.rb`. `Redis::Distributed` does **not** include `Commands`; every method is defined explicitly so it can route by key. Multi-key commands whose keys may land on different nodes raise `CannotDistribute`.
4. Check whether `Redis::Cluster` needs anything. Routing is the driver's job, so usually nothing. If the driver's default routing is wrong, fix it through `DEFAULT_COMMAND_ROUTINGS` in `cluster/lib/redis/cluster.rb`, not by enumerating nodes in Ruby.
5. Write Yard docstrings (`@param`, `@return`, `@example`) in the same style as the neighbouring methods.
6. Add tests: a shared lint module under `test/lint/` where the behaviour is identical across clients, and per-client test files under `test/redis/`, `test/distributed/` and `cluster/test/`. Gate with `target_version` if the command is newer than Redis 7.2.

Follow the local conventions in the file you are editing: symbols for the command verb (`[:incr, key]`), explicit coercion for numeric arguments (`Integer(x)`, `Float(x)`), keyword arguments for optional flags.

### AI-assisted contributions

The repository ships a Claude Code skill, `.claude/skills/add-new-command`, that walks through the checklist above from a command specification in `command_specs/`. You can invoke it as `/add-new-command <COMMAND>` from Claude Code. It is a convenience, not a requirement, and its output is held to the same review standard as hand-written code.

## Pull request checklist

Before opening a PR:

- [ ] `bundle exec rubocop` passes.
- [ ] The affected test groups pass locally under `PROTOCOL=3` and `PROTOCOL=2`.
- [ ] New commands are implemented for `Redis`, `Redis::Distributed` and work on `Redis::Cluster`, with tests for each (or an explanation of why one client is excluded).
- [ ] Public methods have Yard docstrings.
- [ ] No unrelated changes, reformatting or version bumps. Maintainers bump `lib/redis/version.rb` and update `CHANGELOG.md` at release time.
- [ ] The PR description says what changed and why, and links the issue it closes if there is one.

Keep PRs focused. A small, well-tested change is reviewed and merged much faster than a large one that mixes several concerns.

## Code review process

Maintainers look at pull requests regularly and will leave feedback as soon as they can. Please respond to review comments within two weeks; PRs without activity after that may be closed, and you are welcome to reopen them when you have time.

## Reporting bugs

### Security vulnerabilities

Do **not** open a public issue for a security problem. Report it through the [Redis Vulnerability Disclosure Program](https://redis.io/redis-responsible-vulnerability-disclosure/) or email [security@redis.com](mailto:security@redis.com).

### Everything else

When filing an issue, include:

1. The `redis` gem version (and `redis-clustering` version if you use cluster mode).
2. The `redis-client` and, if applicable, `hiredis-client` versions from your `Gemfile.lock`.
3. The Redis server version and topology (standalone, Sentinel, Cluster, Distributed).
4. Ruby version and implementation (MRI, TruffleRuby, JRuby).
5. A minimal script that reproduces the problem.
6. What you expected to see, and what you saw instead, including the full exception and backtrace.

## Suggesting a feature

Check the issue list first; someone may already have proposed it, or it may have been declined with reasoning. If not, open an issue describing the feature and how it should behave from the caller's point of view. For new Redis commands, a link to the command's page on [redis.io](https://redis.io/commands/) is enough.

## License

By contributing you agree that your contributions are licensed under the [MIT license](LICENSE) that covers the project.
