#!/usr/bin/env bash
# Reports the state of the pinned driver dependencies before a release.
#
#   bash .claude/skills/prepare-release/scripts/check_deps.sh
#
# For redis-client (redis.gemspec), redis-cluster-client (cluster/redis-clustering.gemspec) and
# hiredis-client (Gemfile, must track redis-client's version) it prints the current pin, the
# latest version on RubyGems, every version in between, known security advisories (GitHub
# Advisory Database) for the pinned version, and where to read what changed. Read-only; the
# judgement "breaking or not" is left to the skill, which reads the linked changelogs.

set -uo pipefail

pin() { sed -nE "s/.*add_runtime_dependency\('$1', *'([^']+)'\).*/\1/p" "$2" | head -1; }
lock_version() { sed -nE "s/^    $1 \(([^)]+)\)$/\1/p" "$2" | head -1; }

json_versions() { # gem -> newest-first list of version numbers from RubyGems
  curl -fsSL "https://rubygems.org/api/v1/versions/$1.json" 2>/dev/null | ruby -rjson -e '
    JSON.parse(STDIN.read).reject { |v| v["prerelease"] }.map { |v| v["number"] }.uniq
        .sort_by { |n| Gem::Version.new(n) }.reverse.each { |n| puts n }' 2>/dev/null
}
runtime_deps() { # gem version -> "name constraint" lines
  curl -fsSL "https://rubygems.org/api/v2/rubygems/$1/versions/$2.json" 2>/dev/null | ruby -rjson -e '
    JSON.parse(STDIN.read).dig("dependencies", "runtime").to_a.each { |d| puts "  #{d["name"]} #{d["requirements"]}" }' 2>/dev/null
}
advisories() { # gem version -> advisory summary lines
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh api "/advisories?ecosystem=rubygems&affects=$1@$2&per_page=20" \
      --jq '.[] | "  \(.ghsa_id) \(.severity) \(.summary) (patched: \([.vulnerabilities[] | select(.package.name=="'"$1"'") | .first_patched_version // "none"] | join(", ")))"' 2>/dev/null \
      || echo "  (advisory lookup failed)"
  else
    echo "  (gh unavailable — check https://github.com/advisories?query=ecosystem%3Arubygems+$1 by hand)"
  fi
}

report() { # gem current changelog-url
  local gem="$1" current="$2" url="$3"
  echo "=== $gem ==="
  echo "CURRENT_${gem//-/_}: ${current:-unknown}"
  local versions latest newer
  versions="$(json_versions "$gem")"
  latest="$(printf '%s\n' "$versions" | head -1)"
  echo "LATEST_${gem//-/_}: ${latest:-unknown (RubyGems unreachable)}"
  if [ -n "$current" ] && [ -n "$latest" ]; then
    newer="$(printf '%s\n' "$versions" | ruby -e 'cur = Gem::Version.new(ARGV[0]); STDIN.each_line { |l| v = l.strip; puts v if Gem::Version.new(v) > cur }' "$current" | tr '\n' ' ')"
    echo "NEWER_VERSIONS_${gem//-/_}: ${newer:-none}"
    [ -n "$newer" ] && { echo "Runtime deps of $gem $latest:"; runtime_deps "$gem" "$latest"; }
  fi
  echo "Advisories affecting $gem $current:"; advisories "$gem" "$current"
  echo "CHANGELOG_${gem//-/_}: $url"
  echo
}

rc="$(pin redis-client redis.gemspec)"
rcc="$(pin redis-cluster-client cluster/redis-clustering.gemspec)"
hc="$(lock_version hiredis-client Gemfile.lock)"

report redis-client "$rc" "https://github.com/redis-rb/redis-client/blob/master/CHANGELOG.md (raw: https://raw.githubusercontent.com/redis-rb/redis-client/master/CHANGELOG.md)"
report redis-cluster-client "$rcc" "https://github.com/redis-rb/redis-cluster-client/releases (no CHANGELOG file; diff tags with: gh api repos/redis-rb/redis-cluster-client/compare/v<old>...v<new> --jq '.commits[].commit.message')"
report hiredis-client "$hc" "https://github.com/redis-rb/redis-client/blob/master/CHANGELOG.md (same repository as redis-client; versions move in lockstep)"

echo "=== Consistency ==="
[ "$rc" = "$hc" ] && echo "HIREDIS_LOCKSTEP: ok ($rc)" || echo "HIREDIS_LOCKSTEP: MISMATCH redis-client=$rc hiredis-client=$hc"
echo "LOCK_redis_client_root: $(lock_version redis-client Gemfile.lock)"
echo "LOCK_redis_client_cluster: $(lock_version redis-client cluster/Gemfile.lock)"
echo "LOCK_redis_cluster_client: $(lock_version redis-cluster-client cluster/Gemfile.lock)"
echo "CLUSTER_CLIENT_REQUIRES_REDIS_CLIENT: $(sed -nE '/^    redis-cluster-client \(/{n;s/^      redis-client (.*)$/\1/p;}' cluster/Gemfile.lock)"
