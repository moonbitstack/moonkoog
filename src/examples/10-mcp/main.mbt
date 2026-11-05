///|
/// A moonkoog tool the MCP server exposes.
struct EchoTool {}

///|
impl @tools.Tool for EchoTool with fn descriptor(_self) {
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
impl @tools.Tool for EchoTool with fn execute_raw(_self, args) {
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
/// A client transport delivering each request into a server's handler.
struct Loopback {
  server : @mcp.McpServer
}

///|
impl @mcp.McpTransport for Loopback with fn round_trip(self, request) {
  self.server.handle(request)
}

///|
/// The text of an MCP CallToolResult.
fn content_text(result : Json) -> String {
  match result {
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
}

///|
/// The Model Context Protocol adapter (Koog `agents-mcp`): expose a moonkoog
/// `ToolRegistry` as an `McpServer`, discover it from an `McpClient` and adapt each
/// remote tool into a `ToolDescriptor` (`mcp_tool_registry`), then call it over the
/// real `tools/list` + `tools/call` JSON-RPC. `parse_tool` maps the full JSON-Schema
/// surface — arrays, enums, anyOf, nullable unions, `$ref` — into the descriptor model.
///
///     moon run examples/26-mcp --target native
#coverage.skip
fn main {
  let server = @mcp.McpServer::new(
    @tools.ToolRegistry::new().add(EchoTool::{ }),
  )
  let client = @mcp.McpClient::new(Loopback::{ server, })
  try {
    let init = client.initialize()
    println("initialize ok: " + (init is Object(_)).to_string())
    println("list_tools: \{client.list_tools().length()} tool(s)")

    // Discover the server's tools as a local registry, then call one.
    let discovered = @mcp.mcp_tool_registry(client)
    let echo = discovered.get_tool("echo").unwrap()
    let d = echo.descriptor()
    println(
      "discovered '" +
      d.name +
      "': required[0]=" +
      d.required_parameters[0].name,
    )
    println(
      "call echo -> " +
      content_text(@json.parse(echo.execute_raw({ "text": "hello qwq" }))),
    )

    // The raw call path too.
    let direct = client.call_tool("echo", { "text": "direct 233" })
    println("call_tool direct -> " + content_text(direct))
  } catch {
    e => println("mcp error: " + e.to_string())
  }

  // parse_tool maps a full JSON-Schema input into typed parameters.
  try {
    let schema = @json.parse(
      (
        #|{ "name": "query", "description": "a rich tool", "inputSchema": {
        #|  "type": "object",
        #|  "$defs": { "Color": { "enum": ["red", "green"] } },
        #|  "properties": {
        #|    "tags":  { "type": "array", "items": { "type": "string" } },
        #|    "age":   { "type": ["integer", "null"] },
        #|    "mode":  { "anyOf": [ { "type": "string" }, { "type": "integer" } ] },
        #|    "color": { "$ref": "#/$defs/Color" } },
        #|  "required": ["tags"] } }
      ),
    )
    let parsed = @mcp.parse_tool(schema)
    println("parse_tool '" + parsed.name + "':")
    for p in parsed.required_parameters + parsed.optional_parameters {
      println("  " + p.name + " -> " + p.ptype.to_json_schema().stringify())
    }
  } catch {
    e => println("parse error: " + e.to_string())
  }
}
