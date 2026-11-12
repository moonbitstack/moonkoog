///|
/// A tool the model may call and the function behind it. The descriptor is what the model sees;
/// the function is handed the arguments object and returns the text the model reads back.
pub(all) struct ToolSpec {
  tool : @moonmuse.Tool
  run : async (Json) -> String
}

///|
/// A tool with a JSON-schema descriptor.
pub fn ToolSpec::new(
  name~ : String,
  description~ : String,
  run~ : async (Json) -> String,
  schema? : Json,
) -> ToolSpec {
  { tool: @moonmuse.Tool::new(name, description, schema?), run, }
}

///|
/// A tool whose descriptor is already built.
pub fn ToolSpec::of(
  tool : @moonmuse.Tool,
  run : async (Json) -> String,
) -> ToolSpec {
  { tool, run, }
}

///|
/// Everything an agent is configured with, short of the provider and the checkpoint stores.
///
/// A config is data plus a strategy: copying it and changing one field is how a second agent is
/// made, and the presets are the three shapes a run usually takes.
pub(all) struct AgentConfig {
  name : String
  model : String
  instructions : String?
  tools : Array[ToolSpec]
  options : Options
  limits : Limits
  middleware : Array[&Middleware]
  strategy : Strategy?
  structured : Structured?
  events : EventHandler
  exit_tool : String?
  nodes : Map[String, NodeFn]
}

///|
/// A config for `model` that runs the single-run loop.
pub fn AgentConfig::new(
  model : String,
  name~ : String = "agent",
) -> AgentConfig {
  {
    name,
    model,
    instructions: None,
    tools: [],
    options: default_options,
    limits: default_limits,
    middleware: [],
    strategy: None,
    structured: None,
    events: EventHandler::new(),
    exit_tool: None,
    nodes: Map([]),
  }
}

///|
/// The tool a chat strategy ends on: the model calls it when the conversation is over.
pub fn AgentConfig::exit_tool_spec() -> ToolSpec {
  ToolSpec::new(
    name="__exit__",
    description="End the conversation. Call this when there is nothing more to do.",
    schema=Json::object(Map([("type", Json::string("object"))])),
    run=_args => "conversation finished",
  )
}

///|
/// A config for the chat loop: the model must call tools, and calls `__exit__` to finish.
pub fn AgentConfig::chat(
  model : String,
  name~ : String = "agent",
) -> AgentConfig {
  let config = AgentConfig::new(model, name~)
  {
    ..config,
    strategy: Some(chat()),
    exit_tool: Some("__exit__"),
    tools: [AgentConfig::exit_tool_spec()],
  }
}

///|
/// A config for the reason-and-act loop.
pub fn AgentConfig::react(
  model : String,
  name~ : String = "agent",
  reasoning_prompt~ : String = "Think about what you have learned and what the next step should be.",
  interval~ : Int32 = 1,
) -> AgentConfig {
  {
    ..AgentConfig::new(model, name~),
    strategy: Some(react(reasoning_prompt~, interval~)),
  }
}

///|
/// A copy with the system instructions replaced.
pub fn AgentConfig::with_instructions(
  self : AgentConfig,
  instructions : String,
) -> AgentConfig {
  { ..self, instructions: Some(instructions), }
}

///|
/// A copy with tools added.
pub fn AgentConfig::with_tools(
  self : AgentConfig,
  tools : Array[ToolSpec],
) -> AgentConfig {
  let all = self.tools.copy()
  for spec in tools {
    all.push(spec)
  }
  { ..self, tools: all, }
}

///|
/// A copy with one more middleware, outermost last.
pub fn AgentConfig::with_middleware(
  self : AgentConfig,
  middleware : &Middleware,
) -> AgentConfig {
  let all = self.middleware.copy()
  all.push(middleware)
  { ..self, middleware: all, }
}

///|
/// A copy running the given strategy.
pub fn AgentConfig::with_strategy(
  self : AgentConfig,
  strategy : Strategy,
) -> AgentConfig {
  { ..self, strategy: Some(strategy), }
}

