---
name: prepare-release
description: >-
  Prepares a redis / redis-clustering gem release end to end with a human at every irreversible
  step: release branch, breaking-change audit, CHANGELOG, version metadata, pinned driver
  bumps, the release PR, the DRAFT GitHub release, gem publishing instructions and a post-publish
  smoke test. Triggers on "prepare release of version x.y.z", "release 6.1.0", "continue the 6.1.0
  release", "smoke test 6.1.0", or /prepare-release x.y.z. Safe for non-maintainers: it then only
  edits local files.
argument-hint: "[x.y.z] [--smoke]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, WebFetch, AskUserQuestion
---

# Prepare a redis-rb release

`$ARGUMENTS` is the version to release (`6.1.0`) and optionally `--smoke` to jump to the smoke
test. The process is resumable: every run starts with the preflight, which reports the stage the
release is at, and you continue from there.

## Hard rules (apply in every mode, no exceptions)

1. **Never create or push a tag.** No `git tag`, no `git push --tags`, no `rake release`. The tag
   is created by GitHub when a maintainer publishes the draft release.
2. **Never publish a release.** `gh release create` is only ever run with `--draft`; never run
   `gh release edit --draft=false` or `gh release create` without `--draft`.
3. **Never build or push a gem.** No `gem build`, `gem push`, `rake build`. Those are printed as
   instructions for the maintainer to run by hand (Step 8).
4. **Only `MODE: live` may touch GitHub or `origin`.** In `MODE: dry-run` (the caller has no push
   access — admin, maintain or write — on the canonical repository, that could not be verified, or
   `origin` is not the canonical repository) do everything locally and stop before Step 6 with a summary; never
   `git push`, `gh pr create`, `gh release create`. Pass `--repo <GH_REPO>` to every `gh`
   command that creates something, so a fork can never be the accidental target.
5. **Never `git push --force`**, never rewrite history on `master` or a release branch.
6. Make file changes with the Edit/Write tools, not shell edits. The scripts only *read*, except
   `validate_metadata.sh`, which refreshes the two lockfiles via `bundle lock`.
7. Stop and report when anything below says STOP. Do not improvise around a failed check.

Rules 1–3 are also enforced mechanically: the project's PreToolUse hook
(`.claude/hooks/release_guard.sh`, wired in `.claude/settings.json`) refuses tag creation, tag
pushes, `gem push`, `rake release`, `gh release edit/delete`, non-draft `gh release create` and
writes to the releases API for every Bash call in this repository. If it refuses something, that
is the process working: report it, do not look for another way to run the command.

## Step 0 — Preflight

Run `bash .claude/skills/prepare-release/scripts/preflight.sh "<version>"` from the repo root.

- `RESOLUTION: no_version` / `bad_version` → ask for a valid `x.y.z` and STOP.
- `GH:` not `ok` → say so. Remote steps are impossible; continue in dry-run only if the caller
  wants the local preparation. If `gh` fails with a TLS/certificate error, the sandbox is
  intercepting it: tell the user to run the skill outside the sandbox.
- `WORKTREE: dirty` → ask the user to commit or stash their tracked changes first, then STOP.
- `TAG_EXISTS: yes` → this version is already released. Only the smoke test (Step 9) applies.
- Branch on `STAGE:`:
  - `start` → Step 1.
  - `prepared_no_pr` → `origin/<BRANCH>` already carries the version bump. First get onto that
    branch exactly as Step 1 does: `git switch <BRANCH>` (or
    `git switch -c <BRANCH> origin/<BRANCH>`), `git merge --ff-only origin/<BRANCH>`, and confirm
    `git rev-parse --abbrev-ref HEAD` prints `<BRANCH>`. Only then re-run Steps 3–5 as checks and
    continue with Step 6. Never edit or commit while `CURRENT_BRANCH` is anything else.
  - `pr_open` → report the PR URL, say the next step is review + merge by a maintainer, STOP.
  - `pr_closed` → the release PR was closed without merging; ask how to proceed, STOP.
  - `pr_merged` → Step 7.
  - `draft_ready` → print the draft URL and Step 8's instructions, STOP.
  - `released` → Step 9 if `--smoke` or the user asks; otherwise say the release is finished.

Note `KIND`, `BRANCH`, `TAG`, `PREV_TAG`, `MODE`, `ROLE`. In every later message, state the mode
once ("live, acting as maintainer <login>" or "dry-run: local changes only").

## Step 1 — Release branch

Branch name is `BRANCH` (`6.1` for 6.1.0 / 6.1.3; `7.0` for 7.0.0).

