///|
/// The storage key a run records its own failure under. The graph cannot raise a library error
/// from a node, so the node records what went wrong and the walk ends; the agent turns that
/// record back into the error a caller expects.
pub let error_key : String = "moonkoog.error"

///|
/// The storage key a tool writes to ask the run to hand over to another agent. The value is the
/// node name of the agent to continue with.
pub let handoff_key : String = "moonkoog.handoff"

///|
/// Everything a node needs that is not the state: who is running, how to reach the model, what
/// may be called, which middleware is installed, what the caps are, and where events go.
///
/// Nodes are closures over one of these, so a graph is bound to a runtime at compile time and
/// two agents with different providers are two graphs over the same strategy.
pub struct Runtime {
  name : String
  provider : &@moonmuse.Provider
  model : String
  instructions : String?
  tools : Tools
  options : Options
  limits : Limits
  middleware : Array[&Middleware]
  events : EventHandler
  structured : Structured?
  chooser : &Chooser?
  exit_tool : String?
  custom : Map[String, NodeFn]
  /// The node names of the strategy this runtime was compiled for, so a tool that asks for a
  /// handover can tell a node of this graph from one that belongs to the agent that called it.
  nodes : Array[String]
}

///|
/// The provider a run calls, for a middleware or a composed strategy that needs to reach it.
pub fn Runtime::provider(self : Runtime) -> &@moonmuse.Provider {
  self.provider
}

///|
/// Whether this graph has a node of that name.
pub fn Runtime::has_node(self : Runtime, name : String) -> Bool {
  self.nodes.contains(name)
}

///|
/// The descriptors advertised on a call.
pub fn Runtime::tool_specs(self : Runtime) -> Array[@moonmuse.Tool] {
  self.tools.specs().map(spec => spec.tool)
}

///|
/// The tool of this name, if one is installed.
pub fn Runtime::tool(self : Runtime, name : String) -> ToolSpec? {
  for spec in self.tools.specs() {
    if spec.tool.name == name {
      return Some(spec)
    }
  }
  None
}

///|
/// The context a middleware sees for this node.
pub fn Runtime::context(
  self : Runtime,
  run : @moonstate.Run,
  state : AgentState,
) -> RunContext {
  {
    name: self.name,
    model: self.model,
    thread: run.thread(),
    step: run.step(),
    state,
    answer: run.answer(),
    pending: [],
    handover: @ref.Ref(None),
    runtime: self,
  }
}

///|
/// The text of an error, without the type path a `suberror`'s `to_string` prepends.
pub fn error_text(error : Error) -> String {
  match error {
    @moonmuse.LlmError::Status(code~, body~, ..) =>
      "model call failed with status " + code.to_string() + ": " + body
    @moonmuse.LlmError::Stream(reason) => "stream failed: " + reason
    @moonmuse.LlmError::Decode(reason) =>
      "could not decode the reply: " + reason
    @moonmuse.LlmError::Unsupported(reason) => "unsupported: " + reason
    _ => error.to_string()
  }
}
