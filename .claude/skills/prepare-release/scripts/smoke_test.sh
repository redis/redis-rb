#!/usr/bin/env bash
# Installs the published gems from RubyGems into a throwaway GEM_HOME and runs SET/GET.
#
#   bash .claude/skills/prepare-release/scripts/smoke_test.sh <version> [--cluster]
#
# Env: REDIS_URL (default redis://127.0.0.1:6381, the compose `standalone` profile),
#      CLUSTER_URL (default redis://127.0.0.1:16380, the compose `cluster` profile),
#      RETRIES (default 10) × 60s wait for RubyGems to index a freshly pushed gem.
# Uses only the public RubyGems index — never the local checkout — so it proves the release.

set -uo pipefail
version="${1:?usage: smoke_test.sh <version> [--cluster]}"
with_cluster="${2:-}"
home="$(mktemp -d "${TMPDIR:-/tmp}/redis-rb-smoke.XXXXXX")"
export GEM_HOME="$home" GEM_PATH="$home"
unset BUNDLE_GEMFILE RUBYOPT
retries="${RETRIES:-10}"

install() { # gem
  # --remote with the public source only: a redis-<version>.gem left in the repo root by Step 8
  # must never satisfy this install, or the test would pass for a gem that was never published.
  local i
  for i in $(seq 1 "$retries"); do
    if gem install "$1" -v "$version" --remote --clear-sources --source https://rubygems.org \
         --no-document --quiet >/dev/null 2>&1; then echo "INSTALL $1 $version: ok"; return 0; fi
    echo "  $1 $version not installable yet (attempt $i/$retries); waiting 60s for the RubyGems index"
    sleep 60
  done
  echo "INSTALL $1 $version: FAIL"; return 1
}

install redis || exit 1
ruby -e '
  require "redis"
  abort "loaded Redis::VERSION #{Redis::VERSION}, expected #{ARGV[1]}" unless Redis::VERSION == ARGV[1]
  r = Redis.new(url: ARGV[0])
  key = "redis-rb:smoke:#{Process.pid}"
  r.set(key, "ok", ex: 60)
  v = r.get(key)
  r.del(key)
  abort "GET returned #{v.inspect}" unless v == "ok"
  puts "SMOKE redis: ok (#{ARGV[0]}, server #{r.info("server")["redis_version"]}, protocol #{r.instance_variable_get(:@client).protocol rescue "?"})"
' "${REDIS_URL:-redis://127.0.0.1:6381}" "$version" || { echo "SMOKE redis: FAIL"; exit 1; }

if [ "$with_cluster" = "--cluster" ]; then
  install redis-clustering || exit 1
  ruby -e '
    require "redis-clustering"
    c = Redis::Cluster.new(nodes: [ARGV[0]])
    key = "redis-rb:smoke:#{Process.pid}"
    c.set(key, "ok", ex: 60)
    v = c.get(key)
    c.del(key)
    abort "GET returned #{v.inspect}" unless v == "ok"
    puts "SMOKE redis-clustering: ok (#{ARGV[0]})"
  ' "${CLUSTER_URL:-redis://127.0.0.1:16380}" || { echo "SMOKE redis-clustering: FAIL"; exit 1; }
fi

rm -rf "$home"
echo "SMOKE: all ok"