- **major / minor**: if `BRANCH_REMOTE: missing`, create it from `origin/master`:
  `git switch -c <BRANCH> origin/master`. If it exists, `git switch <BRANCH>` (or
  `git switch -c <BRANCH> origin/<BRANCH>`) and bring it up to date with
  `git merge --no-edit origin/master`. Resolve nothing automatically: on conflicts run
  `git merge --abort`, report the conflicting files and STOP.
- **patch**: the `x.y` branch must already exist; `BRANCH_REMOTE: missing` → STOP and ask which
  branch the patch should come from. Otherwise switch to it first, exactly as the minor path
  does: `git switch <BRANCH>` (or `git switch -c <BRANCH> origin/<BRANCH>` when
  `BRANCH_LOCAL: missing`), then `git merge --ff-only origin/<BRANCH>` so the local branch is at
  the remote head. Only then, if `MASTER_AHEAD_OF_BRANCH` is non-zero, list those commits
  (`git log --oneline origin/<BRANCH>..origin/master`) and use **AskUserQuestion**: merge all of
  master into the branch (the documented default), cherry-pick selected commits, or leave the
  branch as is. Do what they choose; never decide this yourself, since a patch branch may
  intentionally exclude the next minor's work. Every later step runs on `<BRANCH>`; confirm with
  `git rev-parse --abbrev-ref HEAD` before Step 3.

In dry-run mode do the same with local branches only.

## Step 2 — Breaking-change audit

Run `bash .claude/skills/prepare-release/scripts/changelog_gaps.sh "<PREV_TAG>" HEAD`. The
default label pattern is `/break/i` (matches `breaking-change`, `breaking change`, `Breaking`);
pass a third argument if the repository uses another label.

- `KIND: minor` or `patch` and `BREAKING_PRS` not `none` → list each PR with its title and use
  **AskUserQuestion** with: release as a major instead (restart at Step 0 with `(X+1).0.0`),
  continue as planned and document them under `## Breaking changes`, or stop. STOP on anything
  but "continue".
- `KIND: major` → breaking PRs are expected; make sure each gets a `## Breaking changes` entry.
- `BREAKING_SCAN: unavailable` or `incomplete` → `BREAKING_PRS: none` is not a result then. Read
  the commit list (all of it when unavailable, the listed PRs when incomplete) for signs of
  breaking changes (removed/renamed public methods, changed return shapes, raised minimum
  Ruby/Redis) and say explicitly which PRs the label scan could not check. Only
  `BREAKING_SCAN: complete` with `BREAKING_PRS: none` means the audit passed on labels alone.

Keep the script output: Step 3 uses the same commit list.

## Step 3 — CHANGELOG.md and cluster/CHANGELOG.md

Goal: the `# <version>` section lists every user-visible change since `PREV_TAG`, one bullet per
PR, nothing else.

1. Work from `MISSING_IN_CHANGELOG` plus the existing `# Unreleased` section. For every PR not
   yet covered, read the diff of its commit (`git show --stat <sha>`, then the `lib/` and
   `cluster/lib/` changes) to learn the public method names, keyword arguments, the Redis server
   version that introduced the command, and whether `Redis::Distributed` / `Redis::Cluster`
   support it or raise. Do not rely on the PR title alone.
2. Rename `# Unreleased` to `# <version>` (create the heading if absent). Sections, in this
   order and only when non-empty: `## Breaking changes`, `## New features`, `## Experimental`,
   `## Bug fixes`, `## Maintenance`.
3. **Entry style — essential information only.** Each bullet says what a user can now do or what
   now behaves differently, in one to three lines, wrapped at ~100 columns, ending with
   `(#PR)`. Include: method names in backticks, new keyword arguments, the Redis version in
   parentheses, `Redis::Distributed`/`Redis::Cluster` support or `NotImplementedError`, and a
   README section name when one exists. Exclude: why it was done, how it was implemented,
   history of earlier attempts, benchmark numbers, test details, internal class names that are
   not public API. Commit messages and PR bodies are sources, not text to paste.
4. Entries that touch the cluster gem's own behaviour (routing, fan-out, per-node semantics,
   `redis-cluster-client` pin) also go in `cluster/CHANGELOG.md` under the same `# <version>`
   heading; inherited commands do not.
5. Drift check: the script's "Changelog edits already made in this range" list shows commits
   that edited the changelogs after `PREV_TAG`. If any added bullets under an **already
   released** heading (compare `git show PREV_TAG:CHANGELOG.md` with the current file), move
   them into `# <version>` and tell the user you did.
