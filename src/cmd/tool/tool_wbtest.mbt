///|
fn generate(source : String) -> String raise {
  @gen.render(Tool::{ }, [("tools.mbt", source)])
}

///|
test "a tool reads each argument by its name, as its pass mode asks" {
  let code = generate(
    (
      #|#koog.tool(description="Add two numbers")
      #|fn add(a : Double, b~ : Double, scale? : Double, note~ : String = "") -> Double {
      #|  a + b
      #|}
    ),
  )
  assert_true(code.contains("pub fn tools() -> Array[@moonkoog.ToolSpec]"))
  assert_true(code.contains("name=\"add\""))
  assert_true(code.contains("description=\"Add two numbers\""))
  assert_true(
    code.contains("@json.from_json(args.get(\"a\").unwrap_or(Json::null()))"),
  )
  assert_true(code.contains("b=@json.from_json(args.get(\"b\")"))
  assert_true(code.contains("scale?=match args.get(\"scale\")"))
  assert_true(code.contains("note?=match args.get(\"note\")"))
  // Only what a caller must give is required.
  assert_true(code.contains("\"required\": [\"a\", \"b\"]"))
  // A number is not text, so it goes back as JSON.
  assert_true(code.contains("@moonkoog.tool_result("))
  assert_true(code.contains("add("))
}

///|
test "a tool that answers in text is passed through, and a name can be given" {
  let code = generate(
    (
      #|#koog.tool(name="shout")
      #|fn loud(text : String) -> String {
      #|  text.to_upper()
      #|}
    ),
  )
  assert_true(code.contains("name=\"shout\""))
  assert_false(code.contains("tool_result"))
  assert_true(code.contains("\"text\": { \"type\": \"string\" }"))
}

///|
test "the run's context is handed over and left out of the schema" {
  let code = generate(
    (
      #|#koog.tool
      #|async fn remember(fact : String, ctx : @moonkoog.RunContext) -> String {
      #|  fact
      #|}
    ),
  )
  assert_true(code.contains("remember("))
  assert_true(code.contains("      context,"))
  assert_false(code.contains("\"ctx\""))
}

///|
test "an optional type reads as None when the argument is missing" {
  let code = generate(
    (
      #|#koog.tool
      #|fn greet(name : String?) -> String {
      #|  name.unwrap_or("you")
      #|}
    ),
  )
  assert_true(code.contains("None | Some(Null) => None"))
  assert_true(code.contains("\"required\": []"))
}

///|
test "an annotation on anything but a free function is refused" {
  let refused = try {
    ignore(
      generate(
        (
          #|#koog.tool
          #|struct Thing {}
        ),
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(refused)
}
