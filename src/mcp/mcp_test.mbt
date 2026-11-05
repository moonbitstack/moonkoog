// The MCP adapter: discover an MCP server's tools over a mock JSON-RPC transport, adapt each into a
// ToolDescriptor, render call results (error vs. success), and parse the full JSON-Schema surface.

///|
/// A transport that answers `tools/list` and `tools/call` from canned results.
struct MockTransport {
  list_result : Json
  call_result : Json
}

///|
impl @mcp.McpTransport for MockTransport with fn round_trip(self, request) {
  let rpc_method = match request {
    Object(o) =>
      match o.get("method") {
        Some(String(m)) => m
        _ => ""
      }
    _ => ""
  }
  let result = match rpc_method {
    "tools/list" => self.list_result
    "tools/call" => self.call_result
    _ => Json::object({})
  }
  { "jsonrpc": "2.0", "id": Json::number(1.0), "result": result }
}

///|
test "mcp: lists tools and adapts each into a ToolDescriptor with the right required/optional split" {
  let list_result = @json.parse(
    (
      #|{ "tools": [
      #|  { "name": "add", "description": "add two integers",
      #|    "inputSchema": { "type": "object",
      #|      "properties": {
      #|        "a": { "type": "integer", "description": "first" },
      #|        "b": { "type": "integer" } },
      #|      "required": ["a"] } } ] }
    ),
  )
  let transport = MockTransport::{ list_result, call_result: Json::object({}), }
  let registry = @mcp.mcp_tool_registry(@mcp.McpClient::new(transport))
  let d = registry.get_tool("add").unwrap().descriptor()
  assert_eq(d.name, "add")
  assert_eq(d.description, "add two integers")
  assert_eq(d.required_parameters.length(), 1)
  assert_eq(d.required_parameters[0].name, "a")
  assert_eq(d.required_parameters[0].ptype, @toolbox.TInteger)
  assert_eq(d.optional_parameters.length(), 1)
  assert_eq(d.optional_parameters[0].name, "b")
}

///|
test "mcp: an error result renders as an Error-prefixed message with the text content" {
  let call_result = @json.parse(
    (
      #|{ "content": [ { "type": "text", "text": "boom" } ], "isError": true }
    ),
  )
  let transport = MockTransport::{ list_result: Json::object({}), call_result, }
  let tool : &@toolbox.Tool = @mcp.McpTool::new(@mcp.McpClient::new(transport), {
    name: "x",
    description: "",
    required_parameters: [],
    optional_parameters: [],
  })
  assert_eq(tool.execute_raw(@json.parse("{}")), "Error: boom")
}

///|
test "mcp: a success result is returned as JSON carrying the content text" {
  let call_result = @json.parse(
    (
      #|{ "content": [ { "type": "text", "text": "42" } ], "isError": false }
    ),
  )
  let transport = MockTransport::{ list_result: Json::object({}), call_result, }
  let tool : &@toolbox.Tool = @mcp.McpTool::new(@mcp.McpClient::new(transport), {
    name: "x",
    description: "",
    required_parameters: [],
    optional_parameters: [],
  })
  let parsed = @json.parse(tool.execute_raw(@json.parse("{}")))
  let text = match parsed {
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
  assert_eq(text, "42")
}

///|
test "mcp parser: maps arrays, enums, anyOf, nullable type-arrays and $ref" {
  let schema = @json.parse(
    (
      #|{ "name": "t", "description": "d", "inputSchema": {
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
  let d = @mcp.parse_tool(schema)
  let ptype_of = fn(name : String) -> @toolbox.ToolParameterType {
    let mut found : @toolbox.ToolParameterType? = None
    for p in d.required_parameters {
      if p.name == name {
        found = Some(p.ptype)
      }
    }
    for p in d.optional_parameters {
      if p.name == name {
        found = Some(p.ptype)
      }
    }
    found.unwrap()
  }
  assert_eq(ptype_of("tags"), @toolbox.TList(@toolbox.TString))
  assert_eq(
    ptype_of("age"),
    @toolbox.TAnyOf([
      { name: "", description: "", ptype: @toolbox.TNull, },
      { name: "", description: "", ptype: @toolbox.TInteger, },
    ]),
  )
  assert_eq(
    ptype_of("mode"),
    @toolbox.TAnyOf([
      { name: "", description: "", ptype: @toolbox.TString, },
      { name: "", description: "", ptype: @toolbox.TInteger, },
    ]),
  )
  assert_eq(ptype_of("color"), @toolbox.TEnum(["red", "green"]))
}
