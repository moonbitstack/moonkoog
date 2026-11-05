// The MCP server (Koog `agents-mcp-server`): the reverse of the adapter — expose a moonkoog
// `ToolRegistry` to an MCP client. `handle` answers the JSON-RPC methods an MCP client issues:
// `initialize`, `tools/list` (each tool advertised with its JSON-Schema `inputSchema`), and
// `tools/call` (run the named tool and return its output as a `CallToolResult`, a tool failure
// coming back as an `isError` result rather than a protocol error).

///|
/// An MCP server exposing the tools in `registry`.
pub struct McpServer {
  registry : @toolbox.ToolRegistry
}

///|
/// A server advertising `registry`'s tools over MCP.
pub fn McpServer::new(registry : @toolbox.ToolRegistry) -> McpServer {
  { registry, }
}

///|
/// Handle one JSON-RPC request, returning the response — a `result`, or an `error` object when the
/// method itself fails (a tool's own failure is a normal `isError` result, not a protocol error).
pub fn McpServer::handle(self : McpServer, request : Json) -> Json {
  let (id, rpc_method, params) = match request {
    Object(o) =>
      (
        match o.get("id") {
          Some(x) => x
          None => Json::null()
        },
        str_field(o, "method", ""),
        match o.get("params") {
          Some(p) => p
          None => Json::object({})
        },
      )
    _ => (Json::null(), "", Json::object({}))
  }
  { "jsonrpc": "2.0", "id": id, "result": self.dispatch(rpc_method, params) } catch {
    McpError(msg) => server_error(id, msg)
    _ => server_error(id, "internal error")
  }
}

///|
/// Route one MCP method against the registry.
fn McpServer::dispatch(
  self : McpServer,
  rpc_method : String,
  params : Json,
) -> Json raise {
  match rpc_method {
    "initialize" =>
      {
        "protocolVersion": "2024-11-05",
        "capabilities": { "tools": Json::object({}) },
        "serverInfo": { "name": "moonkoog", "version": "0.2.0" },
      }
    "tools/list" => {
      let tools : Array[Json] = []
      for desc in self.registry.descriptors() {
        tools.push(descriptor_to_mcp(desc))
      }
      { "tools": Json::array(tools) }
    }
    "tools/call" => {
      guard params is Object(p) else {
        raise McpError("tools/call params must be an object")
      }
      let name = str_field(p, "name", "")
      let arguments = match p.get("arguments") {
        Some(a) => a
        None => Json::object({})
      }
      guard self.registry.get_tool(name) is Some(tool) else {
        raise McpError("unknown tool: " + name)
      }
      let (text, is_error) = (tool.execute_raw(arguments), false) catch {
        _ => ("tool execution failed", true)
      }
      {
        "content": [{ "type": "text", "text": text }],
        "isError": is_error.to_json(),
      }
    }
    other => raise McpError("unknown method: " + other)
  }
}

///|
/// A tool descriptor as an MCP tool definition: name, description, and a JSON-Schema `inputSchema`
/// object built from its parameters (this is the inverse of `parse_tool`).
fn descriptor_to_mcp(desc : @toolbox.ToolDescriptor) -> Json {
  let properties : Map[String, Json] = Map([])
  let required : Array[Json] = []
  for p in desc.required_parameters {
    properties[p.name] = param_schema(p)
    required.push(p.name.to_json())
  }
  for p in desc.optional_parameters {
    properties[p.name] = param_schema(p)
  }
  {
    "name": desc.name,
    "description": desc.description,
    "inputSchema": {
      "type": "object",
      "properties": Json::object(properties),
      "required": Json::array(required),
    },
  }
}

///|
/// A parameter's JSON-Schema, with its description folded in when it has one.
fn param_schema(p : @toolbox.ToolParameterDescriptor) -> Json {
  match p.ptype.to_json_schema() {
    Object(o) => {
      if p.description != "" {
        o["description"] = p.description.to_json()
      }
      Json::object(o)
    }
    other => other
  }
}

///|
/// A JSON-RPC error response.
fn server_error(id : Json, message : String) -> Json {
  {
    "jsonrpc": "2.0",
    "id": id,
    "error": { "code": Json::number(-32000), "message": message },
  }
}
