// The MCP tool-descriptor parser (Koog agents-mcp `DefaultMcpToolDescriptorParser`): turn an MCP
// tool definition — `{ name, description, inputSchema }` where `inputSchema` is a JSON Schema —
// into a moonkoog `ToolDescriptor`. It walks the schema recursively, resolving `$ref` against
// `$defs`, and maps every JSON-Schema shape (primitives, arrays, objects, enums, `anyOf`, and
// nullable type-arrays like `["integer","null"]`) onto a `ToolParameterType`.

///|
/// Raised on a malformed MCP tool schema or JSON-RPC response (Koog throws `IllegalArgumentException`).
pub suberror McpError {
  McpError(String)
}

///|
let max_depth : Int32 = 30

///|
/// Parse an MCP tool definition into a `ToolDescriptor` (Koog `DefaultMcpToolDescriptorParser.parse`).
/// The `required` names decide which parsed parameters are required and which are optional.
pub fn parse_tool(tool : Json) -> @tools.ToolDescriptor raise {
  guard tool is Object(obj) else {
    raise McpError("tool must be a JSON object")
  }
  let name = str_field(obj, "name", "")
  let description = str_field(obj, "description", "")
  let schema : Map[String, Json] = match obj.get("inputSchema") {
    Some(Object(s)) => s
    _ => Map([])
  }
  let defs = lookup_defs(schema)
  let properties : Map[String, Json] = match schema.get("properties") {
    Some(Object(p)) => p
    _ => Map([])
  }
  let required = str_array_field(schema, "required")
  let params = parse_parameters(properties, defs)
  let required_parameters : Array[@tools.ToolParameterDescriptor] = []
  let optional_parameters : Array[@tools.ToolParameterDescriptor] = []
  for p in params {
    if required.contains(p.name) {
      required_parameters.push(p)
    } else {
      optional_parameters.push(p)
    }
  }
  { name, description, required_parameters, optional_parameters, }
}

///|
/// The `$defs` (or `definitions`) block of a schema, if present.
fn lookup_defs(schema : Map[String, Json]) -> Map[String, Json]? {
  match schema.get("$defs") {
    Some(Object(d)) => Some(d)
    _ =>
      match schema.get("definitions") {
        Some(Object(d)) => Some(d)
        _ => None
      }
  }
}

///|
/// Parse each property of an object schema into a named parameter descriptor.
fn parse_parameters(
  properties : Map[String, Json],
  defs : Map[String, Json]?,
) -> Array[@tools.ToolParameterDescriptor] raise {
  let out : Array[@tools.ToolParameterDescriptor] = []
  for name, element in properties {
    guard element is Object(el) else {
      raise McpError("parameter " + name + " must be a JSON object")
    }
    let description = str_field(el, "description", "")
    out.push({ name, description, ptype: parse_type(el, defs, 0), })
  }
  out
}

///|
/// Parse one JSON-Schema element into a `ToolParameterType`, resolving `$ref`, handling `anyOf` /
/// enum / nullable type-arrays, and recurring into arrays and objects.
fn parse_type(
  element : Map[String, Json],
  defs : Map[String, Json]?,
  depth : Int32,
) -> @tools.ToolParameterType raise {
  if depth > max_depth {
    raise McpError("maximum recursion depth exceeded (circular $ref?)")
  }
  if element.get("$ref") is Some(String(ref_str)) {
    return parse_type(resolve_ref(ref_str, defs), defs, depth + 1)
  }
  let (type_str, nullable_array) = parse_type_info(element.get("type"))
  guard type_str is Some(ts) else {
    if element.get("anyOf") is Some(Array(any_of)) {
      let descs : Array[@tools.ToolParameterDescriptor] = []
      for it in any_of {
        guard it is Object(o) else {
          raise McpError("anyOf entry must be a JSON object")
        }
        descs.push({
          name: "",
          description: str_field(o, "description", ""),
          ptype: parse_type(o, defs, depth + 1),
        })
      }
      return TAnyOf(descs)
    }
    if element.get("enum") is Some(Array(en)) && en.length() > 0 {
      return TEnum(enum_values(en))
    }
    raise McpError("parameter must have a type property")
  }
  let parsed : @tools.ToolParameterType = match ascii_lower(ts) {
    "string" => TString
    "integer" => TInteger
    "number" => TFloat
    "boolean" => TBoolean
    "null" => TNull
    "enum" =>
      match element.get("enum") {
        Some(Array(en)) => TEnum(enum_values(en))
        _ => raise McpError("enum type must have an enum property")
      }
    "array" =>
      match element.get("items") {
        Some(Object(items)) => TList(parse_type(items, defs, depth + 1))
        _ => raise McpError("array type must have an items property")
      }
    "object" => parse_object(element, defs, depth)
    other => raise McpError("unsupported parameter type: " + other)
  }
  // A type-array containing "null" (e.g. ["integer","null"]) is a nullable union.
  if nullable_array && parsed != TNull {
    TAnyOf([
      { name: "", description: "", ptype: TNull, },
      { name: "", description: "", ptype: parsed, },
    ])
  } else {
    parsed
  }
}

