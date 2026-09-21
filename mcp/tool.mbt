// The MCP tool bridge (Koog agents-mcp `McpTool` + `McpToolRegistryProvider`): expose an MCP
// server's tools to the agent as ordinary moonkoog tools. `McpTool` forwards a call as `tools/call`
// and renders the result the way Koog's `encodeResultToString` does — an `Error:` prefix and the
// text content when the result is flagged an error, the result JSON (minus meta fields) otherwise.
// `mcp_tool_registry` initializes the connection, lists the tools, parses each descriptor, and
// registers a wrapping `McpTool` for each.

///|
/// A moonkoog tool backed by an MCP server tool (Koog `McpTool`).
pub struct McpTool {
  client : McpClient
  desc : @tools.ToolDescriptor
}

///|
/// An MCP-backed tool calling `desc.name` on `client`.
pub fn McpTool::new(
  client : McpClient,
  desc : @tools.ToolDescriptor,
) -> McpTool {
  { client, desc, }
}

///|
pub impl @tools.Tool for McpTool with fn descriptor(self) {
  self.desc
}

///|
pub impl @tools.Tool for McpTool with fn execute_raw(self, args) {
  encode_result(self.client.call_tool(self.desc.name, args))
}

///|
/// Render a `CallToolResult` for the model (Koog `encodeResultToString`): on an error result, the
/// joined text content prefixed with `Error:` (falling back to the whole result JSON when it has no
/// text); otherwise the result JSON with the `_meta` / `type` fields stripped.
fn encode_result(result : Json) -> String {
  guard result is Object(o) else { return result.stringify() }
  let is_error = o.get("isError") is Some(True)
  let texts : Array[String] = []
  if o.get("content") is Some(Array(blocks)) {
    for b in blocks {
      if b is Object(bo) && str_field(bo, "type", "") == "text" {
        texts.push(str_field(bo, "text", ""))
      }
    }
  }
  if is_error {
    if texts.length() > 0 {
      "Error: " + join_newline(texts)
    } else {
      "Error: " + strip_meta(o).stringify()
    }
  } else {
    strip_meta(o).stringify()
  }
}

///|
/// The object without the LLM-irrelevant `_meta` / `type` fields.
fn strip_meta(o : Map[String, Json]) -> Json {
  let clean : Map[String, Json] = Map([])
  for k, v in o {
    if k != "_meta" && k != "type" {
      clean[k] = v
    }
  }
  Json::object(clean)
}

///|
/// Join `parts` with newlines.
fn join_newline(parts : Array[String]) -> String {
  let sb = StringBuilder()
  for i, p in parts {
    if i > 0 {
      sb.write_string("\n")
    }
    sb.write_string(p)
  }
  sb.to_string()
}

///|
/// Build a `ToolRegistry` from every tool an MCP server advertises (Koog `McpToolRegistryProvider`):
/// initialize the connection, list the tools, parse each descriptor, and register a wrapping tool.
pub fn mcp_tool_registry(client : McpClient) -> @tools.ToolRegistry raise {
  client.initialize() |> ignore
  let registry = @tools.ToolRegistry::new()
  for tool_json in client.list_tools() {
    registry.add(McpTool::new(client, parse_tool(tool_json))) |> ignore
  }
  registry
}

///|
pub extend McpTool with @tools.Tool::{descriptor, execute_raw}
