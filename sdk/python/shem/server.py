import asyncio
from .tools import _registry


def serve_tools(port: int = 5001) -> None:
    """Start an MCP server over stdio exposing all registered @shem.tool functions.

    The port parameter is accepted for API compatibility but ignored — stdio MCP
    servers communicate over stdin/stdout, not a TCP port.
    """
    asyncio.run(_serve())


async def _serve() -> None:
    from mcp.server import Server
    from mcp.server.stdio import stdio_server
    from mcp import types

    server = Server("shem-python-tools")

    @server.list_tools()
    async def list_tools() -> list[types.Tool]:
        return [
            types.Tool(
                name=entry["name"],
                description=entry["description"],
                inputSchema=entry["input_schema"],
            )
            for entry in _registry
        ]

    @server.call_tool()
    async def call_tool(name: str, arguments: dict) -> list[types.TextContent]:
        entry = next((e for e in _registry if e["name"] == name), None)
        if entry is None:
            raise ValueError(f"unknown tool: {name}")
        result = entry["fn"](**arguments)
        return [types.TextContent(type="text", text=str(result))]

    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            server.create_initialization_options(),
        )
