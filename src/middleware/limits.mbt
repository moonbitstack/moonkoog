///|
/// Stop a run before it makes more model calls than the budget allows.
///
/// The cap is checked against what the run has already spent, which the state carries, so a
/// resumed run does not get a fresh budget. Reaching it ends the run with a line of text saying
/// so rather than failing: a caller that wanted an error can look at the answer.
pub struct ModelCallLimit {
  limit : Int32
}

///|
/// A cap of `limit` model calls per run.
pub fn ModelCallLimit::new(limit~ : Int32 = 10) -> ModelCallLimit {
  { limit, }
}

///|
pub extend ModelCallLimit with @agent.Middleware::{
  name,
  install,
  before_agent,
  wrap_model,
  wrap_tool,
  after_agent,
}

///|
pub impl @agent.Middleware for ModelCallLimit with fn name(_self) {
  "model_call_limit"
}

///|
pub impl @agent.Middleware for ModelCallLimit with fn install(_self, _tools) {
  ()
}

///|
pub impl @agent.Middleware for ModelCallLimit with fn before_agent(
  _self,
  _context,
) {
  []
}

///|
pub impl @agent.Middleware for ModelCallLimit with fn wrap_model(
  self,
  context,
  call,
  next,
) {
  if context.state.model_calls >= self.limit {
    return @agent.ModelOutcome::Halted(
      "model call limit of " + self.limit.to_string() + " reached",
    )
  }
  next(call)
}

///|
pub impl @agent.Middleware for ModelCallLimit with fn wrap_tool(
  _self,
  _context,
  call,
  next,
) {
  next(call)
}

///|
pub impl @agent.Middleware for ModelCallLimit with fn after_agent(
  _self,
  _context,
  _state,
) {
  []
}

///|
/// Stop a run from executing more tool calls than the budget allows, in total or for one tool.
///
/// A refused call comes back to the model as a failure rather than ending the run: the model can
/// then answer with what it has, which is usually better than ending mid-task.
pub struct ToolCallLimit {
  limit : Int32
  tool : String?
}

///|
/// A cap of `limit` executions, of one tool when `tool` is given and of all of them otherwise.
pub fn ToolCallLimit::new(limit~ : Int32 = 20, tool? : String) -> ToolCallLimit {
  { limit, tool, }
}

///|
pub extend ToolCallLimit with @agent.Middleware::{
  name,
  install,
  before_agent,
  wrap_model,
  wrap_tool,
  after_agent,
}

///|
pub impl @agent.Middleware for ToolCallLimit with fn name(_self) {
  "tool_call_limit"
}

///|
pub impl @agent.Middleware for ToolCallLimit with fn install(_self, _tools) {
  ()
}

///|
pub impl @agent.Middleware for ToolCallLimit with fn before_agent(
  _self,
  _context,
) {
  []
}

///|
pub impl @agent.Middleware for ToolCallLimit with fn wrap_model(
  _self,
  _context,
  call,
  next,
) {
  next(call)
}

///|
pub impl @agent.Middleware for ToolCallLimit with fn wrap_tool(
  self,
  context,
  call,
  next,
) {
  match self.tool {
    Some(name) => if decorate(call) != name { return next(call) }
    None => ()
  }
  let spent = match self.tool {
    Some(name) => tool_count(context.state, name)
    None => context.state.tool_calls
  }
  guard spent < self.limit else {
    return @agent.ToolOutcome::Failed(
      "tool call limit of " + self.limit.to_string() + " reached",
    )
  }
  next(call)
}

///|
pub impl @agent.Middleware for ToolCallLimit with fn after_agent(
  _self,
  _context,
  _state,
) {
  []
}

///|
/// The name of the call being made.
fn decorate(call : @agent.ToolCall) -> String {
  describe_call(call)
}

///|
/// How many times a tool has run in this thread so far. The tool node records it after each
/// round, which is why the count survives a checkpoint.
pub fn tool_count(state : @agent.AgentState, name : String) -> Int32 {
  match state.storage.get("moonkoog.tool_count." + name) {
    Some(Number(value, ..)) => value.to_int()
    _ => 0
  }
}
