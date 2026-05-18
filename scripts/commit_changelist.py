#!/usr/bin/env python3
"""Commit only files from a JetBrains IDE changelist."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class LineRange:
    start1: int
    end1: int
    start2: int
    end2: int


@dataclass(frozen=True)
class IndexEntry:
    path: str
    mode: str
    oid: str


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


def run_git_bytes(
    repo: Path,
    args: list[str],
    check: bool = True,
    extra_env: dict[str, str] | None = None,
    input_data: bytes | None = None,
) -> subprocess.CompletedProcess[bytes]:
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        input=input_data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    if check and result.returncode != 0:
        if result.stdout:
            sys.stdout.buffer.write(result.stdout)
        if result.stderr:
            sys.stderr.buffer.write(result.stderr)
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


def to_repo_relative(absolute: Path, repo: Path) -> str:
    try:
        return absolute.relative_to(repo).as_posix()
    except ValueError:
        pass

    abs_str = os.fspath(absolute)
    repo_str = os.fspath(repo)
    abs_norm = os.path.normcase(abs_str)
    repo_norm = os.path.normcase(repo_str)
    if abs_norm == repo_norm:
        return ""
    prefix = repo_norm + os.sep
    if abs_norm.startswith(prefix):
        return Path(abs_str[len(repo_str) + 1:]).as_posix()
    raise SystemExit(f"Changelist path is outside the repository: {absolute}")


def pathspecs_for_changelist(changelist: ET.Element, repo: Path) -> list[str]:
    # Emit both afterPath and beforePath so `git add -A` sees deletion of the old
    # name and addition of the new name for renames, letting Git's rename
    # detection fire. Do not "clean up" by keeping only afterPath.
    paths: list[str] = []
    seen: set[str] = set()

    for change in changelist.findall("change"):
        for attr in ("afterPath", "beforePath"):
            raw = change.get(attr)
            if not raw:
                continue
            absolute = expand_project_path(raw, repo)
            pathspec = to_repo_relative(absolute, repo)
            if not pathspec:
                continue
            key = os.path.normcase(pathspec)
            if key not in seen:
                seen.add(key)
                paths.append(pathspec)

    return paths


def line_ranges_for_changelist(root: ET.Element, changelist: ET.Element, repo: Path) -> dict[str, list[LineRange]]:
    list_id = changelist.get("id")
    if not list_id:
        return {}

    component = root.find(".//component[@name='LineStatusTrackerManager']")
    if component is None:
        return {}

    result: dict[str, list[LineRange]] = {}
    for file_node in component.findall("file"):
        raw_path = file_node.get("path")
        if not raw_path:
            continue
        path = to_repo_relative(expand_project_path(raw_path, repo), repo)
        if not path:
            continue

        ranges: list[LineRange] = []
        for range_node in file_node.findall("./ranges/range"):
            if range_node.get("changelist") != list_id:
                continue
            try:
                line_range = LineRange(
                    start1=int(range_node.get("start1", "")),
                    end1=int(range_node.get("end1", "")),
                    start2=int(range_node.get("start2", "")),
                    end2=int(range_node.get("end2", "")),
                )
            except ValueError as exc:
                raise SystemExit(f"Invalid line range for {path}") from exc

            if (
                line_range.start1 < 0
                or line_range.end1 < line_range.start1
                or line_range.start2 < 0
                or line_range.end2 < line_range.start2
            ):
                raise SystemExit(f"Invalid line range bounds for {path}")
            ranges.append(line_range)

        if ranges:
            result[path] = sorted(ranges, key=lambda item: (item.start1, item.start2, item.end1, item.end2))

    return result


def print_selection(changelist: ET.Element, paths: list[str], partial_ranges: dict[str, list[LineRange]]) -> None:
    name = changelist.get("name") or ""
    list_id = changelist.get("id") or ""
    comment = changelist.get("comment") or ""
    print(f"Changelist: {name} ({list_id})")
    if comment:
        print(f"Comment: {comment}")
    print(f"Path count: {len(paths)}")
    for path in paths:
        print(path)
    if partial_ranges:
        print("\nLine ranges:")
        for path in paths:
            ranges = partial_ranges.get(path)
            if not ranges:
                continue
            print(path)
            for line_range in ranges:
                print(
                    f"  old {line_range.start1}:{line_range.end1} "
                    f"-> new {line_range.start2}:{line_range.end2}"
                )


def print_status(repo: Path, paths: list[str]) -> None:
    if not paths:
        return
    result = run_git(repo, ["status", "--short", "--", *paths], check=False)
    if result.stdout.strip():
        print("\nGit status for selected paths:")
        sys.stdout.write(result.stdout)


def blob_from_head(repo: Path, path: str) -> bytes:
    if not has_head(repo):
        return b""
    result = run_git_bytes(repo, ["show", f"HEAD:{path}"], check=False)
    if result.returncode == 0:
        return result.stdout
    return b""


def split_lines(data: bytes) -> list[bytes]:
    return data.splitlines(keepends=True)


def apply_line_ranges(base: bytes, worktree: bytes, ranges: list[LineRange], path: str) -> bytes:
    base_lines = split_lines(base)
    worktree_lines = split_lines(worktree)
    selected: list[bytes] = []
    cursor = 0

    for line_range in ranges:
        if line_range.start1 < cursor:
            raise SystemExit(f"Overlapping line ranges for {path}")
        if line_range.end1 > len(base_lines) or line_range.end2 > len(worktree_lines):
            raise SystemExit(f"Line range is outside file bounds for {path}")
        selected.extend(base_lines[cursor:line_range.start1])
        selected.extend(worktree_lines[line_range.start2:line_range.end2])
        cursor = line_range.end1

    selected.extend(base_lines[cursor:])
    return b"".join(selected)


def index_mode(repo: Path, path: str, extra_env: dict[str, str] | None) -> str:
    # Only called from build_partial_entries, i.e. files with IDEA line ranges.
    # LineStatusTrackerManager tracks per-line diffs, so the path is always a
    # text file — never a symlink (120000) or submodule (160000). The
    # exec-bit fallback is therefore sufficient.
    result = run_git(repo, ["ls-files", "-s", "--", path], check=False, extra_env=extra_env)
    if result.returncode != 0:
        raise SystemExit(result.returncode)
    if result.stdout.strip():
        return result.stdout.split(None, 1)[0]

    absolute = repo / path
    if absolute.exists() and os.access(absolute, os.X_OK):
        return "100755"
    return "100644"


def build_partial_entries(
    repo: Path,
    partial_ranges: dict[str, list[LineRange]],
    extra_env: dict[str, str],
) -> list[IndexEntry]:
    entries: list[IndexEntry] = []
    for path, ranges in partial_ranges.items():
        worktree_path = repo / path
        worktree = worktree_path.read_bytes() if worktree_path.exists() else b""
        content = apply_line_ranges(blob_from_head(repo, path), worktree, ranges, path)
        oid_result = run_git_bytes(
            repo,
            ["hash-object", "-w", f"--path={path}", "--stdin"],
            input_data=content,
        )
        oid = oid_result.stdout.decode("ascii").strip()
        entries.append(IndexEntry(path=path, mode=index_mode(repo, path, extra_env), oid=oid))
    return entries


def update_index_entries(
    repo: Path,
    entries: list[IndexEntry],
    extra_env: dict[str, str] | None = None,
) -> None:
    for entry in entries:
        run_git(
            repo,
            ["update-index", "--add", "--cacheinfo", entry.mode, entry.oid, entry.path],
            extra_env=extra_env,
        )


def commit_paths(
    repo: Path,
    paths: list[str],
    partial_ranges: dict[str, list[LineRange]],
    messages: list[str],
    no_verify: bool,
) -> str:
    if not messages:
        raise SystemExit("Commit message is required. Pass -m/--message.")

    partial_paths = set(partial_ranges)
    full_paths = [path for path in paths if path not in partial_paths]
    full_paths_are_already_indexed = not full_paths or real_index_matches_worktree(repo, full_paths)
    partial_entries: list[IndexEntry] = []

    with tempfile.TemporaryDirectory(prefix="jetbrains-changelist-index-") as temp_dir:
        index_path = str(Path(temp_dir) / "index")
        index_env = {"GIT_INDEX_FILE": index_path}

        if has_head(repo):
            run_git(repo, ["read-tree", "HEAD"], extra_env=index_env)
        else:
            run_git(repo, ["read-tree", "--empty"], extra_env=index_env)

        if full_paths:
            run_git(repo, ["add", "-A", "--", *full_paths], extra_env=index_env)
        if partial_ranges:
            partial_entries = build_partial_entries(repo, partial_ranges, index_env)
            update_index_entries(repo, partial_entries, index_env)

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

    # Re-align the real index with what we just committed. The commit itself
    # went through a temporary GIT_INDEX_FILE, so the real index is still in
    # its pre-commit shape. For paths that were partially staged before this
    # run, leaving the real index untouched would make `git status` show the
    # committed change as still pending. These two calls overwrite the real
    # index entries for selected paths only — other changelists' entries are
    # not touched. This is the documented side effect in SKILL.md.
    if full_paths and not full_paths_are_already_indexed:
        run_git(repo, ["add", "-A", "--", *full_paths])
    if partial_entries:
        update_index_entries(repo, partial_entries)

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
    partial_ranges = {
        path: ranges
        for path, ranges in line_ranges_for_changelist(root, changelist, repo).items()
        if path in paths
    }

    print_selection(changelist, paths, partial_ranges)
    print_status(repo, paths)

    if args.dry_run:
        return 0
    if not paths:
        name = changelist.get("name") or changelist.get("id") or "<unnamed>"
        sys.stderr.write(
            f"No files to commit from changelist '{name}'. Nothing was committed.\n"
        )
        return 2

    commit = commit_paths(repo, paths, partial_ranges, args.message, args.no_verify)
    print(f"\nCommitted: {commit}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
