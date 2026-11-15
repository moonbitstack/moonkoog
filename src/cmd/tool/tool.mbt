///|
/// `#koog.tool` on free functions, turned into `tools()`.
priv struct Tool {}

///|
impl @gen.Generator for Tool with fn name(_) {
  "moonkoog"
}

///|
/// Where `attr` is written, as `file:line:column`.
fn at(attr : @attribute.Attribute, file : String) -> String {
  "\{file}:\{attr.loc.start.lnum}:\{attr.loc.start.column()}"
}

///|
fn quoted(text : String) -> String {
  @quote.string(text).to_string()
}

///|
/// Whether a parameter is the run's context rather than an argument the model gives.
fn is_context(param : @gen.Param) -> Bool {
  param.ty is Some(ty) && ty.trim(chars=" ").has_suffix("RunContext")
}

///|
/// The expression that reads argument `name` from `args`, as the parameter's pass mode and type
/// ask: a value that may be absent reads as `None` when it is missing or `null`.
fn read(name : String, ty : String) -> (String, String) {
  let field = "args.get(\{quoted(name)})"
  let maybe = "match \{field} { None | Some(Null) => None; Some(value) => Some(@json.from_json(value)) }"
  let sure = "@json.from_json(\{field}.unwrap_or(Json::null()))"
  (if @gen.is_optional(ty) { maybe } else { sure }, maybe)
}

///|
/// The arguments of the call, in order, and the parameters the schema describes.
fn call_of(
  params : Array[@gen.Param],
  where_ : String,
) -> (String, Array[@gen.Param]) raise {
  let call = []
  let described = []
  for param in params {
    guard param.name is Some(name) && param.ty is Some(ty) else {
      fail("\{where_}: every parameter needs a name and a type")
    }
    if is_context(param) {
      call.push(
        match param.pass {
          Positional => "context"
          _ => "\{name}=context"
        },
      )
      continue
    }
    described.push(param)
    let (value, maybe) = read(name, ty)
    call.push(
      match param.pass {
        Positional => value
        Labelled => "\{name}=\{value}"
        Optional | Defaulted => "\{name}?=\{maybe}"
      },
    )
  }
  (call.join(", "), described)
}

///|
/// The `ToolSpec` for the function `handler` under `attr`.
fn spec_of(
  attr : @attribute.Attribute,
  handler : String,
  params : Array[@gen.Param],
  returns : String?,
  is_async : Bool,
  file : String,
) -> String raise {
  let where_ = at(attr, file)
  guard @attr.name_of(attr) is Some("koog.tool") else {
    fail("\{where_}: not a moonkoog annotation")
  }
  let args = @attr.Spec::new("koog.tool")
    .optional("name", Str)
    .optional("description", Str)
    .bind(attr)
  let (call, described) = call_of(params, where_)
  let schema = @gen.object_schema(described, where_)
  let body = match returns {
    Some("String") => "\{handler}(\{call})"
    _ => "@moonkoog.tool_result(\{handler}(\{call}))"
  }
  let name = args.str("name").unwrap_or(handler)
  let description = args.str("description").unwrap_or("")
  // A function that does not wait gets an arrow, which may raise without saying so; an async one
  // needs the `async fn` form.
  let opening = if is_async {
    "async fn(args, context) {"
  } else {
    "(args, context) => {"
  }
  "@moonkoog.ToolSpec::new(name=\{quoted(name)}, description=\{quoted(description)}, schema=\{schema}, run=\{opening} let args = match args { Object(fields) => fields; _ => Map([]) }; ignore(args); ignore(context); \{body} })"
}

///|
impl @gen.Generator for Tool with fn generate(_, decls) {
  let specs = []
  for decl in decls {
    let found = @attr.under(decl.attrs(), "koog")
    guard found is [first, ..] else { continue }
    guard decl
      is Func(owner=None, name~, params~, returns~, is_async~, file~, ..) else {
      fail("\{at(first, decl.file())}: `#koog.tool` goes on a free function")
    }
    for attr in found {
      specs.push(spec_of(attr, name, params, returns, is_async, file))
    }
  }
  let source = "pub fn tools() -> Array[@moonkoog.ToolSpec] {\n  [\n" +
    specs.join(",\n") +
    "\n  ]\n}"
  @quote.items(source).render()
}
