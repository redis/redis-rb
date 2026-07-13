#!/usr/bin/env ruby
# frozen_string_literal: true

# Stop hook — breaking-change detection. Fires when the main agent finishes a
# turn. It does a CHEAP deterministic gate (is there a diff against master in
# the public-API paths?) and, if so, hands the work back to the main agent via
# decision:"block" so the agent dispatches a subagent to classify semver impact
# over the full diff. The expensive LLM reasoning lives in the subagent, not
# here — this script only decides *whether* to ask for it.
#
# Loop safety, two independent guards:
#   1. stop_hook_active == true  -> we're already continuing because of this
#      hook; exit 0 so we never re-trigger.
#   2. a digest of the public-API diff is cached in .claude/.breaking-state;
#      if it's unchanged since we last asked, exit 0. This stops us from
#      re-blocking on the same changes every single turn for the rest of the
#      branch's life.

require "json"
require "digest"
require "English"

# Pathspecs that bound the public-API surface (mirrors breaking_watch.rb).
PATHSPECS = [
  "lib/redis.rb",
  "lib/redis/commands",
  "lib/redis/distributed.rb",
  "cluster/lib",
  "*.gemspec"
].freeze

def sh(*args)
  out = IO.popen(args, err: File::NULL, &:read)
  $CHILD_STATUS.success? ? out : nil
end

begin
  payload = JSON.parse($stdin.read)
rescue StandardError
  payload = {}
end

# Guard 1: don't re-fire on the continuation we ourselves triggered.
exit 0 if payload["stop_hook_active"]

repo = `git rev-parse --show-toplevel 2>/dev/null`.strip
exit 0 if repo.empty?
Dir.chdir(repo)

# Need master to diff against; if it isn't present locally, stay silent.
exit 0 unless sh("git", "rev-parse", "--verify", "--quiet", "master")

# Committed changes on this branch (merge-base diff) + anything uncommitted,
# restricted to the public-API pathspecs.
committed = sh("git", "diff", "master...HEAD", "--", *PATHSPECS) || ""
working   = sh("git", "diff", "HEAD", "--", *PATHSPECS) || ""
diff = committed + working
exit 0 if diff.strip.empty?

# Guard 2: only ask once per distinct diff.
state_file = File.join(repo, ".claude", ".breaking-state")
digest = Digest::SHA256.hexdigest(diff)
prev = File.exist?(state_file) ? File.read(state_file).strip : nil
exit 0 if digest == prev
File.write(state_file, digest)

files = sh("git", "diff", "--name-only", "master...HEAD", "--", *PATHSPECS).to_s.split("\n")
files += sh("git", "diff", "--name-only", "HEAD", "--", *PATHSPECS).to_s.split("\n")
files = files.reject(&:empty?).uniq.sort

reason = <<~MSG
  Breaking-change watch: this branch changes redis-rb public-API files. Before
  finishing, assess whether a MAJOR version bump is warranted.

  Dispatch a subagent (Explore or general-purpose) to analyse the diff and
  classify the semver impact. Have it run:

      git diff master...HEAD -- #{PATHSPECS.join(' ')}
      git diff HEAD -- #{PATHSPECS.join(' ')}

  and judge against these breaking-change rules for the gem:
    - a public command/method removed or renamed (e.g. the recent ft.add /
      ft.mget / ft.del removal — that is MAJOR)
    - a method signature / arity / required-argument change
    - a changed return shape from a reply-reshaping lambda
    - a removed or relocated command category file
    - a raised required_ruby_version or a dropped/renamed runtime dependency

  Ask it to return a verdict (MAJOR / MINOR / PATCH) with the specific breaking
  changes listed, then relay that verdict to me. If nothing is breaking, say so.

  Changed public-API files:
  #{files.map { |f| "    - #{f}" }.join("\n")}
MSG

puts JSON.generate("decision" => "block", "reason" => reason)
exit 0
