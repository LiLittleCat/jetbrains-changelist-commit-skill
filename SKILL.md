---
name: jetbrains-changelist-commit
description: Use when creating a git commit in a JetBrains project (one containing .idea/workspace.xml), when the user asks to commit a specific or default ChangeListManager list, or when local uncommitted files from other changelists must stay out of the commit.
---

# JetBrains Changelist Commit

## Overview

AI coding agents commit too eagerly. A bare `git add .` or `git commit -a` sweeps in unrelated local work — debug prints, half-finished experiments, files belonging to a different task — anything the working tree happens to hold. JetBrains IDEs already solve this on the human side: developers carefully group commit-worthy files into named `ChangeListManager` lists in `.idea/workspace.xml`, and unrelated edits live in other lists.

This skill makes the agent trust that grouping. It reads the selected changelist, commits only those paths through a temporary Git index, and leaves every other changelist's index entries untouched. The result: the agent commits exactly the files the developer staged in the IDE, and nothing else.

## When to Use

- The repository has `.idea/workspace.xml` with a `ChangeListManager` component.
- The user asks the agent to commit "the changelist", "the default changelist", or a named JetBrains changelist.
- Local uncommitted files exist that should NOT be in this commit (other changelists, scratch edits, debug code).

## When NOT to Use

- No `.idea/workspace.xml` (non-JetBrains project) — fall back to standard git workflow.
- The user explicitly wants `git add .` / commit-everything semantics.
- The intended commit scope is a path or glob the user named, not a changelist — use `git add <pathspec>` directly.

## Workflow

1. Locate the repository root with `git rev-parse --show-toplevel`.
2. Run the bundled script in dry-run mode to read `.idea/workspace.xml`, select the `<component name="ChangeListManager">` list with `default="true"` (or the named list), and print the paths.
3. Review the printed paths against the user's intended commit scope.
4. Run the same script with `-m "<commit message>"` to stage and commit only those paths.
5. Report the commit hash and the paths included.

## Commands

From any directory inside the repository:

```bash
python <skill-dir>/scripts/commit_changelist.py --dry-run
python <skill-dir>/scripts/commit_changelist.py -m "feat: concise message"
```

When Python is unavailable on Windows, use the PowerShell fallback:

```powershell
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\commit_changelist.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\commit_changelist.ps1 -Message "feat: concise message"
```

When Python is unavailable on Linux or macOS, use the POSIX shell fallback:

```bash
sh <skill-dir>/scripts/commit_changelist.sh --dry-run
sh <skill-dir>/scripts/commit_changelist.sh -m "feat: concise message"
```

Use `--repo <path>` when working outside the target repository.

Use `--list <name-or-id>` when the user names a specific JetBrains changelist. The default behavior uses the list marked `default="true"`.

PowerShell equivalents:

```powershell
-Repo <path>
-List <name-or-id>
```

Shell equivalents match the Python flags:

```bash
--repo <path>
--list <name-or-id>
```

## Script Behavior

`scripts/commit_changelist.py`, `scripts/commit_changelist.ps1`, and `scripts/commit_changelist.sh`:

- Read `.idea/workspace.xml`.
- Extract direct `<change>` children from the selected changelist.
- Expand `$PROJECT_DIR$` to the Git repository root.
- Use both `afterPath` and `beforePath` so additions, edits, deletes, and renames are handled.
- Build the commit from a temporary Git index seeded from `HEAD`.
- Add only the selected changelist paths to the temporary index.
- Update the real Git index only for selected paths that were not already indexed with their worktree content. Index entries for other changelists are never touched.

Side effect: if a selected path was partially staged (e.g. via `git add -p`) before running this skill, the real index for that path is replaced with the worktree content after the commit. The intermediate partial-staging state is lost, but no committed content is lost — the worktree state is what was just committed.

## Common Mistakes

- Skipping the dry-run step and committing the wrong scope.
- Passing the commit message to `--list` (it expects a changelist name or id, not a message).
- Running the skill in a repo without `.idea/workspace.xml` and expecting it to fall back to `git add .` — it will exit with an error instead.
- Assuming an empty default changelist means "commit everything". It means there is nothing to commit from that list; the skill exits with code 2 and prints an explanation to stderr.

## Handling Empty Lists

When the default changelist has no `<change>` entries, run a dry-run with `--list <name-or-id>` only when the user intended a different changelist. If the intended changelist is empty, stop and report that there are no files to commit from that changelist.

## Verification

After a successful commit, verify the committed file list:

```bash
git show --name-only --pretty=format: <commit>
git status --porcelain=v1
```