///|
/// A copy with the given caps.
pub fn AgentConfig::with_limits(
  self : AgentConfig,
  limits : Limits,
) -> AgentConfig {
  { ..self, limits, }
}

///|
/// A copy with the given request settings.
pub fn AgentConfig::with_options(
  self : AgentConfig,
  options : Options,
) -> AgentConfig {
  { ..self, options, }
}

///|
/// A copy asking for structured output against `schema`.
pub fn AgentConfig::with_structured(
  self : AgentConfig,
  structured : Structured,
) -> AgentConfig {
  { ..self, structured: Some(structured), }
}

///|
/// A copy reporting to the given handlers.
pub fn AgentConfig::with_events(
  self : AgentConfig,
  events : EventHandler,
) -> AgentConfig {
  { ..self, events, }
}

///|
/// A copy with a custom node body registered under `name`, for a strategy that names it.
pub fn AgentConfig::with_node(
  self : AgentConfig,
  name : String,
  body : NodeFn,
) -> AgentConfig {
  let nodes = self.nodes.copy()
  nodes[name] = body
  { ..self, nodes, }
}

///|
/// A run that went wrong, or one that was interrupted and can be resumed.
///
/// `Engine` carries the graph engine's own error unchanged so that an interrupt, a step limit
/// and a backend failure stay distinguishable to the caller.
pub(all) suberror AgentError {
  Exhausted(limit~ : Int32)
  Refused(reason~ : String)
  Engine(@moonstate.GraphError)
}

///|
/// Turn the failure a node recorded back into the error a caller sees.
fn recorded_failure(state : AgentState) -> AgentError? {
  match state.storage.get(error_key) {
    Some(String(reason)) => Some(Refused(reason~))
    Some(json) =>
      match json {
        Object(fields) =>
          match fields.get("exhausted") {
            Some(Number(limit, ..)) => Some(Exhausted(limit=limit.to_int()))
            _ => Some(Refused(reason=@moonjson.dumps(json)))
          }
        _ => Some(Refused(reason=@moonjson.dumps(json)))
      }
    None => None
  }
}

///|
/// An agent: a runtime, the graph its strategy compiled to, and the operations a caller runs.
///
/// The graph is the same engine a plain state machine uses — an agent is a graph whose nodes
/// happen to talk to a model, which is what keeps checkpoints, interrupts, resumption and
/// multi-agent composition available without a second mechanism.
pub struct Agent {
  runtime : Runtime
  graph : @moonstate.Graph[AgentState, Update]
  strategy_name : String
}

///|
/// The runtime an agent runs on — what a composed strategy or a protocol adapter needs in order
/// to add nodes of its own.
pub fn Agent::runtime(self : Agent) -> Runtime {
  self.runtime
}

///|
/// The agent's name.
pub fn Agent::name(self : Agent) -> String {
  self.runtime.name
}

///|
/// The strategy it runs.
pub fn Agent::strategy_name(self : Agent) -> String {
  self.strategy_name
}

///|
/// The model it calls.
pub fn Agent::model(self : Agent) -> String {
  self.runtime.model
}

///|
/// Build an agent. The strategy defaults to [`single_run`]; tools from the config are installed
/// first, then whatever the middleware contributes, so a middleware can replace a default tool
/// of the same name.
pub fn create_agent(
  provider : &@moonmuse.Provider,
  config : AgentConfig,
  saver? : &@moonstate.Saver,
  store? : &@moonstate.Store,
  executor? : &@moonstate.Executor,
) -> Agent raise @moonstate.Refused {
  let toolbox = @toolbox.Toolbox::new()
  for spec in config.tools {
    toolbox.add(spec.tool, spec.run)
  }
  let runtime : Runtime = {
    name: config.name,
    provider,
    model: config.model,
    instructions: config.instructions,
    toolbox,
    options: config.options,
    limits: config.limits,
    middleware: config.middleware,
    events: config.events,
    structured: config.structured,
    chooser: None,
    exit_tool: config.exit_tool,
    custom: config.nodes,
  }
  install_tools(runtime)
  let strategy = config.strategy.unwrap_or(single_run())
  let graph = strategy.compile(runtime, saver?, store?, executor?)
  { runtime, graph, strategy_name: strategy.name, }
}

