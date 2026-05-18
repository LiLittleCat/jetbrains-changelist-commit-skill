<div align="center">

# jetbrains-changelist-commit.skill

[![Agent Skill](https://img.shields.io/badge/Agent-Skill-7c3aed)](https://github.com/vercel-labs/skills)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>

An agent skill for safely creating focused commits from JetBrains IDE changelists without mixing unrelated local work.

It reads `.idea/workspace.xml`, resolves the selected changelist from JetBrains `ChangeListManager`, and commits only the selected paths through a temporary Git index. When the IDE records per-line changelist ownership through `LineStatusTrackerManager`, the skill can commit only the ranges that belong to the selected changelist, even when a single file contains changes from multiple changelists.

This is built for practical agent workflows: preventing Codex, Claude Code, and other skill-aware agents from accidentally including unrelated local changes in a commit, especially in repositories where changelists from IntelliJ IDEA, WebStorm, PyCharm, or Android Studio are the source of truth.


<div align="center">

[Install](#install) | [Usage](#usage) | [Behavior](#behavior) | [Layout](#layout) | [License](#license)

</div>

---

## Install

Pick one:

**A. With [`skills`](https://github.com/vercel-labs/skills):**

```bash
npx skills add LiLittleCat/jetbrains-changelist-commit-skill -g
```

The `-g` flag installs globally at user level.

**B. Or ask your AI coding agent:**

```text
Install the jetbrains-changelist-commit skill for this project:

1. Clone https://github.com/LiLittleCat/jetbrains-changelist-commit-skill into
   the project-level skills directory your agent reads.
2. Verify SKILL.md and scripts/ are present.
3. Confirm the install path.
```

## Usage

### Commit the current changelist

When your IDE changelist already contains the work you want to commit, ask your agent directly:

```text
commit
```

The agent reads `.idea/workspace.xml`, previews the selected changelist, and commits only that changelist.

### Commit a named changelist

When the commit should use a specific JetBrains IDE changelist, name it:

```text
commit the JIRA-1234 changelist
```

The name can be the changelist name or id from IDEA.

### Provide a commit message

You can provide the commit message up front:

```text
commit with message "fix: handle empty training sample"
```

When committing without an explicit message, the agent uses a supplied JetBrains changelist comment first, then matches recent repository history from `git log --oneline -20`. If there is no useful history, it falls back to a concise Conventional Commits message such as `feat(scope): summary` or `fix(scope): summary`.

## Behavior

The bundled runners:

- Read `.idea/workspace.xml`.
- Locate `ChangeListManager`.
- Select the default changelist or a named changelist via `--list`.
- Extract direct `<change>` entries from the selected list.
- Read `LineStatusTrackerManager` ranges for files split across changelists.
- Use both `afterPath` and `beforePath` so additions, edits, deletes, and renames are covered.
- Expand `$PROJECT_DIR$` to the Git repository root.
- Reject changelist paths outside the repository.
- Build the commit through a temporary Git index.
- For shared files, write a temporary blob made from `HEAD` plus the selected line ranges.
- Leave other changelist index entries untouched.

## Layout

```text
jetbrains-changelist-commit-skill/
├── SKILL.md
└── scripts/
    ├── commit_changelist.py
    ├── commit_changelist.ps1
    └── commit_changelist.sh
```

## License

MIT - see [LICENSE](LICENSE).
