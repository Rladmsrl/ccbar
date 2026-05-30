#!/usr/bin/env python3
"""Generate GitHub and Sparkle release notes from source commits."""

from __future__ import annotations

import argparse
import html
import re
import subprocess
import sys
from pathlib import Path

from release_notes_lib import GROUP_ORDER, find_previous_tag, grouped_notes, read_commits


RELEASE_REPO_URL = "https://github.com/rladmsrl/ccbar"
SPARKLE_PRIMARY_GROUPS = ["新功能", "修复", "性能", "改进"]
SPARKLE_FALLBACK_GROUPS = ["工程与发布", "其他"]


def render_markdown(grouped: dict[str, list[str]], previous_tag: str | None) -> str:
    lines = ["## 更新内容", ""]
    if previous_tag:
        lines.extend([f"自 [`{previous_tag}`]({RELEASE_REPO_URL}/releases/tag/{previous_tag}) 以来：", ""])

    wrote_group = False
    for group in GROUP_ORDER:
        items = grouped.get(group, [])
        if not items:
            continue
        wrote_group = True
        lines.extend([f"### {group}", ""])
        lines.extend(f"- {item}" for item in items)
        lines.append("")

    if not wrote_group:
        lines.append("- 本次发布没有源代码提交记录。")

    return "\n".join(lines).rstrip() + "\n"


def sparkle_items(grouped: dict[str, list[str]]) -> list[str]:
    items: list[str] = []
    for group in SPARKLE_PRIMARY_GROUPS:
        items.extend(grouped.get(group, []))
    if not items:
        for group in SPARKLE_FALLBACK_GROUPS:
            items.extend(grouped.get(group, []))
    return items[:8]


def render_sparkle_html(grouped: dict[str, list[str]]) -> str:
    items = sparkle_items(grouped)
    if not items:
        return "<h2>本次更新</h2>\n<p>本次发布包含稳定性和体验改进。</p>\n"

    lines = ["<h2>本次更新</h2>", "<ul>"]
    for item in items:
        lines.append(f"<li>{html.escape(item, quote=False)}</li>")
    lines.append("</ul>")
    return "\n".join(lines) + "\n"


def markdown_override_to_html(markdown_text: str) -> str:
    lines: list[str] = []
    paragraph: list[str] = []
    open_list: str | None = None

    def flush_paragraph() -> None:
        nonlocal paragraph
        if paragraph:
            lines.append(f"<p>{html.escape(' '.join(paragraph), quote=False)}</p>")
            paragraph = []

    def close_list() -> None:
        nonlocal open_list
        if open_list:
            lines.append(f"</{open_list}>")
            open_list = None

    for raw_line in markdown_text.splitlines():
        line = raw_line.strip()
        if not line:
            flush_paragraph()
            close_list()
            continue

        heading = re.match(r"^(#{1,6})\s+(.+)$", line)
        if heading:
            flush_paragraph()
            close_list()
            level = len(heading.group(1))
            text = html.escape(heading.group(2).strip(), quote=False)
            lines.append(f"<h{level}>{text}</h{level}>")
            continue

        unordered = re.match(r"^[-*+]\s+(.+)$", line)
        ordered = re.match(r"^\d+[.)、]\s+(.+)$", line)
        list_match = unordered or ordered
        if list_match:
            flush_paragraph()
            target_list = "ul" if unordered else "ol"
            if open_list != target_list:
                close_list()
                lines.append(f"<{target_list}>")
                open_list = target_list
            text = html.escape(list_match.group(1).strip(), quote=False)
            lines.append(f"<li>{text}</li>")
            continue

        close_list()
        paragraph.append(line)

    flush_paragraph()
    close_list()
    return "\n".join(lines).strip() + "\n"


def read_sparkle_override(repo: Path, tag: str, override_dir: Path) -> str | None:
    base_dir = override_dir if override_dir.is_absolute() else repo / override_dir
    html_path = base_dir / f"{tag}.html"
    md_path = base_dir / f"{tag}.md"

    if html_path.exists():
        raw = html_path.read_text(encoding="utf-8").strip()
        if "]]>" in raw:
            raise ValueError(f"{html_path} contains ']]>', which would break appcast CDATA")
        return raw + "\n"

    if md_path.exists():
        raw = md_path.read_text(encoding="utf-8")
        if "]]>" in raw:
            raise ValueError(f"{md_path} contains ']]>', which would break appcast CDATA")
        return markdown_override_to_html(raw)

    return None


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True, help="current release tag, e.g. v1.3.12")
    parser.add_argument("--markdown-out", required=True, type=Path)
    parser.add_argument("--sparkle-html-out", required=True, type=Path)
    parser.add_argument("--repo", default=Path.cwd(), type=Path)
    parser.add_argument("--sparkle-override-dir", default=Path("release-notes/sparkle"), type=Path)
    args = parser.parse_args()

    repo = args.repo.resolve()
    previous_tag = find_previous_tag(repo, args.tag)
    notes = read_commits(repo, args.tag, previous_tag)
    grouped = grouped_notes(notes)

    markdown = render_markdown(grouped, previous_tag)
    sparkle_html = read_sparkle_override(repo, args.tag, args.sparkle_override_dir)
    if sparkle_html is None:
        sparkle_html = render_sparkle_html(grouped)
    if "]]>" in sparkle_html:
        print("error: Sparkle release notes contain ']]>', which would break appcast CDATA", file=sys.stderr)
        return 1

    write_text(args.markdown_out, markdown)
    write_text(args.sparkle_html_out, sparkle_html)
    print(f"generated {args.markdown_out} and {args.sparkle_html_out}")
    if previous_tag:
        print(f"commit range: {previous_tag}..{args.tag}")
    else:
        print(f"commit range: {args.tag}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        print(f"error: git command failed with exit code {error.returncode}: {' '.join(error.cmd)}", file=sys.stderr)
        if error.output:
            print(error.output, file=sys.stderr)
        raise SystemExit(error.returncode)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
