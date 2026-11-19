#!/usr/bin/env bash
# Deterministic preflight for the prepare-release skill.
#
# Takes the requested version ("6.1.0") and reports — without any LLM reasoning — the release
# kind, branch/tag names, the previous tag, what already exists on origin, whether the caller
# may perform remote actions, and which stage of the release process we are at. The skill body
# branches on the KEY: value lines. Never mutates the repository or GitHub.
#
# Run from the repo root:
#   bash .claude/skills/prepare-release/scripts/preflight.sh 6.1.0

set -uo pipefail

version="${1:-}"
version="$(printf '%s' "$version" | sed -E 's/^[[:space:]]*v?//; s/[[:space:]]+$//')"

if [ -z "$version" ]; then
  echo "RESOLUTION: no_version"
  echo "Ask the user which version to release (x.y.z)."
  exit 0
fi
if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "RESOLUTION: bad_version"
  echo "VERSION: $version"
  echo "Versions must be x.y.z (no pre-release suffix). Ask the user for a corrected version."
  exit 0
fi

major="${version%%.*}"; rest="${version#*.}"; minor="${rest%%.*}"; patch="${rest#*.}"
if [ "$patch" != "0" ]; then kind=patch; elif [ "$minor" != "0" ]; then kind=minor; else kind=major; fi
branch="$major.$minor"
tag="v$version"

echo "RESOLUTION: ok"
echo "VERSION: $version"
echo "KIND: $kind"
echo "BRANCH: $branch"
echo "TAG: $tag"
echo "CURRENT_VERSION: $(sed -nE "s/.*VERSION = '([^']+)'.*/\1/p" lib/redis/version.rb)"

# --- git state --------------------------------------------------------------------------------
if git fetch --quiet --prune --tags origin 2>/dev/null; then echo "FETCH: ok"; else echo "FETCH: failed (offline? results below may be stale)"; fi

# highest existing tag that sorts below the requested version
prev_tag="$({ git tag -l 'v[0-9]*' | sed 's/^v//' | grep -vx "$version"; echo "$version"; } | sort -V | grep -B1 -x "$version" | head -1)"
[ "$prev_tag" = "$version" ] && prev_tag=""
echo "PREV_TAG: ${prev_tag:+v$prev_tag}"
[ -z "$prev_tag" ] && echo "PREV_TAG_NOTE: no earlier tag found; compare against the first commit"

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  echo "TAG_EXISTS: yes"; tag_exists=yes
else
  echo "TAG_EXISTS: no"; tag_exists=no
fi

if git rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then
  echo "BRANCH_REMOTE: exists"; branch_remote=yes
  echo "MASTER_AHEAD_OF_BRANCH: $(git rev-list --count "origin/$branch..origin/master")"
  echo "BRANCH_AHEAD_OF_MASTER: $(git rev-list --count "origin/master..origin/$branch")"
  echo "BRANCH_VERSION: $(git show "origin/$branch:lib/redis/version.rb" 2>/dev/null | sed -nE "s/.*VERSION = '([^']+)'.*/\1/p")"
else
  echo "BRANCH_REMOTE: missing"; branch_remote=no
fi
if git rev-parse -q --verify "refs/heads/$branch" >/dev/null; then echo "BRANCH_LOCAL: exists"; else echo "BRANCH_LOCAL: missing"; fi
echo "CURRENT_BRANCH: $(git rev-parse --abbrev-ref HEAD)"

if [ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then echo "WORKTREE: clean"; else echo "WORKTREE: dirty (tracked changes present)"; fi

# --- GitHub access ----------------------------------------------------------------------------
role=unknown; login=""; repo=""
if ! command -v gh >/dev/null 2>&1; then
  echo "GH: missing (install GitHub CLI)"
elif ! login="$(gh api user --jq .login 2>/dev/null)" || [ -z "$login" ]; then
  # `gh auth status` can report success with a stale token or a blocked network; a real API call is the test.
  echo "GH: unavailable — $(gh api user 2>&1 | head -1 | cut -c1-120)"
  echo "GH_HINT: re-authenticate with 'gh auth login -h github.com'; a TLS/certificate error means run outside the sandbox"
else
  echo "GH: ok"
  # Permission is checked on the canonical repository, never on a fork: on a fork the caller is
  # always admin, which must not unlock live mode.
  repo="$(gh repo view --json nameWithOwner,isFork,parent \
    --jq 'if .isFork then (.parent.owner.login + "/" + .parent.name) else .nameWithOwner end' 2>/dev/null || true)"
  echo "GH_LOGIN: $login"
  echo "GH_REPO: ${repo:-?}"
  if [ -n "$repo" ]; then
    perm="$(gh api "repos/$repo/collaborators/$login/permission" --jq .permission 2>/dev/null || echo error)"
    echo "GH_PERMISSION: $perm"
    # Push access to the canonical repository is what a release needs (branch, PR, draft release).
    case "$perm" in
      admin|maintain|write) role=maintainer ;;
      error) role=unknown ;;
      *) role=contributor ;;
    esac
  fi
fi
echo "ROLE: $role"
origin_url="$(git remote get-url origin 2>/dev/null || true)"
echo "ORIGIN: ${origin_url:-none}"
origin_ok=no
[ -n "$repo" ] && printf '%s' "$origin_url" | grep -Eq "[:/]${repo}(\.git)?/?$" && origin_ok=yes
if [ "$role" = maintainer ] && [ "$origin_ok" = yes ]; then
  echo "MODE: live"
elif [ "$role" = maintainer ]; then
  echo "MODE: dry-run (origin is not $repo; live mode only runs from a clone of the canonical repository)"
else
  echo "MODE: dry-run (local changes only: no push, no PR, no release)"
fi

# --- stage detection --------------------------------------------------------------------------
stage=start
if [ "$tag_exists" = yes ]; then
  stage=released
elif [ "$role" != unknown ] && [ -n "$repo" ]; then
  if [ "$(gh release view "$tag" --json isDraft --jq .isDraft 2>/dev/null)" = "true" ]; then
    stage=draft_ready
    echo "DRAFT_URL: $(gh release view "$tag" --json url --jq .url 2>/dev/null)"
  else
    pr_json="$(gh pr list --repo "$repo" --head "$branch" --base master --state all --search "\"Release $version\" in:title" --json number,state,url --jq '.[0]' 2>/dev/null || true)"
    if [ -n "$pr_json" ] && [ "$pr_json" != "null" ]; then
      echo "PR_NUMBER: $(printf '%s' "$pr_json" | sed -nE 's/.*"number":([0-9]+).*/\1/p')"
      echo "PR_URL: $(printf '%s' "$pr_json" | sed -nE 's/.*"url":"([^"]+)".*/\1/p')"
      case "$pr_json" in
        *'"state":"MERGED"'*) stage=pr_merged ;;
        *'"state":"OPEN"'*)   stage=pr_open ;;
        *)                    stage=pr_closed ;;
      esac
    elif [ "$branch_remote" = yes ] && [ "$(git show "origin/$branch:lib/redis/version.rb" 2>/dev/null | sed -nE "s/.*VERSION = '([^']+)'.*/\1/p")" = "$version" ]; then
      stage=prepared_no_pr
    fi
  fi
fi
echo "STAGE: $stage"
