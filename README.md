<div align="center">

# jetbrains-changelist-commit.skill

[![Agent Skill](https://img.shields.io/badge/Agent-Skill-7c3aed)](https://github.com/vercel-labs/skills)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

<br>

**An Agent Skill for committing JetBrains IDE changelists safely**. It reads `.idea/workspace.xml`, resolves the selected changelist from `ChangeListManager`, and commits only those paths through a temporary Git index, so one changelist can be committed without disturbing the Git index entries of the others.

The goal is practical: keep Codex, Claude Code, and other skill-aware agents from accidentally mixing unrelated local work into a commit, especially in repositories where IntelliJ IDEA, WebStorm, PyCharm, or Android Studio changelists are the source of truth.

<br>

**Install** - pick one:

</div>

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

<div align="center">

[Use cases](#use-cases) | [Behavior](#behavior) | [Usage](#usage) | [Layout](#layout) | [License](#license)

</div>

---

## Use cases

### Case 1 - Commit only the default changelist

You have multiple local changes, and IDEA already grouped the commit-worthy files into the default changelist.

```text
You    > Commit the default changelist.

Agent  > I will read .idea/workspace.xml, use the default ChangeListManager
         list, dry-run the selected paths, then commit only those paths with
         the bundled script.
```

The script selects the `<list default="true">` entry, expands `$PROJECT_DIR$`, and commits the listed files.

### Case 2 - Commit a named changelist

You moved a focused change into a named JetBrains changelist such as `JIRA-1234`.

```text
You    > Commit the changelist named JIRA-1234.

Agent  > I will select the matching ChangeListManager list, show the paths,
         and commit only that changelist.
```

The same `--list` selector accepts a changelist name or id.

### Case 3 - Preserve other staged changelists

Other changelists may already have staged additions, deletes, renames, or partially staged content. The script builds the commit with a temporary index seeded from `HEAD`, adds the selected changelist paths to that temporary index, and creates the commit from there.

That keeps unrelated changelist entries in the real `.git/index` stable, which helps JetBrains IDEs preserve their changelist state.

## Behavior

The bundled runners:

- Read `.idea/workspace.xml`.
- Locate `ChangeListManager`.
- Select the default changelist or a named changelist via `--list`.
- Extract direct `<change>` entries from the selected list.
- Use both `afterPath` and `beforePath` so additions, edits, deletes, and renames are covered.
- Expand `$PROJECT_DIR$` to the Git repository root.
- Reject changelist paths outside the repository.
- Build the commit through a temporary Git index.
- Leave other changelist index entries untouched.

## Usage

Ask your agent to commit a changelist. The skill tells the agent how to inspect `.idea/workspace.xml`, pick the intended changelist, preview the selected files, and create a scoped commit.

```text
Commit the default changelist with message "fix: handle empty training sample".
```

```text
Commit the changelist named JIRA-1234 with message "feat: add retry policy".
```

```text
Dry-run the default changelist and show me the files that would be committed.
```

The agent uses the bundled scripts behind the scenes, then reports the commit hash and included paths.

## Internals

The skill bundles three runner scripts so agents can use the best available runtime:

```text
scripts/commit_changelist.py
scripts/commit_changelist.ps1
scripts/commit_changelist.sh
```

## Layout

```text
jetbrains-changelist-commit-skill/
├── SKILL.md
├── README.md
├── LICENSE
└── scripts/
    ├── commit_changelist.py
    ├── commit_changelist.ps1
    └── commit_changelist.sh
```

## License

MIT - see [LICENSE](LICENSE).
