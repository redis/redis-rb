#!/usr/bin/env bash
# Deterministic spec resolver for the add-new-command skill.
#
# Takes the raw skill argument (a Redis command name like "TS.BGET", or a path
# to a spec file) and decides — without any LLM reasoning — where the spec is,
# whether it is filled in or still a stub, and (when the user must act) how to
# resume. It prints a small structured report the skill body branches on.
#
# Run from the repo root. Usage:
#   bash .claude/skills/add-new-command/scripts/resolve_spec.sh "<command-name-or-path>"

set -euo pipefail

arg="${1:-}"
arg="$(printf '%s' "$arg" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

if [ -z "$arg" ]; then
  echo "RESOLUTION: no_argument"
  echo "Ask the user which Redis command to add (e.g. TS.BGET) or for a path to a spec file."
  exit 0
fi

emit_spec_block() {
  echo "--- BEGIN SPEC ---"
  cat "$1"
  echo ""
  echo "--- END SPEC ---"
}

# Classify a found spec file as ready or incomplete, then emit its report.
# A spec is still a stub if it carries the template's $COMMAND_NAME placeholder.
#   $1 = source label, $2 = spec file path, $3 = re-run token (command name or path)
handle_found() {
  local source="$1" file="$2" rerun="$3"
  if grep -qF -- '$COMMAND_NAME' "$file"; then
    echo "RESOLUTION: incomplete"
    echo "SPEC_FILE: $file"
    echo "RERUN_HINT: /add-new-command ${rerun}"
  else
    echo "RESOLUTION: ready"
    echo "SOURCE: $source"
    echo "SPEC_FILE: $file"
  fi
  emit_spec_block "$file"
}

# 1. Explicit path to an existing file.
if [ -f "$arg" ]; then
  handle_found "explicit_path" "$arg" "$arg"
  exit 0
fi

# 1b. Path-shaped argument (contains a slash or a .md suffix) that doesn't exist.
# Don't fall through to command-name handling — that would fabricate a bogus
# COMMAND / REDIS_IO_URL / TARGET_SPEC_FILE from the path string.
case "$arg" in
  */* | *.md)
    echo "RESOLUTION: path_not_found"
    echo "SPEC_FILE: $arg"
    echo "The argument looks like a spec file path, but no such file exists."
    echo "RERUN_HINT: /add-new-command ${arg}"
    exit 0
    ;;
esac

# 2. Treat as a command name. Uppercase + keep dots for the filename; lowercase for the URL.
name_upper="$(printf '%s' "$arg" | tr '[:lower:]' '[:upper:]')"
name_lower="$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]')"
spec_file="command_specs/${name_upper}-specification-template.md"

# 3. Local spec lookup (authoritative; also the resume path).
if [ -f "$spec_file" ]; then
  handle_found "local" "$spec_file" "$name_upper"
  exit 0
fi

# 4. No local spec — point at redis.io and where to save the spec.
echo "RESOLUTION: missing"
echo "COMMAND: ${name_upper}"
echo "REDIS_IO_URL: https://redis.io/docs/latest/commands/${name_lower}/"
echo "TARGET_SPEC_FILE: ${spec_file}"
echo "RERUN_HINT: /add-new-command ${name_upper}"
