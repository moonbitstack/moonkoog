///|
/// What a middleware is handed about the run it is taking part in: the agent's identity, the
/// thread it belongs to, the step it is on, and the state as of this node.
///
/// The state is a snapshot — a middleware that wants to change it returns updates, so every
/// change goes through the graph and lands in the checkpoint like a node's own write.
pub(all) struct RunContext {
  name : String
  model : String
  thread : String
  step : Int32
  state : AgentState
  /// The answer a resumed run was given, when the node is running again after an interrupt.
  answer : Json?
  /// The agent as built: provider, model, tool registry, the hooks. A middleware that needs to
  /// call the model itself (a summariser, a tool selector) reaches it through here.
  runtime : Runtime
  /// The handover a tool asked for during this node, if any.
  handover : @ref.Ref[String?]
  /// Updates a middleware wants the node to write. The node returns them as steps once the
  /// call it was wrapping has finished, so a hook can leave something in the state without a
  /// second channel to the graph.
  pending : Array[Update]
}

///|
/// One model call about to be made.
pub(all) struct ModelCall {
  request : @moonmuse.Request
}

///|
/// What a model call came to. `Halted` is a middleware refusing to spend the call, carrying
/// the text the run ends with — the shape a call limit takes.
pub(all) enum ModelOutcome {
  Replied(@moonmuse.Reply)
  /// The call did not produce a reply. `retryable` is the provider's own judgement — a rate
  /// limit or a gateway error is worth another attempt, a malformed request is not.
  Failed(reason~ : String, retryable~ : Bool)
  /// A middleware refused to spend the call; the run ends with this text as its answer.
  Halted(String)
}

///|
/// One tool call about to be made.
pub(all) struct ToolCall {
  part : @moonmuse.Part
}

///|
/// What a tool call came to. `Failed` records the reason as an error result, which is what the
/// model reads and what a retry policy looks at.
pub(all) enum ToolOutcome {
  Done(String)
  Failed(String)
  /// The call cannot run until the run is answered: the node stops on this value, the answer
  /// arrives on resumption, and the node runs again.
  Suspend(Json)
}

///|
/// A hook into a run, between the graph and the provider.
///
/// Four places to act: before the run starts, around each model call, around each tool call,
/// and after the run ends. The around-hooks take the next step as a function, so a middleware
/// can retry it, replace it, or skip it — and the pipeline nesting is the composition order,
/// first registered outermost.
///
/// A middleware may also install tools, which is how a feature that is best expressed as
/// something the model calls (a todo list, a shell, a file search) joins a run.
pub(open) trait Middleware {
  fn name(Self) -> String
  fn install(Self, Tools) -> Unit
  async fn before_agent(Self, RunContext) -> Array[Update]
  async fn wrap_model(
    Self,
    RunContext,
    ModelCall,
    async (ModelCall) -> ModelOutcome,
  ) -> ModelOutcome
  async fn wrap_tool(
    Self,
    RunContext,
    ToolCall,
    async (ToolCall) -> ToolOutcome,
  ) -> ToolOutcome
  async fn after_agent(Self, RunContext, AgentState) -> Array[Update]
}

///|
/// A middleware that changes nothing, for a caller that wants one hook and no others.
pub struct Passthrough {
  label : String
}

///|
/// A pass-through middleware under `name`.
pub fn Passthrough::new(name : String) -> Passthrough {
  { label: name, }
}

///|
/// The name it was built with.
pub fn Passthrough::name(self : Passthrough) -> String {
  self.label
}

///|
pub extend Passthrough with Middleware::{
  install,
  before_agent,
  wrap_model,
  wrap_tool,
  after_agent,
}

///|
pub impl Middleware for Passthrough with fn name(self) {
  self.label
}

///|
pub impl Middleware for Passthrough with fn install(_self, _toolbox) {
  ()
}

///|
pub impl Middleware for Passthrough with fn before_agent(_self, _context) {
  []
}

///|
pub impl Middleware for Passthrough with fn wrap_model(
  _self,
  _context,
  call,
  next,
) {
  next(call)
}

///|
pub impl Middleware for Passthrough with fn wrap_tool(
  _self,
  _context,
  call,
  next,
) {
  next(call)
}

///|
pub impl Middleware for Passthrough with fn after_agent(_self, _context, _state) {
  []
}
