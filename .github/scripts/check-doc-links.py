#!/usr/bin/env python3
"""Validate repository-local Markdown links without touching the network."""

from __future__ import annotations

from pathlib import Path
import re
import urllib.parse

ROOT = Path(__file__).resolve().parents[2]
LINK_RE = re.compile(r"(?<!!)\[[^\]]*\]\(([^)]+)\)")
SKIP_PARTS = {".git", "artifacts", "out"}


def main() -> None:
    documents = sorted(
        path for path in ROOT.rglob("*.md") if not SKIP_PARTS.intersection(path.parts)
    )
    errors: list[str] = []

    for source in documents:
        text = source.read_text(encoding="utf-8")
        for raw in LINK_RE.findall(text):
            target = raw.strip().split()[0].strip("<>")
            if not target or target.startswith(("#", "http://", "https://", "mailto:")):
                continue
            path_part = urllib.parse.unquote(target.split("#", 1)[0])
            if not path_part:
                continue
            destination = (source.parent / path_part).resolve()
            try:
                destination.relative_to(ROOT)
            except ValueError:
                errors.append(f"{source.relative_to(ROOT)}: link escapes repository: {target}")
                continue
            if not destination.exists():
                errors.append(f"{source.relative_to(ROOT)}: missing local target: {target}")

    if errors:
        raise SystemExit("\n".join(errors))
    print(f"validated local links in {len(documents)} Markdown files")


if __name__ == "__main__":
    main()
