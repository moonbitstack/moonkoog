// MCP end-to-end: an McpClient whose transport is a real McpServer over a moonkoog ToolRegistry, so
// discovery (tools/list) and invocation (tools/call) travel the actual MCP protocol between the two.

///|
/// A tool that echoes its `text` argument.
struct EchoTool {}

///|
impl @toolbox.Tool for EchoTool with fn descriptor(_self) {
  {
    name: "echo",
    description: "echoes text back",
    required_parameters: [
      { name: "text", description: "the text to echo", ptype: TString, },
    ],
    optional_parameters: [],
  }
}

///|
impl @toolbox.Tool for EchoTool with fn execute_raw(_self, args) {
  match args {
    Object(o) =>
      match o.get("text") {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
/// A client transport delivering each request straight into a server's handler.
struct ServerLoopback {
  server : @mcp.McpServer
}

///|
impl @mcp.McpTransport for ServerLoopback with fn round_trip(self, request) {
  self.server.handle(request)
}

///|
test "mcp e2e: a client discovers and calls the server's tools over the real protocol" {
  let registry = @toolbox.ToolRegistry::new().add(EchoTool::{ })
  let client = @mcp.McpClient::new(ServerLoopback::{
    server: @mcp.McpServer::new(registry),
  })
  let discovered = @mcp.mcp_tool_registry(client)
  let echo = discovered.get_tool("echo").unwrap()
  assert_eq(echo.descriptor().name, "echo")
  assert_eq(echo.descriptor().description, "echoes text back")
  assert_eq(echo.descriptor().required_parameters[0].name, "text")
  assert_eq(echo.descriptor().required_parameters[0].ptype, @toolbox.TString)
  // Calling the discovered tool runs EchoTool on the server; the CallToolResult carries the text.
  let result = @json.parse(echo.execute_raw(@json.parse("{\"text\":\"hi\"}")))
  let text = match result {
    Object(o) =>
      match o.get("content") {
        Some(Array(a)) =>
          match a[0] {
            Object(b) =>
              match b.get("text") {
                Some(String(s)) => s
                _ => ""
              }
            _ => ""
          }
        _ => ""
      }
    _ => ""
  }
  assert_eq(text, "hi")
}
