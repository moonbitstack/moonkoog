#!/usr/bin/env python3
"""Render the API reference from the generated interfaces.

Every public item of every package comes from `pkg.generated.mbti`, which `moon
info` writes; the doc comment for an item is read from the source, where it is
written as `///|` blocks above the definition. The page is regenerated in CI and
compared, so an interface change that is not reflected in the page fails the
build.
"""

from __future__ import annotations

import html
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
OUT = ROOT / "docs" / "api.html"
MODULE = "moonbitstack/moonkoog"

# The order the packages are presented in: the facade, then the agent and its
# pipeline, then the composed strategies, then the adapters.
ORDER = [
    "",
    "agent",
    "middleware",
    "plan",
    "multi",
    "otel",
    "tools",
    "mcp",
    "a2a",
    "acp",
    "rag",
    "skills",
    "serve",
]

PACKAGE_TITLES = {
    "": "The facade",
    "agent": "The agent",
    "middleware": "Middleware",
    "plan": "Planning",
    "multi": "Teams",
    "otel": "Observability",
    "tools": "Tools",
    "mcp": "MCP",
    "a2a": "A2A",
    "acp": "ACP",
    "rag": "Retrieval",
    "skills": "Skills",
    "serve": "Agent Protocol",
}

PACKAGE_NOTES = {
    "": "What importing the module root gives you: the agent, the built-in middleware, the planner, the team builder and the shipped tools, all re-exported from the package that owns them.",
    "agent": "The run itself: the state a graph checkpoints, the strategy that decides which node runs, the middleware chain around each model and tool call, and the events a run reports.",
    "middleware": "The built-in pipeline. Each one wraps the model call, the tool call, or both.",
    "plan": "Goal-oriented search over world states, and the plan-and-execute strategy.",
    "multi": "Agents as nodes of one graph: handovers, a swarm that follows them, and a supervisor that chooses.",
    "otel": "A run as GenAI spans.",
    "tools": "The tools this module ships.",
    "mcp": "An agent as an MCP server, and another server's tools as this agent's tools.",
    "a2a": "An agent behind A2A, and a remote agent as a tool.",
    "acp": "An agent behind ACP.",
    "rag": "Retrieval as a tool, and retrieval as middleware.",
    "skills": "Progressive loading of skill documents.",
    "serve": "The Agent Protocol's threads and runs over moonapi.",
}


def package_dir(name: str) -> Path:
    return SRC if name == "" else SRC / name


def read_sources(directory: Path) -> dict[str, str]:
    """Doc comments by the name of the item they precede."""
    docs: dict[str, str] = {}
    for path in sorted(directory.glob("*.mbt")):
        if path.name.endswith("_test.mbt") or path.name.endswith("_wbtest.mbt"):
            continue
        lines = path.read_text(encoding="utf-8").splitlines()
        block: list[str] = []
        for line in lines:
            stripped = line.strip()
            if stripped == "///|":
                block = []
            elif stripped.startswith("///"):
                block.append(stripped[3:].strip())
            elif stripped:
                name = item_name(stripped)
                if name and block:
                    text = " ".join(part for part in block if part)
                    docs.setdefault(name, text)
                block = []
    return docs


def item_name(line: str) -> str | None:
    patterns = [
        r"pub fn (?:\[[^\]]*\] )?([A-Za-z0-9_]+)::",
        r"pub fn (?:\[[^\]]*\] )?([a-z0-9_]+)\b",
        r"pub(?:\(all\))? struct ([A-Za-z0-9_]+)",
        r"pub(?:\(all\))? enum ([A-Za-z0-9_]+)",
        r"pub(?:\(all\))? suberror ([A-Za-z0-9_]+)",
        r"pub let ([A-Za-z0-9_]+)",
        r"pub\(open\) trait ([A-Za-z0-9_]+)",
        r"pub type ([A-Za-z0-9_]+)",
    ]
    for pattern in patterns:
        match = re.match(pattern, line)
        if match:
            return match.group(1)
    return None


def keyword(line: str) -> str:
    if " trait " in line:
        return "trait"
    for word in ("suberror", "struct", "enum", "fn", "let", "type"):
        if f" {word} " in line or line.startswith(f"pub {word} "):
            return word
    return "item"


