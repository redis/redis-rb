#!/usr/bin/env bash
# Lists what changed since the previous release and what the changelogs do not yet cover.
#
#   bash .claude/skills/prepare-release/scripts/changelog_gaps.sh <prev-tag> [<end-ref>] [<label-pattern>]
#
# prev-tag       previous release tag, e.g. v6.0.0 (empty string = repository root)
# end-ref        what to compare against; default HEAD (run it on the synced release branch)
# label-pattern  case-insensitive regex matched against PR label names to flag breaking changes;
#                default "break". Pass "-" to skip the GitHub label scan.
#
# Output sections are plain text for the skill to read; the summary lines are KEY: value.
# Read-only: never edits files or touches GitHub beyond reads.

set -uo pipefail

prev="${1:-}"
end="${2:-HEAD}"
label_re="${3:-break}"
range="${prev:+$prev..}$end"

echo "RANGE: $range"
echo
echo "=== Commits (oldest first; merges excluded) ==="
git log --reverse --no-merges --format='%h %ad %s' --date=short "$range"
echo

# PR numbers come from subjects only ("… (#1234)"); bodies reference issues ("Fix #1290"), which
# a changelog entry may cite in addition but which are not gaps.
prs="$(git log --no-merges --format='%s' "$range" | grep -oE '\(#[0-9]+\)' | tr -d '#()' | sort -un)"
echo "PR_COUNT: $(printf '%s\n' $prs | grep -c . || true)"

missing_main=""; missing_cluster=""
for n in $prs; do
  grep -q "#$n\b" CHANGELOG.md || missing_main="$missing_main $n"
  grep -q "#$n\b" cluster/CHANGELOG.md || missing_cluster="$missing_cluster $n"
done
echo "MISSING_IN_CHANGELOG:${missing_main:- none}"
echo "MISSING_IN_CLUSTER_CHANGELOG:${missing_cluster:- none}"
echo "(cluster/CHANGELOG.md only needs cluster-specific behaviour; treat its list as candidates, not gaps)"
echo

echo "=== Changelog edits already made in this range (check none landed under an already-released heading) ==="
git log --format='%h %s' "$range" -- CHANGELOG.md cluster/CHANGELOG.md
echo "FIRST_RELEASED_HEADING_MAIN: $(grep -nE '^# [0-9]+\.[0-9]+\.[0-9]+' CHANGELOG.md | head -1)"
echo "UNRELEASED_HEADING_MAIN: $(grep -nE '^# Unreleased' CHANGELOG.md | head -1 || echo none)"
echo "UNRELEASED_HEADING_CLUSTER: $(grep -nE '^# Unreleased' cluster/CHANGELOG.md | head -1 || echo none)"
echo

if [ "$label_re" = "-" ]; then
  echo "BREAKING_SCAN: skipped"
  exit 0
fi
if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  echo "BREAKING_SCAN: unavailable (gh missing or unauthenticated) — review the commit list by hand"
  exit 0
fi

echo "=== PR labels (pattern: /$label_re/i) ==="
breaking=""
for n in $prs; do
  labels="$(gh pr view "$n" --json labels --jq '[.labels[].name] | join(", ")' 2>/dev/null)" || { echo "#$n: (not a PR or not readable)"; continue; }
  echo "#$n: ${labels:-no labels}"
  printf '%s' "$labels" | grep -Eiq "$label_re" && breaking="$breaking $n"
done
echo "BREAKING_PRS:${breaking:- none}"
