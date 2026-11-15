"""Drive the agent over A2A with the official Python client.

The peer is the server half: this script starts the agent on a free port, reads its card from
the well-known address, sends one message, and compares the answer it gets back.
"""

from __future__ import annotations

import asyncio
import socket
import subprocess
import sys
import time

import httpx

from a2a.client import A2ACardResolver, ClientConfig, ClientFactory
from a2a.helpers import get_stream_response_text, new_text_message
from a2a.types import SendMessageRequest

EXPECTED = "answered over the wire"


def free_port() -> int:
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


def wait_for_card(client: httpx.Client, base: str) -> None:
    """Give the server a moment to bind, then ask for its card until it answers."""
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        try:
            response = client.get(f"{base}/.well-known/agent-card.json", timeout=1)
            if response.status_code == 200:
                return
        except httpx.HTTPError:
            pass
        time.sleep(0.1)
    raise AssertionError(f"{base} never served an agent card")


async def drive(binary: str) -> None:
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    server = subprocess.Popen(
        [binary, str(port)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        with httpx.Client() as probe:
            wait_for_card(probe, base)
        async with httpx.AsyncClient(timeout=15) as http:
            card = await A2ACardResolver(http, base).get_agent_card()
            if card.name != "interop":
                raise AssertionError(f"the card names {card.name!r}, not 'interop'")
            client = ClientFactory(ClientConfig(streaming=True)).create(card)
            answers = [
                get_stream_response_text(event)
                async for event in client.send_message(
                    SendMessageRequest(message=new_text_message("hello over the wire"))
                )
            ]
        if answers != [EXPECTED]:
            raise AssertionError(f"the agent answered {answers!r}, not [{EXPECTED!r}]")
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()


def main() -> int:
    binary = sys.argv[1] if len(sys.argv) > 1 else "./a2a-serve"
    asyncio.run(drive(binary))
    print("a2a-peer: card, SendMessage and the answer over a real socket")
    return 0


if __name__ == "__main__":
    sys.exit(main())
