#!/usr/bin/env bash
# Refreshes the lockfiles for a new version and verifies every file a release ships depends on.
#
#   bash .claude/skills/prepare-release/scripts/validate_metadata.sh <version>
#
# Edits only Gemfile.lock and cluster/Gemfile.lock (via `bundle lock`, which re-resolves the
# `redis (x.y.z)` entry from lib/redis/version.rb). Everything else is a check that prints
# CHECK <name>: ok | FAIL <reason>. Builds no gem. Exit status 1 when any check fails.

set -uo pipefail
version="${1:?usage: validate_metadata.sh <version>}"
fail=0
check() { # name ok-condition-exit-code message
  if [ "$2" -eq 0 ]; then echo "CHECK $1: ok"; else echo "CHECK $1: FAIL $3"; fail=1; fi
}

echo "=== Lockfiles ==="
out="$(bundle lock 2>&1)"; rc=$?; check lock_root $rc "bundle lock failed in repo root: $(printf '%s' "$out" | tail -1)"
out="$(BUNDLE_GEMFILE=cluster/Gemfile bundle lock 2>&1)"; rc=$?; check lock_cluster $rc "bundle lock failed for cluster/Gemfile: $(printf '%s' "$out" | tail -1)"

echo "=== Version ==="
v="$(sed -nE "s/.*VERSION = '([^']+)'.*/\1/p" lib/redis/version.rb)"
[ "$v" = "$version" ]; check version_rb $? "lib/redis/version.rb says '$v'"
grep -qE "^    redis \($version\)$" Gemfile.lock; check lock_root_version $? "Gemfile.lock lacks 'redis ($version)'"
grep -qE "^    redis \($version\)$" cluster/Gemfile.lock; check lock_cluster_version $? "cluster/Gemfile.lock lacks 'redis ($version)'"
grep -qE "^      redis \(= $version\)$" cluster/Gemfile.lock; check cluster_depends_on_redis $? "redis-clustering should depend on redis (= $version)"

echo "=== Gemspecs load ==="
for spec in redis.gemspec cluster/redis-clustering.gemspec; do
  out="$(cd "$(dirname "$spec")" && ruby -e '
    s = Gem::Specification.load(ARGV[0]) or abort "could not load"
    abort "version #{s.version}" unless s.version.to_s == ARGV[1]
    abort "no files" if s.files.empty?
    abort "CHANGELOG.md not shipped" unless s.files.include?("CHANGELOG.md")
    puts "#{s.name} #{s.version} files=#{s.files.size} deps=#{s.runtime_dependencies.map { |d| "#{d.name} #{d.requirement}" }.join(", ")}"
  ' "$(basename "$spec")" "$version" 2>&1)"
  rc=$?; echo "  $out"; check "gemspec_$(basename "$spec" .gemspec)" $rc "$out"
done

echo "=== Changelogs ==="
grep -qE "^# $version\$" CHANGELOG.md; check changelog_heading $? "CHANGELOG.md has no '# $version' heading"
grep -qE "^# $version\$" cluster/CHANGELOG.md; check cluster_changelog_heading $? "cluster/CHANGELOG.md has no '# $version' heading"
! grep -qiE '^# Unreleased' CHANGELOG.md cluster/CHANGELOG.md; check no_unreleased $? "an '# Unreleased' heading is still present"
first="$(grep -m1 -E '^# [0-9]' CHANGELOG.md)"; [ "$first" = "# $version" ]; check changelog_order $? "first heading in CHANGELOG.md is '$first'"

echo "=== Dependency pins ==="
rc="$(sed -nE "s/.*add_runtime_dependency\('redis-client', *'([^']+)'\).*/\1/p" redis.gemspec)"
hc="$(sed -nE 's/^    hiredis-client \(([^)]+)\)$/\1/p' Gemfile.lock)"
[ "$rc" = "$hc" ]; check hiredis_lockstep $? "redis-client $rc vs hiredis-client $hc (bundle lock --update hiredis-client)"
printf '%s' "$rc" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; check redis_client_exact_pin $? "redis-client pin '$rc' is not an exact version"
rcc="$(sed -nE "s/.*add_runtime_dependency\('redis-cluster-client', *'([^']+)'\).*/\1/p" cluster/redis-clustering.gemspec)"
printf '%s' "$rcc" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; check cluster_client_exact_pin $? "redis-cluster-client pin '$rcc' is not an exact version"

echo "=== Stray references to the previous version ==="
grep -rnE "VERSION = '" lib cluster/lib | grep -v "'$version'" | grep -v 'Redis::VERSION' | sed 's/^/  /'
echo "(anything listed above needs a look; test files using target_version(\"x.y.z\") refer to server versions and are fine)"

echo
if [ $fail -eq 0 ]; then echo "METADATA: ok"; else echo "METADATA: FAILED"; fi
exit $fail
