"""Write the event sequence LangGraph produces for the graph the test replays.

The graph has the four nodes this library's single-run strategy has, under the same names, and
a stub model whose answers are the ones the MoonBit test scripts. Only the projection below is
compared, and it is the same projection `src/agent/langgraph_test.mbt` takes of this library's
stream:

    node:<name>    a node was entered
    tool:<name>    a tool ran
    answer:<text>  the run settled on this

Run with a pinned LangGraph (`pip install -r integration/requirements.txt`); the file it writes
is committed, and CI regenerates it and fails when the two differ.
"""

from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Annotated, TypedDict

from langgraph.graph import END, START, StateGraph

ROOT = Path(__file__).resolve().parent.parent
TARGET = ROOT / "src" / "agent" / "langgraph_fixture_wbtest.mbt"

# The two answers the stub model gives, in order: one tool call, then the final text.
SCRIPT = [
    {"call": {"name": "echo", "args": {"text": "hello"}}},
    {"text": "done"},
]


def add(left: list, right: list) -> list:
    return left + right


class State(TypedDict):
    messages: Annotated[list, add]
    cursor: int
    answer: str


def agent(state: State) -> dict:
    return {"messages": [{"role": "user", "text": "hello"}]}


def model(state: State) -> dict:
    step = SCRIPT[state["cursor"]]
    if "call" in step:
        return {
            "messages": [
                {
                    "role": "assistant",
                    "tool_call": step["call"]["name"],
                    "args": step["call"]["args"],
                }
            ],
            "cursor": state["cursor"] + 1,
        }
    return {
        "messages": [{"role": "assistant", "text": step["text"]}],
        "cursor": state["cursor"] + 1,
    }


def tools(state: State) -> dict:
    call = state["messages"][-1]
    echoed = "echoed " + call["args"]["text"]
    return {"messages": [{"role": "tool", "name": call["tool_call"], "text": echoed}]}


def finish(state: State) -> dict:
    last = state["messages"][-1]
    return {"answer": last.get("text", "")}


def route(state: State) -> str:
    return "tools" if "tool_call" in state["messages"][-1] else "finish"


def build():
    graph = StateGraph(State)
    graph.add_node("agent", agent)
    graph.add_node("model", model)
    graph.add_node("tools", tools)
    graph.add_node("finish", finish)
    graph.add_edge(START, "agent")
    graph.add_edge("agent", "model")
    graph.add_conditional_edges("model", route, {"tools": "tools", "finish": "finish"})
    graph.add_edge("tools", "model")
    graph.add_edge("finish", END)
    return graph.compile()


async def sequence() -> tuple[list[str], dict]:
    graph = build()
    events: list[str] = []
    state = {"messages": [], "cursor": 0, "answer": ""}
    async for chunk in graph.astream(
        {"messages": [], "cursor": 0, "answer": ""}, stream_mode="updates"
    ):
        for node, update in chunk.items():
            events.append("node:" + node)
            if update:
                for message in update.get("messages", []):
                    if message["role"] == "tool":
                        events.append("tool:" + message["name"])
                        state["messages"].append(message)
                    else:
                        state["messages"].append(message)
                if "answer" in update:
                    state["answer"] = update["answer"]
    events.append("answer:" + state["answer"])
    return events, state


def main() -> int:
    events, _state = asyncio.run(sequence())
    lines = [
        "///|",
        "/// The sequence LangGraph produced for the same graph, written by",
        "/// `scripts/gen_langgraph_events.py`. CI regenerates this file and fails when it differs.",
        "///",
        "/// It is a white-box fixture so that it stays out of the package's public interface: the",
        "/// only reader is the test beside it.",
        "let langgraph_steps : Array[String] = [",
    ]
    lines.extend(f'  "{step}",' for step in events)
    lines.append("]")
    # Written with the newline the repository uses, and then the formatter runs over it in CI:
    # the layout is the formatter's business, the steps are this script's.
    with TARGET.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(lines) + "\n")
    print("wrote", TARGET.relative_to(ROOT), "with", len(events), "steps")
    for step in events:
        print(" ", step)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
