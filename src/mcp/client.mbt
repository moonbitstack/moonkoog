// The MCP client (Koog agents-mcp `Client` over a `Transport`): JSON-RPC 2.0 with an incrementing
// request id. Koog's transports are stdio / SSE / streamable-HTTP coroutine streams; moonkoog's
// `Tool.execute_raw` is synchronous, so the transport here is a blocking request→response
// round-trip — mocked in tests, and backed by a real subprocess pipe or HTTP call in production.

///|
/// A synchronous MCP transport: send one JSON-RPC request, get its response (Koog `Transport`).
pub(open) trait McpTransport {
  fn round_trip(Self, request : Json) -> Json raise
}

///|
/// An MCP client over `transport`, issuing JSON-RPC 2.0 calls with monotonically increasing ids.
pub struct McpClient {
  transport : &McpTransport
  mut next_id : Int32
}

///|
/// A client that talks to an MCP server through `transport`.
pub fn McpClient::new(transport : &McpTransport) -> McpClient {
  { transport, next_id: 1, }
}

///|
/// Issue a JSON-RPC call and return its `result`, raising on a JSON-RPC `error` or a missing result.
fn McpClient::request(
  self : McpClient,
  rpc_method : String,
  params : Json,
) -> Json raise {
  let id = self.next_id
  self.next_id = self.next_id + 1
  let request : Json = {
    "jsonrpc": "2.0",
    "id": Json::number(id.to_double()),
    "method": rpc_method,
    "params": params,
  }
  let response = self.transport.round_trip(request)
  guard response is Object(o) else {
    raise McpError("JSON-RPC response must be a JSON object")
  }
  if o.get("error") is Some(Object(e)) {
    raise McpError("MCP error: " + str_field(e, "message", "unknown"))
  }
  match o.get("result") {
    Some(r) => r
    None => raise McpError("JSON-RPC response is missing 'result'")
  }
}

///|
/// The MCP `initialize` handshake, advertising the client name and protocol version.
pub fn McpClient::initialize(self : McpClient) -> Json raise {
  self.request("initialize", {
    "protocolVersion": "2024-11-05",
    "capabilities": Json::object({}),
    "clientInfo": { "name": "moonkoog", "version": "0.2.0" },
  })
}

///|
/// List the tools the MCP server exposes (`tools/list`), returning each tool definition's JSON.
pub fn McpClient::list_tools(self : McpClient) -> Array[Json] raise {
  match self.request("tools/list", Json::object({})) {
    Object(o) =>
      match o.get("tools") {
        Some(Array(a)) => a
        _ => []
      }
    _ => []
  }
}

///|
/// Call the MCP tool `name` with `arguments` (`tools/call`), returning the `CallToolResult` JSON.
pub fn McpClient::call_tool(
  self : McpClient,
  name : String,
  arguments : Json,
) -> Json raise {
  self.request("tools/call", { "name": name, "arguments": arguments })
}
