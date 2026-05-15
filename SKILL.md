---
name: jetbrains-changelist-commit
description: Commit Git changes using JetBrains IDE changelist membership from .idea/workspace.xml. Use when Codex is asked to create a git commit in a JetBrains project, when the user wants commits limited to the active/default changelist, or when local uncommitted files should stay out of the commit unless they are listed under ChangeListManager.
---

# JetBrains Changelist Commit

## Workflow

Use this skill before creating a Git commit in a repository that has `.idea/workspace.xml` and JetBrains changelists.

1. Locate the repository root with `git rev-parse --show-toplevel`.
2. Run the bundled script in dry-run mode to read `.idea/workspace.xml`, select the `<component name="ChangeListManager">` list with `default="true"`, and print the paths in that changelist.
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

- Reads `.idea/workspace.xml`.
- Extracts direct `<change>` children from the selected changelist.
- Expands `$PROJECT_DIR$` to the Git repository root.
- Uses both `afterPath` and `beforePath` so additions, edits, deletes, and renames are handled.
- Runs `git add -A -- <paths>` for the selected paths.
- Runs `git commit --only -- <paths>` so the commit contains the selected changelist paths.
- Leaves existing staged entries for other paths in the index after the commit.

## Handling Empty Lists

When the default changelist has no `<change>` entries, run a dry-run with `--list <name-or-id>` only when the user intended a different changelist. If the intended changelist is empty, stop and report that there are no files to commit from that changelist.

## Verification

After a successful commit, verify the committed file list:

```bash
git show --name-only --pretty=format: <commit>
git status --porcelain=v1
```