///|
/// Run the agent on `input` and return its answer.
///
/// `thread` names the run's checkpoint thread: passing the same name again resumes from what was
/// checkpointed, which is what makes a durable agent possible without a separate API.
pub async fn Agent::run(
  self : Agent,
  input : String,
  thread? : String,
) -> String raise AgentError {
  let goal = Append([@moonmuse.Message::user(input)])
  self.walk(goal, input, thread?)
}

///|
/// Resume an interrupted run with the answer to the question it stopped on.
pub async fn Agent::resume_from(
  self : Agent,
  thread : String,
  answer : Json,
) -> String raise AgentError {
  let runtime = self.runtime
  let walked = Ok(self.graph.resume_with(thread, answer)) catch {
    error => Err(error)
  }
  match walked {
    Ok(state) => self.settle(state)
    Err(error) => {
      (runtime.events.on_agent_execution_failed)(error_text(error))
      runtime.events.report(
        AgentFailed(name=runtime.name, reason=error_text(error)),
      )
      raise Engine(error)
    }
  }
}

///|
/// Run and report each graph event to `listener`, which is how a caller watches a run as it
/// happens rather than after it ends.
pub async fn Agent::stream(
  self : Agent,
  input : String,
  listener : (Event) -> Unit,
  thread? : String,
) -> String raise AgentError {
  let runtime = self.runtime
  let previous = runtime.events.listener
  runtime.events.listener = event => {
    previous(event)
    listener(event)
  }
  let goal = Append([@moonmuse.Message::user(input)])
  let result = self.walk(goal, input, thread?)
  runtime.events.listener = previous
  result
}

///|
/// The walk itself: run the graph, then turn the state it settled on into an answer or an error.
async fn Agent::walk(
  self : Agent,
  goal : Update,
  input : String,
  thread? : String,
) -> String raise AgentError {
  let runtime = self.runtime
  (runtime.events.on_agent_starting)(input)
  (runtime.events.on_strategy_starting)(self.strategy_name)
  runtime.events.report(AgentStarted(name=runtime.name))
  let walked = Ok(self.graph.run(goal, thread?)) catch { error => Err(error) }
  match walked {
    Ok(state) => self.settle(state)
    Err(error) => {
      (runtime.events.on_agent_execution_failed)(error_text(error))
      runtime.events.report(
        AgentFailed(name=runtime.name, reason=error_text(error)),
      )
      raise Engine(error)
    }
  }
}

///|
/// Read the state a run ended on: its text, or the error a node recorded.
fn Agent::settle(self : Agent, state : AgentState) -> String raise AgentError {
  let runtime = self.runtime
  match recorded_failure(state) {
    Some(error) => {
      (runtime.events.on_agent_execution_failed)(describe(error))
      runtime.events.report(
        AgentFailed(name=runtime.name, reason=describe(error)),
      )
      raise error
    }
    None => {
      let text = state.text()
      (runtime.events.on_strategy_completed)(self.strategy_name, text)
      (runtime.events.on_agent_completed)(text)
      runtime.events.report(AgentFinished(name=runtime.name, text~))
      text
    }
  }
}

///|
/// A failure as a line of text, for hooks that only report.
pub fn describe(error : AgentError) -> String {
  match error {
    Exhausted(limit~) => "a cap of " + limit.to_string() + " was reached"
    Refused(reason~) => reason
    Engine(error) => error_text(error)
  }
}

///|
/// The state of a thread, when one was checkpointed.
pub async fn Agent::state(
  self : Agent,
  thread : String,
) -> @moonstate.Snapshot[AgentState]? raise AgentError {
  self.graph.state(thread) catch {
    error => raise Engine(error)
  }
}

///|
/// Every checkpoint of a thread, newest first.
pub async fn Agent::history(
  self : Agent,
  thread : String,
) -> Array[@moonstate.Snapshot[AgentState]] raise AgentError {
  self.graph.history(thread) catch {
    error => raise Engine(error)
  }
}
