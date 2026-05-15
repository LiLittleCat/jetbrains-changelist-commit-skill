# jetbrains-changelist-commit-skill

Standalone Codex skill repository for `jetbrains-changelist-commit`.

## Skill name

The repository name is `jetbrains-changelist-commit-skill`.
The Codex skill name remains `jetbrains-changelist-commit` in `SKILL.md`.

## What it does

This skill commits only the files listed in a JetBrains IDE changelist from `.idea/workspace.xml`.

It supports:

- the default JetBrains changelist
- a named changelist via `--list`
- Python, PowerShell, and POSIX shell runners
- additions, edits, deletes, and renames

## Usage

From any directory inside the target Git repository:

```bash
python <skill-dir>/scripts/commit_changelist.py --dry-run
python <skill-dir>/scripts/commit_changelist.py -m "feat: concise message"
```

PowerShell fallback:

```powershell
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\commit_changelist.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\commit_changelist.ps1 -Message "feat: concise message"
```

POSIX shell fallback:

```bash
sh <skill-dir>/scripts/commit_changelist.sh --dry-run
sh <skill-dir>/scripts/commit_changelist.sh -m "feat: concise message"
```

## Files

- `SKILL.md` - Codex skill definition and workflow
- `scripts/commit_changelist.py` - primary implementation
- `scripts/commit_changelist.ps1` - Windows PowerShell fallback
- `scripts/commit_changelist.sh` - POSIX shell fallback
- `agents/openai.yaml` - agent metadata
