---
description: >-
  Adds support for a new Redis command to the gem from a specification. Triggers on requests
  like "add support for the TS.BGET command" or via /add-new-command <COMMAND|path>. Resolves the
  spec from command_specs/, falling back to official redis.io docs. See .claude/skills/add-new-command/examples/command-specification-template.md.
argument-hint: "[command-name | path-to-spec]"
allowed-tools: Bash, Read, Write, Edit, WebFetch, Glob, Grep, AskUserQuestion
---

# Add new Redis command support

`$ARGUMENTS` is either a Redis command **name** (e.g. `TS.BGET`, `JSON.GET`) or a **path** to a
specification file. Before doing anything else, resolve it to a filled specification using Step 0.

## Step 0 — Resolve the specification

Run `bash .claude/skills/add-new-command/scripts/resolve_spec.sh "$ARGUMENTS"` from the repo root. Branch on its `RESOLUTION:` line.
Do not start Step 1 until you hold a filled spec.

- **`ready`** — filled spec is in the output. Go to Step 1.
- **`incomplete`** — spec exists but still has the `$COMMAND_NAME` placeholder. Ask the user to fill in the template, show the `RERUN_HINT` to resume, then STOP.
- **`missing`** — WebFetch `REDIS_IO_URL`.
  - Found → write a spec to `TARGET_SPEC_FILE` using `.claude/skills/add-new-command/examples/command-specification-template.md` structure, then use the **AskUserQuestion** tool to present a "Proceed / Stop" choice. On Proceed → go to Step 1; on Stop → end (the saved spec can be edited and re-run later).
  - Not found → ask the user to either give a spec path, or have you copy `.claude/skills/add-new-command/examples/command-specification-template.md` verbatim to `TARGET_SPEC_FILE` (keep the `$COMMAND_NAME` marker so the resolver flags it `incomplete` until filled) for them to fill; then show the `RERUN_HINT` and STOP.
- **`no_argument`** — ask for a command name or spec path, then STOP.

## Execution Instructions

### 1. Preparations

- Go through the guide `specs/adding-commands.md`

### 2. Read and Understand

- Read the ENTIRE specification carefully
- Go through Command Description and identify command type (string, list, set, etc.)
- Go through the Command API:
    - Identify required and optional arguments
    - Identify how to match Redis command arguments type to Ruby types
    - Identify return value and possible response types
- Check relevant Redis-Cli examples, if provided
- Review the Test Plan

### 3. Execute Tasks in Order

#### a. Navigate to the task
- Identify the files and action required
- Read existing related files if modifying

#### b. Implement the command
- Identify the command API surface object you need to work with.
- Identify required and optional arguments and their matching types.
- Add command implementation following `specs/adding-commands.md`
- Ensure doc string documents are added

#### c. Verify as you go
- After each file change, check syntax
- Ensure imports are correct
- Verify types are properly defined

### 4. Implement Testing Plan

After completing implementation tasks:

- Identify matching test file or create new one if needed
- Implement all test cases as separate test methods
- Ensure adding version constraint if specified in the specification
- Ensure tests cover edge cases

### 5. Run tests

- Run newly added test cases
- Get back to the Implementation stage if any test failed

### 6. Final Verification

Before completing:

- ✅ All tasks from plan completed
- ✅ All tests created and passing
- ✅ Code follows project conventions
- ✅ Documentation added/updated as needed

## Output Report

Provide summary:

### Specification Source
- How the spec was resolved (local file / built from redis.io / user-provided path)
- Path to the spec file used

### Completed Tasks
- List of all tasks completed
- Files created (with paths)
- Files modified (with paths)

### Tests Added
- Test files created
- Test cases implemented
- Test results
