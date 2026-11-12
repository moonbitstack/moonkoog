///|
/// A tool that does arithmetic on two numbers.
///
/// Models are unreliable at arithmetic and good at deciding that arithmetic is needed, which is
/// exactly the division of labour a tool exists for. Division by zero is refused rather than
/// answered with infinity: a wrong number that looks like a number is worse than an error.
pub fn calculator() -> @agent.ToolSpec {
  @agent.ToolSpec::new(
    name="calculator",
    description="Apply one of add, subtract, multiply or divide to a and b.",
    schema=Json::object(
      Map([
        ("type", Json::string("object")),
        (
          "properties",
          Json::object(
            Map([
              (
                "op",
                Json::object(
                  Map([
                    ("type", Json::string("string")),
                    (
                      "enum",
                      Json::array([
                        Json::string("add"),
                        Json::string("subtract"),
                        Json::string("multiply"),
                        Json::string("divide"),
                      ]),
                    ),
                  ]),
                ),
              ),
              ("a", Json::object(Map([("type", Json::string("number"))]))),
              ("b", Json::object(Map([("type", Json::string("number"))]))),
            ]),
          ),
        ),
        (
          "required",
          Json::array([Json::string("op"), Json::string("a"), Json::string("b")]),
        ),
      ]),
    ),
    run=fn(args, _context) {
      let op = arg_string(args, "op").unwrap_or("")
      let a = arg_number(args, "a")
      let b = arg_number(args, "b")
      match (a, b) {
        (Some(a), Some(b)) =>
          match op {
            "add" => (a + b).to_string()
            "subtract" => (a - b).to_string()
            "multiply" => (a * b).to_string()
            "divide" =>
              if b == 0.0 {
                "error: division by zero"
              } else {
                (a / b).to_string()
              }
            _ => "error: unknown operation " + op
          }
        _ => "error: a and b must both be numbers"
      }
    },
  )
}

///|
/// The tools this package ships.
pub fn all() -> Array[@agent.ToolSpec] {
  [calculator()]
}

///|
/// A string field of a tool call's arguments.
fn arg_string(args : Json, key : String) -> String? {
  match args {
    Object(fields) =>
      match fields.get(key) {
        Some(String(value)) => Some(value)
        _ => None
      }
    _ => None
  }
}

///|
/// A number field of a tool call's arguments.
fn arg_number(args : Json, key : String) -> Double? {
  match args {
    Object(fields) =>
      match fields.get(key) {
        Some(Number(value, ..)) => Some(value)
        _ => None
      }
    _ => None
  }
}
