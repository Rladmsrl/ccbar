from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass
from pathlib import Path


SEMVER_TAG_RE = re.compile(r"^v\d+\.\d+\.\d+$")
CONVENTIONAL_RE = re.compile(r"^(?P<type>[A-Za-z]+)(?:\([^)]+\))?!?:\s*(?P<summary>.+)$")
RELEASE_BUMP_RE = re.compile(r"^chore\(release\)!?:\s*v\d+\.\d+\.\d+(?:\s+\[skip ci\])?$", re.IGNORECASE)
LIST_ITEM_RE = re.compile(r"^\s*(?:[-*+]|\d+[.)、])\s+(?P<text>.+)$")
HEADING_ONLY_RE = re.compile(r"^(?:详细变更|变更|changes?)\s*[:：]$", re.IGNORECASE)
TRAILER_RE = re.compile(r"^(?:Signed-off-by|Co-authored-by|Reviewed-by):\s", re.IGNORECASE)

GROUP_ORDER = ["新功能", "修复", "性能", "改进", "工程与发布", "其他"]
TYPE_TO_GROUP = {
    "feat": "新功能",
    "fix": "修复",
    "perf": "性能",
    "refactor": "改进",
    "docs": "改进",
    "style": "改进",
    "build": "工程与发布",
    "ci": "工程与发布",
    "chore": "工程与发布",
    "test": "工程与发布",
}


@dataclass(frozen=True)
class CommitNote:
    sha: str
    subject: str
    commit_type: str | None
    group: str
    items: tuple[str, ...]


def run_git(repo: Path, args: list[str]) -> str:
    return subprocess.check_output(["git", *args], cwd=repo, text=True)


def semver_key(tag: str) -> tuple[int, int, int]:
    version = tag[1:] if tag.startswith("v") else tag
    major, minor, patch = version.split(".")
    return int(major), int(minor), int(patch)


def semver_tags(repo: Path) -> list[str]:
    raw_tags = run_git(repo, ["tag", "--list", "v*.*.*"])
    tags = [tag.strip() for tag in raw_tags.splitlines() if SEMVER_TAG_RE.match(tag.strip())]
    return sorted(tags, key=semver_key)


def tag_exists(repo: Path, tag: str) -> bool:
    try:
        run_git(repo, ["rev-parse", "--verify", "--quiet", f"refs/tags/{tag}"])
        return True
    except subprocess.CalledProcessError:
        return False


def find_previous_tag(repo: Path, current_tag: str) -> str | None:
    if not SEMVER_TAG_RE.match(current_tag):
        return None
    current_key = semver_key(current_tag)
    candidates = [tag for tag in semver_tags(repo) if semver_key(tag) < current_key]
    return candidates[-1] if candidates else None


def release_range(current_ref: str, previous_ref: str | None) -> str:
    if previous_ref:
        return f"{previous_ref}..{current_ref}"
    return current_ref


def parse_type_and_summary(subject: str) -> tuple[str | None, str]:
    match = CONVENTIONAL_RE.match(subject.strip())
    if not match:
        return None, subject.strip()
    return match.group("type").lower(), match.group("summary").strip()


def group_for_type(commit_type: str | None) -> str:
    if commit_type is None:
        return "其他"
    return TYPE_TO_GROUP.get(commit_type, "其他")


def group_for_subject(subject: str) -> str:
    commit_type, _ = parse_type_and_summary(subject)
    return group_for_type(commit_type)


def clean_body_items(body: str) -> list[str]:
    items: list[str] = []
    paragraph: list[str] = []

    def flush_paragraph() -> None:
        nonlocal paragraph
        if paragraph:
            items.append(" ".join(paragraph).strip())
            paragraph = []

    for raw_line in body.splitlines():
        line = raw_line.strip()
        if not line:
            flush_paragraph()
            continue
        if HEADING_ONLY_RE.match(line) or TRAILER_RE.match(line):
            flush_paragraph()
            continue

        list_match = LIST_ITEM_RE.match(line)
        if list_match:
            flush_paragraph()
            text = list_match.group("text").strip()
            if text:
                items.append(text)
        else:
            paragraph.append(line)

    flush_paragraph()

    deduped: list[str] = []
    seen: set[str] = set()
    for item in items:
        if item and item not in seen:
            deduped.append(item)
            seen.add(item)
    return deduped


def items_for_commit(subject: str, body: str) -> tuple[str, ...]:
    _, summary = parse_type_and_summary(subject)
    items = clean_body_items(body)
    if not items and summary:
        items = [summary]
    return tuple(items)


def is_release_bump(subject: str) -> bool:
    return RELEASE_BUMP_RE.match(subject.strip()) is not None


def read_commits(repo: Path, current_ref: str, previous_ref: str | None) -> list[CommitNote]:
    log_format = "%x1e%H%x1f%s%x1f%b"
    raw_log = run_git(repo, ["log", "--no-merges", f"--pretty=format:{log_format}", release_range(current_ref, previous_ref)])
    notes: list[CommitNote] = []
    for record in raw_log.split("\x1e"):
        if not record.strip():
            continue
        parts = record.split("\x1f", 2)
        if len(parts) != 3:
            continue
        sha, subject, body = parts
        subject = subject.strip()
        if is_release_bump(subject):
            continue
        commit_type, _ = parse_type_and_summary(subject)
        items = items_for_commit(subject, body)
        if not items:
            continue
        notes.append(
            CommitNote(
                sha=sha.strip(),
                subject=subject,
                commit_type=commit_type,
                group=group_for_type(commit_type),
                items=items,
            )
        )
    return notes


def grouped_notes(notes: list[CommitNote]) -> dict[str, list[str]]:
    grouped: dict[str, list[str]] = {group: [] for group in GROUP_ORDER}
    for note in notes:
        grouped.setdefault(note.group, [])
        grouped[note.group].extend(note.items)
    return grouped
