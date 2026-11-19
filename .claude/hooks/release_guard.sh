#!/usr/bin/env bash
# PreToolUse guard for Bash: refuses the commands that publish a redis-rb release.
#
# Blocked, regardless of who runs the session or which skill asked for it:
#   git tag <anything that creates/deletes>     (listing: git tag, git tag -l/--list/-n is fine)
#   git push --tags | --follow-tags | --mirror | refs/tags/... | v1.2.3-style tag refspec
#   git update-ref refs/tags/...
#   gem push, rake release (incl. bundle exec rake release)
#   gh release create|new without --draft, gh release edit, gh release delete
#   gh api ... repos/*/releases with a writing method (POST/PATCH/PUT/DELETE or -f/-F fields)
#
# Releases are published by a maintainer pressing "Publish release" on a DRAFT in GitHub, and
# gems are pushed by hand from a terminal — never from inside a Claude session.
#
# Reads the hook JSON on stdin and prints a permission decision on stdout. Exit 0 always; a
# refusal is expressed in the JSON (hookSpecificOutput.permissionDecision = "deny").

exec ruby -rjson -rshellwords -e '
  input = JSON.parse(STDIN.read) rescue {}
  cmd = input.dig("tool_input", "command").to_s

  # Split on shell separators so each simple command is judged on its own; strip wrappers.
  parts = cmd.split(/(?:&&|\|\||;|\||\n)/).map(&:strip)
  parts = parts.map { |p| p.sub(/\A(?:sudo\s+|env\s+(?:\S+=\S+\s+)*|bundle\s+exec\s+|bundler\s+exec\s+)+/, "") }

  # `git tag` with no args, or with a listing flag and no creation/deletion flag, only reads.
  listing_only = ->(args) {
    args.empty? ||
      (args.any? { |a| a =~ /\A(-l|--list|-n\d*|--contains|--no-contains|--points-at|--merged|--no-merged)\z/ } &&
       args.none? { |a| a =~ /\A(-a|-s|-u|-m|-F|-d|-f|--annotate|--sign|--local-user.*|--message.*|--file.*|--delete|--force|--edit)\z/ })
  }

  # Attached option values ("--method=POST", "-XPOST", "-fdraft=false", "--input=f") are
  # split into separate words so the checks below see the same shape as the spaced forms.
  normalize = ->(words) {
    words.flat_map { |w|
      case w
      when /\A(--[a-z][a-z-]*)=(.*)\z/m then [$1, $2]
      when /\A(-[XfFHq])(.+)\z/m        then [$1, $2]
      else [w]
      end
    }
  }

  # Tokenize like the shell does, so `--method "DELETE"` and `--method=DELETE` look the same as
  # the bare word; unbalanced quotes fall back to a whitespace split rather than allowing the call.
  shell_words = ->(str) {
    begin
      Shellwords.split(str)
    rescue ArgumentError
      str.split(/\s+/)
    end
  }

  reason = nil
  parts.each do |p|
    words = normalize.(shell_words.(p))
    next if words.empty?
    case words
    in ["git", *git_args] if git_args.first == "tag"
      args = git_args.drop(1)
      reason ||= "creating or deleting tags is refused: `#{p}`. Tags are created by GitHub when a maintainer publishes the draft release." unless listing_only.(args)
    in ["git", *git_args] if git_args.first == "push"
      args = git_args.drop(1)
      if args.any? { |a| a =~ /\A(--tags|--follow-tags|--mirror|tag)\z/ || a.include?("refs/tags/") || a =~ /\A\+?v?\d+\.\d+\.\d+(:.*)?\z/ }
        reason ||= "pushing tags is refused: `#{p}`."
      end
    in ["git", "update-ref", *ur] if ur.any? { |a| a.start_with?("refs/tags/") }
      reason ||= "writing tag refs is refused: `#{p}`."
    in ["gem", "push", *]
      reason ||= "`gem push` is refused inside a Claude session; the maintainer pushes gems by hand after the release is published."
    in ["rake", /\Arelease(:|\z)/, *]
      reason ||= "`rake release` tags, pushes and publishes; refused. Use the prepare-release skill flow instead."
    in ["gh", "release", ("create" | "new"), *rest]
      # "new" is the documented gh alias for "create". (No apostrophes here: this is inside a
      # single-quoted shell string.)
      # "--draft=false" normalizes to ["--draft", "false"]; only a bare flag or an explicit true counts.
      draft = rest.each_with_index.any? { |a, i| (a == "--draft" || a == "-d") && rest[i + 1] != "false" }
      reason ||= "`gh release create` without --draft would publish a release and create its tag; add --draft." unless draft
    in ["gh", "release", ("edit" | "delete" | "delete-asset"), *]
      reason ||= "`gh release #{words[2]}` is refused; publishing or removing a release is a maintainer action in the GitHub UI."
    in ["gh", "api", *api]
      path = api.find { |a| a =~ %r{repos/[^/]+/[^/]+/releases} }
      method_write = api.each_with_index.any? { |a, i| a =~ /\A(-X|--method)\z/ && api[i + 1].to_s =~ /\A(POST|PATCH|PUT|DELETE)\z/i }
      writing = method_write || api.any? { |a| a =~ /\A(-f|-F|--field|--raw-field|--input)\z/ }
      reason ||= "writing to the releases API is refused: `#{p}`." if path && writing
    else
      nil
    end
  end

  if reason
    puts JSON.generate({
      "hookSpecificOutput" => {
        "hookEventName" => "PreToolUse",
        "permissionDecision" => "deny",
        "permissionDecisionReason" => "release guard (.claude/hooks/release_guard.sh): #{reason}"
      }
    })
  end
'
