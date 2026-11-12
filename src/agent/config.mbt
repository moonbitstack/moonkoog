///|
/// The request settings every call from this agent carries. The provider's own defaults apply
/// to anything left unset, so an empty record means "let the model decide".
pub(all) struct Options {
  temperature : Double?
  max_tokens : Int32?
  choice : @moonmuse.ToolChoice
  stop : Array[String]
  extra : Map[String, Json]
}

///|
/// Nothing pinned: the provider's defaults, tools left to the model's judgement, no stop
/// sequences.
pub let default_options : Options = {
  temperature: None,
  max_tokens: None,
  choice: @moonmuse.ToolChoice::Auto,
  stop: [],
  extra: Map([]),
}

///|
/// What a run may spend. `iterations` counts model calls, `tool_calls` counts executions, and
/// `steps` bounds the graph walk itself so a strategy that loops on its own still terminates.
///
/// The numbers follow the agent frameworks this one is built for: 50 model calls is the cap
/// their default agent uses, and a thousand node visits is the walk limit a compiled graph
/// gets. Raise them for a run that legitimately needs more, lower them in a test.
pub(all) struct Limits {
  iterations : Int32
  tool_calls : Int32
  steps : Int32
}

///|
/// The default caps.
pub let default_limits : Limits = {
  iterations: 50,
  tool_calls: 200,
  steps: 1000,
}

///|
/// The caps of a plain agent: [`default_limits`].
pub fn Limits::new() -> Limits {
  default_limits
}

///|
/// A copy with the model-call cap replaced.
pub fn Limits::with_iterations(self : Limits, iterations : Int32) -> Limits {
  { ..self, iterations, }
}

///|
/// A copy with the tool-call cap replaced.
pub fn Limits::with_tool_calls(self : Limits, tool_calls : Int32) -> Limits {
  { ..self, tool_calls, }
}

///|
/// A copy with the walk cap replaced.
pub fn Limits::with_steps(self : Limits, steps : Int32) -> Limits {
  { ..self, steps, }
}

///|
/// Ask the model for an object that matches `schema`, in a call that advertises a single
/// tool of that shape. The model's answer is the tool call's arguments, which is how a
/// provider without a `response_format` field can still be held to a schema.
pub(all) struct Structured {
  name : String
  schema : Json
}

///|
/// A structured-output request named `name`, validated against `schema`.
pub fn Structured::new(name : String, schema : Json) -> Structured {
  { name, schema, }
}
