---
name: jetbrains-changelist-commit
description: Use when creating a git commit in a JetBrains project (one containing .idea/workspace.xml), when the user asks to commit a specific or default ChangeListManager list, or when local uncommitted files from other changelists must stay out of the commit.
---

# JetBrains Changelist Commit

## Overview

AI coding agents commit too eagerly. A bare `git add .` or `git commit -a` sweeps in unrelated local work — debug prints, half-finished experiments, files belonging to a different task — anything the working tree happens to hold. JetBrains IDEs already solve this on the human side: developers carefully group commit-worthy files into named `ChangeListManager` lists in `.idea/workspace.xml`, and unrelated edits live in other lists.

This skill makes the agent trust that grouping. It reads the selected changelist, commits those paths through a temporary Git index, and honors IDEA's per-line ownership data when `LineStatusTrackerManager` records multiple changelists in the same file. The result: the agent commits exactly the selected changelist's files and line ranges.

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
2. Prefer the bundled PowerShell runner on Windows or the POSIX shell runner on Linux/macOS. Run it in dry-run mode to read `.idea/workspace.xml`, select the `<component name="ChangeListManager">` list with `default="true"` (or the named list), and print the paths plus any line ranges.
3. Review the printed paths against the user's intended commit scope.
4. Choose the commit message:
   - If the user supplied a message, use it exactly.
   - If the selected JetBrains changelist has a non-empty `comment`, use that comment.
   - Otherwise, inspect recent history with `git log --oneline -20` and match the repository's commit message style.
   - If there is no useful history, use a concise Conventional Commits message such as `feat(scope): summary`, `fix(scope): summary`, `feat: summary`, or `fix: summary`.
5. Run the same runner with the commit message to stage and commit only those paths.
6. Report the commit hash and the paths included.

## Commands

From any directory inside the repository, prefer the native runner for the platform.

Windows / PowerShell:

```powershell
pwsh -File <skill-dir>\scripts\commit_changelist.ps1 -DryRun
pwsh -File <skill-dir>\scripts\commit_changelist.ps1 -Message "feat: concise message"
```

If only Windows PowerShell 5.1 is available, substitute `powershell -ExecutionPolicy Bypass` for `pwsh`.

Linux or macOS / POSIX shell:

```bash
sh <skill-dir>/scripts/commit_changelist.sh --dry-run
sh <skill-dir>/scripts/commit_changelist.sh -m "feat: concise message"
```

Python is available as an additional runner:

```bash
python3 <skill-dir>/scripts/commit_changelist.py --dry-run
python3 <skill-dir>/scripts/commit_changelist.py -m "feat: concise message"
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

`scripts/commit_changelist.ps1`, `scripts/commit_changelist.sh`, and the optional fallback `scripts/commit_changelist.py`:

- Read `.idea/workspace.xml`.
- Extract direct `<change>` children from the selected changelist.
- Extract matching `LineStatusTrackerManager` ranges for selected files.
- Expand `$PROJECT_DIR$` to the Git repository root.
- Use both `afterPath` and `beforePath` so additions, edits, deletes, and renames are handled.
- Build the commit from a temporary Git index seeded from `HEAD`.
- Add selected changelist paths to the temporary index.
- For files split across changelists, write a blob made from `HEAD` plus only the selected line ranges.
- Update the real Git index only for selected paths that were not already indexed with their worktree content. Index entries for other changelists are never touched.

Side effect: if a selected path was partially staged (e.g. via `git add -p`) before running this skill, the real index for that path may be rewritten after the commit. For shared files with IDEA line ranges, the real index is updated to the committed selected-range blob and the remaining worktree edits stay visible.

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
