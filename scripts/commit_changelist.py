#!/usr/bin/env python3
"""Commit only files from a JetBrains IDE changelist."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


def run_git(
    repo: Path,
    args: list[str],
    check: bool = True,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    if check and result.returncode != 0:
        if result.stdout:
            sys.stdout.write(result.stdout)
        if result.stderr:
            sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    return result


def has_head(repo: Path) -> bool:
    result = run_git(repo, ["rev-parse", "--verify", "--quiet", "HEAD"], check=False)
    return result.returncode == 0


def real_index_matches_worktree(repo: Path, paths: list[str]) -> bool:
    diff = run_git(repo, ["diff", "--quiet", "--", *paths], check=False)
    if diff.returncode not in (0, 1):
        raise SystemExit(diff.returncode)

    others = run_git(repo, ["ls-files", "--others", "--exclude-standard", "--", *paths], check=False)
    if others.returncode != 0:
        raise SystemExit(others.returncode)

    return diff.returncode == 0 and not others.stdout.strip()


def resolve_repo(start: Path) -> Path:
    result = subprocess.run(
        ["git", "-C", str(start), "rev-parse", "--show-toplevel"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr or f"Not a Git repository: {start}\n")
        raise SystemExit(result.returncode)
    return Path(result.stdout.strip()).resolve()


def parse_workspace(workspace: Path) -> ET.Element:
    if not workspace.exists():
        raise SystemExit(f"Missing JetBrains workspace file: {workspace}")
    try:
        return ET.parse(workspace).getroot()
    except ET.ParseError as exc:
        raise SystemExit(f"Failed to parse {workspace}: {exc}") from exc


def find_changelist(root: ET.Element, selector: str | None) -> ET.Element:
    component = root.find(".//component[@name='ChangeListManager']")
    if component is None:
        raise SystemExit("Missing ChangeListManager component in workspace.xml")

    lists = component.findall("list")
    if selector:
        for item in lists:
            if selector in {item.get("name"), item.get("id")}:
                return item
        names = ", ".join(filter(None, (item.get("name") for item in lists)))
        raise SystemExit(f"Changelist not found: {selector}. Available: {names}")

    for item in lists:
        if item.get("default") == "true":
            return item
    raise SystemExit("No default JetBrains changelist found")


def expand_project_path(raw: str, repo: Path) -> Path:
    marker = "$PROJECT_DIR$"
    if raw.startswith(marker):
        suffix = raw[len(marker) :].lstrip("/\\")
        return (repo / suffix).resolve()
    value = Path(raw)
    if value.is_absolute():
        return value.resolve()
    return (repo / value).resolve()


def pathspecs_for_changelist(changelist: ET.Element, repo: Path) -> list[str]:
    paths: list[str] = []
    seen: set[str] = set()

    for change in changelist.findall("change"):
        for attr in ("afterPath", "beforePath"):
            raw = change.get(attr)
            if not raw:
                continue
            absolute = expand_project_path(raw, repo)
            try:
                relative = absolute.relative_to(repo)
            except ValueError as exc:
                raise SystemExit(f"Changelist path is outside the repository: {absolute}") from exc
            pathspec = relative.as_posix()
            if pathspec not in seen:
                seen.add(pathspec)
                paths.append(pathspec)

    return paths


def print_selection(changelist: ET.Element, paths: list[str]) -> None:
    name = changelist.get("name") or ""
    list_id = changelist.get("id") or ""
    comment = changelist.get("comment") or ""
    print(f"Changelist: {name} ({list_id})")
    if comment:
        print(f"Comment: {comment}")
    print(f"Path count: {len(paths)}")
    for path in paths:
        print(path)


def print_status(repo: Path, paths: list[str]) -> None:
    if not paths:
        return
    result = run_git(repo, ["status", "--short", "--", *paths], check=False)
    if result.stdout.strip():
        print("\nGit status for selected paths:")
        sys.stdout.write(result.stdout)


def commit_paths(repo: Path, paths: list[str], messages: list[str], no_verify: bool) -> str:
    if not messages:
        raise SystemExit("Commit message is required. Pass -m/--message.")

    selected_paths_are_already_indexed = real_index_matches_worktree(repo, paths)

    with tempfile.TemporaryDirectory(prefix="jetbrains-changelist-index-") as temp_dir:
        index_path = str(Path(temp_dir) / "index")
        index_env = {"GIT_INDEX_FILE": index_path}

        if has_head(repo):
            run_git(repo, ["read-tree", "HEAD"], extra_env=index_env)
        else:
            run_git(repo, ["read-tree", "--empty"], extra_env=index_env)

        run_git(repo, ["add", "-A", "--", *paths], extra_env=index_env)

        diff = run_git(repo, ["diff", "--cached", "--quiet", "--", *paths], check=False, extra_env=index_env)
        if diff.returncode == 0:
            raise SystemExit("Selected changelist has no staged changes to commit")
        if diff.returncode not in (0, 1):
            raise SystemExit(diff.returncode)

        cmd = ["commit"]
        if no_verify:
            cmd.append("--no-verify")
        for message in messages:
            cmd.extend(["-m", message])
        result = run_git(repo, cmd, extra_env=index_env)
        sys.stdout.write(result.stdout)

    if not selected_paths_are_already_indexed:
        run_git(repo, ["add", "-A", "--", *paths])

    rev = run_git(repo, ["rev-parse", "--short", "HEAD"])
    return rev.stdout.strip()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Commit only files listed in a JetBrains changelist from .idea/workspace.xml."
    )
    parser.add_argument("--repo", default=".", help="Path inside the target Git repository.")
    parser.add_argument(
        "--workspace",
        help="Path to workspace.xml. Defaults to <repo>/.idea/workspace.xml.",
    )
    parser.add_argument(
        "--list",
        dest="changelist",
        help="JetBrains changelist name or id. Defaults to the list with default=true.",
    )
    parser.add_argument("-m", "--message", action="append", default=[], help="Commit message paragraph.")
    parser.add_argument("--dry-run", action="store_true", help="Print selected files and exit.")
    parser.add_argument("--no-verify", action="store_true", help="Pass --no-verify to git commit.")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    repo = resolve_repo(Path(args.repo).resolve())
    workspace = Path(args.workspace).resolve() if args.workspace else repo / ".idea" / "workspace.xml"

    root = parse_workspace(workspace)
    changelist = find_changelist(root, args.changelist)
    paths = pathspecs_for_changelist(changelist, repo)

    print_selection(changelist, paths)
    print_status(repo, paths)

    if args.dry_run:
        return 0
    if not paths:
        return 2

    commit = commit_paths(repo, paths, args.message, args.no_verify)
    print(f"\nCommitted: {commit}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