///|
/// Parse an `object` schema's `properties` / `required` into a `TObject`.
fn parse_object(
  element : Map[String, Json],
  defs : Map[String, Json]?,
  depth : Int32,
) -> @tools.ToolParameterType raise {
  let props : Array[@tools.ToolParameterDescriptor] = []
  if element.get("properties") is Some(Object(p)) {
    for pname, pval in p {
      guard pval is Object(po) else {
        raise McpError("property " + pname + " must be a JSON object")
      }
      props.push({
        name: pname,
        description: str_field(po, "description", ""),
        ptype: parse_type(po, defs, depth + 1),
      })
    }
  }
  TObject(properties=props, required=str_array_field(element, "required"))
}

///|
/// The JSON-Schema `type` keyword parsed into (primary non-null type, is-nullable-array): a single
/// string type, or an array like `["string","null"]` whose first non-null entry is the type and
/// whose containing `"null"` marks it nullable.
fn parse_type_info(type_element : Json?) -> (String?, Bool) {
  match type_element {
    Some(String(s)) => (Some(s), false)
    Some(Array(arr)) => {
      let types : Array[String] = []
      for t in arr {
        if t is String(s) {
          types.push(s)
        }
      }
      let non_null = types.filter(fn(x) { x != "null" })
      let ts = if non_null.length() == 0 {
        Some("null")
      } else {
        Some(non_null[0])
      }
      (ts, types.length() != non_null.length())
    }
    _ => (None, false)
  }
}

///|
/// The string form of every entry of a JSON-Schema `enum` (non-string entries as canonical JSON).
fn enum_values(entries : Array[Json]) -> Array[String] {
  let out : Array[String] = []
  for e in entries {
    out.push(
      match e {
        String(s) => s
        _ => e.stringify()
      },
    )
  }
  out
}

///|
/// Resolve a local `$ref` (`#/$defs/Name` or `#/definitions/Name`) against the defs block.
fn resolve_ref(
  ref_str : String,
  defs : Map[String, Json]?,
) -> Map[String, Json] raise {
  let path = split_slash(strip_prefix(ref_str, "#/"))
  guard path.length() == 2 && (path[0] == "$defs" || path[0] == "definitions") else {
    raise McpError("unsupported $ref format: " + ref_str)
  }
  match defs {
    Some(d) =>
      match d.get(path[1]) {
        Some(Object(o)) => o
        _ => raise McpError("definition not found: " + path[1])
      }
    None => raise McpError("no $defs for $ref: " + ref_str)
  }
}

///|
/// The string value of `key` in `obj`, or `default`.
fn str_field(obj : Map[String, Json], key : String, default : String) -> String {
  match obj.get(key) {
    Some(String(s)) => s
    _ => default
  }
}

///|
/// The string entries of the array at `key` in `obj` (empty when absent).
fn str_array_field(obj : Map[String, Json], key : String) -> Array[String] {
  let out : Array[String] = []
  if obj.get(key) is Some(Array(a)) {
    for x in a {
      if x is String(s) {
        out.push(s)
      }
    }
  }
  out
}

///|
/// `s` lowercased over ASCII `A`–`Z` (Koog lowercases the type keyword defensively).
fn ascii_lower(s : String) -> String {
  let sb = StringBuilder()
  for c in s {
    let code = c.to_int()
    if code >= 'A'.to_int() && code <= 'Z'.to_int() {
      sb.write_string((code + 32).unsafe_to_char().to_string())
    } else {
      sb.write_string(c.to_string())
    }
  }
  sb.to_string()
}

///|
/// `s` with `prefix` removed when present.
fn strip_prefix(s : String, prefix : String) -> String {
  if s.has_prefix(prefix) {
    let mut n = 0
    for _ in prefix {
      n = n + 1
    }
    drop_n(s, n)
  } else {
    s
  }
}

///|
/// `s` with its first `n` characters dropped.
fn drop_n(s : String, n : Int32) -> String {
  let sb = StringBuilder()
  let mut i = 0
  for c in s {
    if i >= n {
      sb.write_string(c.to_string())
    }
    i = i + 1
  }
  sb.to_string()
}

///|
/// `s` split on `/`.
fn split_slash(s : String) -> Array[String] {
  let out : Array[String] = []
  let sb = StringBuilder()
  for c in s {
    if c == '/' {
      out.push(sb.to_string())
      sb.reset()
    } else {
      sb.write_string(c.to_string())
    }
  }
  out.push(sb.to_string())
  out
}
