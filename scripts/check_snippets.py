#!/usr/bin/env python3
"""Compile the MoonBit in the documentation.

Every `mbt` block in the README, the guide and the skill is a complete item
sequence — a `fn`, a `test` — so the blocks are written into one package and
checked with the compiler. A block whose fence carries `nocheck` is prose, and a
block that needs the native target says so with `mbt native`.

The package lives in a workspace beside this module rather than inside it: a
snippet must compile against what a user gets from `moon add`, not against the
repository's own test scaffolding.
"""

from __future__ import annotations

import html
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULE = "moonbitstack/moonkoog"
DOCUMENTS = [
    ROOT / "README.md",
    ROOT / "docs" / "skills" / "moonkoog" / "SKILL.md",
    ROOT / "docs" / "guide.html",
    ROOT / "docs" / "index.html",
]

# The packages a snippet may reach for, by the alias it would use. Only the ones a document
# actually mentions are imported, so the checked package has no unused dependency.
PACKAGES = {
    "moonkoog": "moonbitstack/moonkoog",
    "agent": "moonbitstack/moonkoog/agent",
    "middleware": "moonbitstack/moonkoog/middleware",
    "plan": "moonbitstack/moonkoog/plan",
    "multi": "moonbitstack/moonkoog/multi",
    "mcp": "moonbitstack/moonkoog/mcp",
    "otel": "moonbitstack/moonkoog/otel",
    "tools": "moonbitstack/moonkoog/tools",
    "fake": "moonbitstack/moonmuse/fake",
    "moonmuse": "moonbitstack/moonmuse",
    "moonstate": "moonbitstack/moonstate",
    "trace": "moonbitstack/moontel/trace",
    "client": "moonbitstack/moonmcp/client",
}


def manifest() -> tuple[str, list[str]]:
    """This module's version and the dependencies a snippet package has to declare."""
    text = (ROOT / "moon.mod").read_text(encoding="utf-8")
    match = re.search(r'version\s*=\s*"([^"]+)"', text)
    version = match.group(1) if match else "0.0.0"
    deps = re.findall(r'"([a-z0-9-]+/[a-z0-9-]+@[0-9.]+)"', text)
    return version, deps


def blocks(path: Path) -> list[tuple[str, bool]]:
    """The MoonBit blocks of a document, with whether each needs the native target."""
    text = path.read_text(encoding="utf-8")
    found: list[tuple[str, bool]] = []
    if path.suffix == ".html":
        for match in re.finditer(
            r'<pre(?P<attrs>[^>]*)><code>(?P<body>.*?)</code></pre>', text, re.S
        ):
            # `shell` is a command line and `excerpt` is a fragment of an example whose whole
            # form is in the guide; neither is a snippet of its own.
            if "shell" in match.group("attrs") or "excerpt" in match.group("attrs"):
                continue
            body = html.unescape(match.group("body"))
            found.append((body, "native" in match.group("attrs")))
        return found
    pattern = re.compile(
        r"(?P<fence>`{3,})(?P<info>[^\n]*)\n(?P<body>.*?)\n(?P=fence)", re.S
    )
    for match in pattern.finditer(text):
        info = match.group("info")
        if not info.startswith("mbt") or "nocheck" in info:
            continue
        found.append((match.group("body"), "native" in info.split()))
    return found


def main() -> int:
    snippets: list[tuple[str, str, bool]] = []
    for document in DOCUMENTS:
        if not document.exists():
            continue
        for index, (body, native) in enumerate(blocks(document)):
            snippets.append((f"{document.stem}_{index}.mbt", body, native))
    if not snippets:
        print("no snippets found", file=sys.stderr)
        return 1

    work = Path(tempfile.mkdtemp(prefix="moonkoog-snippets-"))
    package = work / "check"
    package.mkdir()
    try:
        (work / "moon.work").write_text(
            'members = ["check", "%s"]\n'
            % os.path.relpath(ROOT, work).replace("\\", "/"),
            encoding="utf-8",
        )
        version, deps = manifest()
        declared = [f'  "{MODULE}@{version}",'] + [f'  "{dep}",' for dep in deps]
        (package / "moon.mod").write_text(
            'name = "check/snippets"\nversion = "0.1.0"\n\nimport {\n'
            + "\n".join(declared)
            + "\n}\n",
            encoding="utf-8",
        )
        used = set()
        for _name, body, _native in snippets:
            used.update(re.findall(r"(?<![\w.])@([a-z][a-z0-9_]*)\.", body))
        lines = ["import {"]
        lines.append('  "moonbitlang/async",')
        for alias in sorted(used):
            target_pkg = PACKAGES.get(alias)
            if target_pkg is None:
                print(f"a snippet uses @{alias}, which has no package to import", file=sys.stderr)
                return 1
            lines.append(f'  "{target_pkg}",')
        lines.append("}")

        (package / "moon.pkg").write_text("\n".join(lines) + "\n", encoding="utf-8")
        for name, body, _native in snippets:
            (package / name).write_text(body + "\n", encoding="utf-8")
        result = subprocess.run(
            ["moon", "check", "--deny-warn"],
            cwd=work,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if result.returncode != 0:
            sys.stderr.write(result.stdout)
            sys.stderr.write(result.stderr)
            print(f"the snippets do not compile ({len(snippets)} blocks)", file=sys.stderr)
            return 1
        print(f"checked {len(snippets)} snippet blocks")
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
