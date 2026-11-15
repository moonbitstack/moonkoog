"""An A2A server built on the official Python SDK, started as a child process.

It prints the port it bound as its first line of stdout, so the MoonBit client that
started it never has to guess one, and it serves the card at the well-known address.
"""

from __future__ import annotations

import asyncio
import socket
import sys

import uvicorn
from fastapi import FastAPI

from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.routes.fastapi_routes import add_a2a_routes_to_fastapi
from a2a.server.routes.agent_card_routes import create_agent_card_routes
from a2a.server.routes.jsonrpc_routes import create_jsonrpc_routes
from a2a.server.tasks import InMemoryTaskStore
from a2a.helpers import new_text_message
from a2a.types import (
    AgentCapabilities,
    AgentCard,
    AgentInterface,
    AgentSkill,
)


class Answerer(AgentExecutor):
    """Answers every message with one fixed line, so the client has something to compare."""

    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        await event_queue.enqueue_event(new_text_message("answered by the Python agent"))

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        raise NotImplementedError("the peer never cancels")


def card(port: int) -> AgentCard:
    url = f"http://127.0.0.1:{port}"
    return AgentCard(
        name="python-peer",
        description="an agent from the official SDK, for the interop checks",
        version="1.0.0",
        supported_interfaces=[
            AgentInterface(url=url, protocol_binding="JSONRPC", protocol_version="1.0")
        ],
        capabilities=AgentCapabilities(streaming=True),
        default_input_modes=["text/plain"],
        default_output_modes=["text/plain"],
        skills=[
            AgentSkill(
                id="answer",
                name="Answer",
                description="Answer anything, briefly",
                tags=["interop"],
            )
        ],
    )


def build(port: int) -> FastAPI:
    handler = DefaultRequestHandler(
        agent_executor=Answerer(),
        task_store=InMemoryTaskStore(),
        agent_card=card(port),
    )
    app = FastAPI()
    add_a2a_routes_to_fastapi(
        app,
        agent_card_routes=create_agent_card_routes(card(port)),
        jsonrpc_routes=create_jsonrpc_routes(handler, rpc_url="/"),
    )
    return app


async def serve() -> None:
    # The card has to carry the address the client will call, and it is built before the socket
    # is bound, so a free port is taken first and handed to both.
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    print(f"port={port}", flush=True)
    server = uvicorn.Server(
        uvicorn.Config(build(port), host="127.0.0.1", port=port, log_level="warning")
    )
    await server.serve()


if __name__ == "__main__":
    sys.exit(asyncio.run(serve()))
