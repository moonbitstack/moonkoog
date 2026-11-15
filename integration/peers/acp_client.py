"""Drive the agent over ACP with the official Python client.

The peer is the process an editor starts: this script spawns it, opens a session, sends one
prompt, and checks the updates it reports and the stop reason it settles on.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

from acp.schema import TextContentBlock
from acp.stdio import spawn_agent_process


class Recorder:
    """The client half: it keeps what the agent reports and answers nothing."""

    def __init__(self) -> None:
        self.updates: list[tuple[str, str]] = []

    async def session_update(self, session_id: str, update, **kwargs) -> None:
        content = getattr(update, "content", None)
        text = getattr(content, "text", "") if content is not None else ""
        self.updates.append((type(update).__name__, text))

    async def request_permission(self, session_id, tool_call, options, **kwargs):
        raise AssertionError("the agent asked for permission, which this run does not grant")


async def drive(binary: str) -> None:
    recorder = Recorder()
    async with spawn_agent_process(recorder, binary) as (conn, _process):
        initialized = await conn.initialize(
            protocol_version=1,
            client_capabilities={"fs": {"readTextFile": False, "writeTextFile": False}},
            client_info={"name": "moonkoog-interop", "version": "0.0.1"},
        )
        if initialized.protocol_version != 1:
            raise AssertionError(
                f"the agent speaks protocol version {initialized.protocol_version}, not 1"
            )

        session = await conn.new_session(cwd=str(Path.cwd()), mcp_servers=[])
        if not session.session_id:
            raise AssertionError("the agent opened a session without an identifier")

        answer = await conn.prompt(
            session_id=session.session_id,
            prompt=[TextContentBlock(type="text", text="hello over ACP")],
        )
        if answer.stop_reason != "end_turn":
            raise AssertionError(f"the agent stopped with {answer.stop_reason!r}")

        answers = [text for kind, text in recorder.updates if kind == "AgentMessageChunk"]
        if answers != ["answered over ACP"]:
            raise AssertionError(
                f"the answer did not arrive as one session update: {recorder.updates}"
            )


def main() -> int:
    binary = sys.argv[1] if len(sys.argv) > 1 else "./acp-agent"
    asyncio.run(drive(binary))
    print("acp-peer: initialize, session/new and session/prompt answered over stdio")
    return 0


if __name__ == "__main__":
    sys.exit(main())
