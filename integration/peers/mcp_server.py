"""A tools-only MCP server, run over stdio by the interop checks.

It is deliberately boring: the smallest server the official SDK can build, so that a
failure on the MoonBit side means the client is wrong rather than the peer.
"""

from mcp.server.mcpserver import MCPServer

server = MCPServer("arith")


@server.tool()
def add(a: int, b: int) -> int:
    """Add two integers."""
    return a + b


@server.tool()
def shout(text: str) -> str:
    """Upper-case the text."""
    return text.upper()


if __name__ == "__main__":
    server.run()
