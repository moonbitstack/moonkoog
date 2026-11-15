// The functions the model may call. Each parameter becomes a property of the tool's input schema,
// typed from its MoonBit type; the ones with a default are not required.

///|
#koog.tool(description="Multiply two numbers")
fn multiply(a : Double, b : Double) -> Double {
  a * b
}

///|
#koog.tool(name="greet", description="Greet someone, loudly when asked")
fn hello(name : String, loud~ : Bool = false) -> String {
  let text = "hello, \{name}"
  if loud {
    text.to_upper()
  } else {
    text
  }
}
