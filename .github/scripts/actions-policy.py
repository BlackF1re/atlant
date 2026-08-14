#!/usr/bin/env python3
"""AtlANTian policy for immutable, automatically maintained GitHub Actions."""

from __future__ import annotations

from collections import Counter
import json
from pathlib import Path
import re
import sys

ALLOWED_ACTIONS = {
    "actions/checkout",
    "actions/cache",
    "actions/upload-artifact",
    "actions/attest-build-provenance",
    "actions/configure-pages",
    "actions/upload-pages-artifact",
    "actions/deploy-pages",
}

USES_KEY_RE = re.compile(r"^\s*(?:-\s*)?uses:\s*")
USES_RE = re.compile(
    r"^\s*(?:-\s*)?uses:\s*([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@([0-9a-f]{40})\s*$"
)
VERSION_COMMENT_RE = re.compile(r"^\s*#\s*v[0-9][0-9A-Za-z._+-]*\s*$")
WORKFLOW_RE = re.compile(r"^\.github/workflows/[^/]+\.ya?ml$")


def fail(message: str) -> "NoReturn":
    raise SystemExit(message)


def scan_workflows(root: Path) -> None:
    seen = 0
    for path in sorted(root.glob("*.yml")) + sorted(root.glob("*.yaml")):
        lines = path.read_text(encoding="utf-8").splitlines()
        for number, line in enumerate(lines, 1):
            if not USES_KEY_RE.match(line):
                continue
            stripped = line.strip()
            if re.match(r"^-?\s*uses:\s*\./", stripped):
                continue
            match = USES_RE.match(line)
            if not match:
                fail(f"{path}:{number}: external action must use an immutable 40-hex SHA: {line.strip()}")
            action, _sha = match.groups()
            if action not in ALLOWED_ACTIONS:
                fail(f"{path}:{number}: external action is outside the AtlANTian allow-list: {action}")
            if number < 2 or not VERSION_COMMENT_RE.match(lines[number - 2]):
                fail(f"{path}:{number}: {action} pin must have an adjacent human-readable version comment")
            seen += 1
    if not seen:
        fail("no external GitHub Actions references were found")
    print(f"validated {seen} immutable, version-labelled GitHub Actions references")


def validate_dependabot_files(path: Path) -> None:
    files = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(files, list) or not files:
        fail("Dependabot PR has no changed files")

    changed_pins = 0
    for item in files:
        filename = item.get("filename", "")
        status = item.get("status")
        patch = item.get("patch")
        if status != "modified":
            fail(f"Dependabot auto-merge refuses non-modified file: {filename} ({status})")
        if not WORKFLOW_RE.match(filename):
            fail(f"Dependabot auto-merge refuses non-workflow file: {filename}")
        if not patch:
            fail(f"GitHub did not provide an auditable patch for {filename}")

        removed: list[tuple[str, str]] = []
        added: list[tuple[str, str]] = []
        for raw in patch.splitlines():
            if raw.startswith(("+++", "---", "@@")) or not raw.startswith(("+", "-")):
                continue
            line = raw[1:]
            match = USES_RE.match(line)
            if match:
                action, sha = match.groups()
                if action not in ALLOWED_ACTIONS:
                    fail(f"Dependabot proposed a non-allow-listed action: {action}")
                (added if raw.startswith("+") else removed).append((action, sha))
                continue
            # Human-readable version comments may move with an immutable pin.
            if VERSION_COMMENT_RE.match(line):
                continue
            fail(f"Dependabot auto-merge refuses non-pin change in {filename}: {line!r}")

        if Counter(action for action, _ in removed) != Counter(action for action, _ in added):
            fail(f"Dependabot changed action identity or workflow structure in {filename}")
        if len(removed) != len(added):
            fail(f"Dependabot pin replacement is unbalanced in {filename}")
        for old, new in zip(removed, added):
            if old[0] != new[0]:
                fail(f"Dependabot changed action identity in {filename}: {old[0]} -> {new[0]}")
            if old[1] == new[1]:
                fail(f"Dependabot did not change the immutable pin for {old[0]}")
        changed_pins += len(added)

    if not changed_pins:
        fail("Dependabot PR contains no GitHub Action pin updates")
    print(f"validated {changed_pins} Dependabot GitHub Action pin updates")


def main() -> None:
    if len(sys.argv) < 2:
        fail("usage: actions-policy.py scan [workflow-dir] | dependabot-files <files.json>")
    mode = sys.argv[1]
    if mode == "scan":
        root = Path(sys.argv[2] if len(sys.argv) > 2 else ".github/workflows")
        scan_workflows(root)
    elif mode == "dependabot-files" and len(sys.argv) == 3:
        validate_dependabot_files(Path(sys.argv[2]))
    else:
        fail("usage: actions-policy.py scan [workflow-dir] | dependabot-files <files.json>")


if __name__ == "__main__":
    main()