def parse_mbti(path: Path) -> list[tuple[str, list[str]]]:
    """The file as (kind, lines) groups: `// Values`, `// Errors` and so on."""
    groups: list[tuple[str, list[str]]] = []
    kind = "Declarations"
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("// "):
            kind = line[3:].strip()
            groups.append((kind, []))
            continue
        if not line.strip():
            continue
        if line.startswith("package ") or line.startswith("import"):
            continue
        if not line.startswith("pub") and not line.startswith("#derive"):
            continue
        if not groups:
            groups.append((kind, []))
        groups[-1][1].append(line)
    return [(kind, lines) for kind, lines in groups if lines]


def render_item(kind: str, line: str, docs: dict[str, str]) -> str:
    name = item_name(line) or ""
    doc = docs.get(name, "")
    signature = html.escape(line)
    for word in ("pub(all)", "pub(open)", "pub", "fn", "struct", "enum", "trait"):
        signature = signature.replace(
            word, f'<span class="k">{word}</span>', 1
        ) if word in signature.split(" ")[0] else signature
    body = f'<p class="sig">{signature}</p>'
    if doc:
        body += f'<p class="doc">{html.escape(doc)}</p>'
    return f'<div class="item" data-k="{kind}"><span class="kind">{kind}</span>{body}</div>'


def page(sections: str, stats: str) -> str:
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>moonkoog — API reference</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans:wght@400;500;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="style.css">
</head>
<body>
<div class="layout">
<aside class="sidebar">
  <a class="brand" href="index.html"><span class="dot"></span>moonkoog</a>
  <p class="brand-sub">agents on the moonstate graph</p>
  <nav class="side-nav">
    <a href="index.html"><span class="at">#</span>overview</a>
    <a href="guide.html"><span class="at">#</span>guide</a>
    <a class="active" href="api.html"><span class="at">#</span>api</a>
    <a href="https://github.com/moonbitstack/moonkoog"><span class="at">#</span>github</a>
  </nav>
  <div class="side-foot">
    <button class="theme-btn" id="theme">theme: system</button>
  </div>
</aside>
<main>
  <div class="hero">
    <h1>API reference</h1>
    <p class="tag">Every public item of every package, generated from the interfaces the compiler writes. {stats}</p>
  </div>
  {sections}
  <footer>moonkoog · <a href="https://github.com/moonbitstack/moonkoog">github.com/moonbitstack/moonkoog</a></footer>
</main>
</div>
<script src="site.js"></script>
</body>
</html>
"""


def main() -> int:
    if not (SRC / "pkg.generated.mbti").exists():
        print("run `moon info` first: src/pkg.generated.mbti is missing", file=sys.stderr)
        return 1
    sections: list[str] = []
    items = 0
    packages = 0
    for name in ORDER:
        directory = package_dir(name)
        mbti = directory / "pkg.generated.mbti"
        if not mbti.exists():
            continue
        packages += 1
        docs = read_sources(directory)
        anchor = name.replace("/", "-") or "root"
        title = PACKAGE_TITLES.get(name, name)
        path = MODULE if name == "" else f"{MODULE}/{name}"
        blocks: list[str] = []
        for kind, lines in parse_mbti(mbti):
            rendered = [render_item(kind, line, docs) for line in lines]
            items += len(rendered)
            blocks.append(
                f'<h3 class="group">{html.escape(kind)}</h3>' + "".join(rendered)
            )
        sections.append(
            f'<section class="pkg" id="{anchor}">'
            f'<h2><span class="at">#</span>{html.escape(title)} '
            f'<code class="path">{html.escape(path)}</code></h2>'
            f'<p class="pdesc">{html.escape(PACKAGE_NOTES.get(name, ""))}</p>'
            + "".join(blocks)
            + "</section>"
        )
    stats = f"{items} public items across {packages} packages."
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(page("".join(sections), stats), encoding="utf-8", newline="\n")
    print(f"wrote {OUT.relative_to(ROOT)}: {items} items, {packages} packages")
    return 0


if __name__ == "__main__":
    sys.exit(main())