6. Re-run `changelog_gaps.sh` until `MISSING_IN_CHANGELOG: none` (PRs that are pure
   CI/test/doc churn may be skipped — say which, and why).

## Step 4 — Version metadata

1. Edit `lib/redis/version.rb` to `VERSION = '<version>'`. That is the single source: both
   gemspecs and `cluster/lib/redis/cluster/version.rb` read it.
2. Run `bash .claude/skills/prepare-release/scripts/validate_metadata.sh <version>`. It refreshes
   `Gemfile.lock` and `cluster/Gemfile.lock` and prints `CHECK …: ok|FAIL` for the version, the
   lockfiles, both gemspecs loading with the right version and files, the changelog headings and
   the exact dependency pins. Fix every FAIL and re-run until `METADATA: ok`. Do not build a gem.

## Step 5 — Pinned driver dependencies

`redis-client` (redis.gemspec), `redis-cluster-client` (cluster/redis-clustering.gemspec) and
the dev dependency `hiredis-client` are pinned to exact versions because they are pre-1.0 and
ship behaviour changes in patch releases.

1. Run `bash .claude/skills/prepare-release/scripts/check_deps.sh`.
2. For each gem with `NEWER_VERSIONS`, read what changed between the current pin and the latest
   (WebFetch the `CHANGELOG_*` URL; for redis-cluster-client use the `gh api …/compare` command
   printed) and classify: **security fix**, **bug fix / additive**, or **breaking** (removed or
   renamed APIs redis-rb subclasses or calls, changed `connection_prelude`, changed error
   classes, changed routing semantics — see AGENTS.md "Client identification" and "Command
   routings" for the coupling points). Also confirm the new redis-cluster-client still accepts
   the chosen redis-client (`Runtime deps` line).
3. Decide: a newer version that is non-breaking, or that fixes an advisory, is adopted. A
   breaking one is reported with the specific incompatibility and left alone (open a follow-up,
   do not block the release). If `Advisories affecting …` lists anything unpatched by any
   version, tell the user plainly; the release decision is theirs.
4. To adopt: edit the pin in the gemspec(s) (and the explanatory comment above it if it names
   versions), then `bundle lock --update redis-client hiredis-client && bundle install` and
   `BUNDLE_GEMFILE=cluster/Gemfile bundle lock --update redis-client hiredis-client
   redis-cluster-client && BUNDLE_GEMFILE=cluster/Gemfile bundle install` (the lock alone does
   not install the gem, and the suite then fails with `Bundler::GemNotFound`). Re-audit the
   coupling points named in AGENTS.md for every bump. Add a `## Maintenance` bullet
   (`Pin redis-client to 0.32.0.`) to CHANGELOG.md, and to cluster/CHANGELOG.md for
   redis-cluster-client. Re-run `validate_metadata.sh`. A test that asserted the old driver's
   behaviour (a rejected subcommand, a `CROSSSLOT` error) and now fails is part of the bump:
   update it to the new behaviour and say so in the PR; any other failure means revert.
5. Run the suite locally when Docker is available: `make start_all`, then
   `bundle exec rake test:redis test:distributed test:sentinel` and
   `BUNDLE_GEMFILE=cluster/Gemfile bundle exec rake test:cluster`, then `make stop_all`. Report
   failures verbatim; a failing suite after a bump means revert the bump and report, not patch
   around it. CI on the PR is the authoritative run either way.

## Step 6 — Release PR (live mode only)

Dry-run: stop here. Summarise the local changes (`git status`, `git diff --stat`) and explain that
a maintainer has to push the branch and open the PR; do not push.

Live:

1. `git add CHANGELOG.md cluster/CHANGELOG.md lib/redis/version.rb redis.gemspec
   cluster/redis-clustering.gemspec` plus any test or source file a dependency bump required
   (only these; show `git status` first and ask if anything else is modified). `Gemfile.lock`
   and `cluster/Gemfile.lock` are gitignored here; `validate_metadata.sh` refreshes them for the
   local run only.
2. Commit as `Prepare <version> release` with the attribution trailer the session requires.
3. `git push -u origin <BRANCH>`.
4. `gh pr create --base master --head <BRANCH> --title "Release <version>" --body-file <file>`
   where the body has: the release kind and headline items, the dependency bumps with a one-line
   justification each (or "no bumps: current pins are latest"), the breaking-change audit result,
   and a checklist for the reviewer (CHANGELOG complete, version bumped, CI green). End the body
   with the attribution line the session requires.
5. Report the PR URL and STOP. Merging is the maintainer's decision; the skill never merges.

## Step 7 — Release notes and DRAFT release (after the PR is merged, live mode only)

Preflight reports `STAGE: pr_merged`.

1. Preflight prints `PR_HEAD_COMMIT`, the reviewed commit (the release branch head at merge
   time), and `PR_MERGE_COMMIT`, the commit the PR produced on `master`. **The release is
   `PR_HEAD_COMMIT`.** Master may hold more than the release: a patch branch deliberately
   excludes the next minor's work (Step 1), and master may have moved on since the review, so
   the merge commit is only proof that master received the release, never the release itself.
   The branch may have been deleted on merge, so fetch the PR ref instead of relying on
   `origin/<BRANCH>`:
   ```sh
   git fetch origin master "refs/pull/<PR_NUMBER>/head"
   git show <PR_HEAD_COMMIT>:lib/redis/version.rb | grep -F "'<version>'"
   git show <PR_HEAD_COMMIT>:CHANGELOG.md | grep -Fx '# <version>'
   git merge-base --is-ancestor <PR_MERGE_COMMIT> origin/master   # master really received it
   git diff --stat <PR_HEAD_COMMIT> <PR_MERGE_COMMIT> -- CHANGELOG.md cluster/CHANGELOG.md \
     lib/redis/version.rb redis.gemspec cluster/redis-clustering.gemspec   # must print nothing
   ```
   Any of these failing → STOP and report which: the version or changelog is not what was
   reviewed, or master ended up with different release metadata (a conflict resolution or a
   partial merge).
2. Write `RELEASE_NOTES-<version>.md` in the repo root from the `# <version>` sections of both
   changelogs, following `.claude/skills/prepare-release/examples/release-notes-template.md`.
   Same content rule as Step 3: what changed, for whom, which Redis version; no reasoning. The
   file is a GitHub release body, not a changelog: no `# title` line, `###` section headings
   with the template's emojis, and every paragraph and bullet on a single unwrapped line
   (GitHub turns the newlines of a hard-wrapped body into line breaks). Do not commit this file.
3. Create the draft, targeting the release branch `<BRANCH>` (never `master`), which must be at
   the reviewed commit so the tag points at exactly the content that was reviewed, and nothing
   master added before or after. `git ls-remote --heads origin <BRANCH>` must print
   `PR_HEAD_COMMIT`: a different commit → STOP and report it; no output (the branch was deleted
   on merge) → STOP and ask the maintainer to restore it with
   `git push origin <PR_HEAD_COMMIT>:refs/heads/<BRANCH>` (reachable through
   `refs/pull/<PR_NUMBER>/head`), then continue. The title is the bare version, without `v`:
   ```sh
   gh release create v<version> --draft --target <BRANCH> \
     --title "<version>" --notes-file RELEASE_NOTES-<version>.md
   ```
   `--draft` is mandatory. A draft creates no tag; GitHub creates `v<version>` at the head of
   `<BRANCH>` only when a maintainer presses **Publish release**, so nothing may be pushed to
   `<BRANCH>` between the draft and publishing.
4. Report the draft URL and print Step 8 verbatim. STOP. If `gh release create` is unavailable,
   leave the `.md` file, say so, and print Step 8.

## Step 8 — Publishing the gems (maintainer runs these by hand)

Print this block, with the version filled in, after Step 7 and whenever `STAGE` is
`draft_ready` or `released`:

```sh
# 1. Publish the draft release on GitHub (Releases → v<version> → Publish). This creates the tag.
# 2. Build and push from the tagged commit, main gem first (redis-clustering depends on it):
git fetch --tags origin && git checkout v<version>
gem build redis.gemspec && gem push redis-<version>.gem
cd cluster && gem build redis-clustering.gemspec && gem push redis-clustering-<version>.gem && cd ..
# 3. Then ask for the smoke test:  /prepare-release <version> --smoke
```

Never run these yourself.

## Step 9 — Smoke test (on request, after the gems are published)

Needs a Redis to talk to: `docker compose --profile standalone up -d --wait` (port 6381), add
`--profile cluster` for the cluster gem (port 16380). Then:

```sh
bash .claude/skills/prepare-release/scripts/smoke_test.sh <version>            # redis
bash .claude/skills/prepare-release/scripts/smoke_test.sh <version> --cluster  # + redis-clustering
```

It installs the gems from RubyGems into a throwaway `GEM_HOME` (retrying while the index
catches up), checks `Redis::VERSION`, and runs SET/GET/DEL. `SMOKE: all ok` ends the release;
report any FAIL line verbatim together with the server version it printed.

## Reporting

Every message states the mode, the stage reached, what was changed (files, commits, URLs), and
exactly which human action comes next. Never claim a step ran if its check did not print `ok`.
