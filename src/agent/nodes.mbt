///|
/// The node an agent run starts from: it seeds the system message, runs the middleware's
/// run-start hooks, and hands over to the model node.
pub let agent_node : String = "agent"

///|
/// The node that makes one model call.
pub let model_node : String = "model"

///|
/// The node that executes the calls a reply asked for.
pub let tools_node : String = "tools"

///|
/// The node a run ends on.
pub let finish_node : String = "finish"

///|
/// Which way a request node asks the model.
///
/// This is the whole of the request side: the many request nodes a Kotlin-style DSL spells out
/// separately differ only in what they put in the request — the tools, the choice, the number
/// of candidates, whether the answer is streamed or shaped by a schema.
pub(all) enum RequestMode {
  /// Advertise the toolbox and let the model decide.
  Tools
  /// Advertise nothing, for a turn that must answer in prose.
  NoTools
  /// Advertise the toolbox and require a call.
  OnlyCalling
  /// Advertise the toolbox and require the named tool.
  ForceOne(String)
  /// Ask `count` times and keep the candidate the chooser prefers.
  Choice(Int32)
  /// Stream the reply, reporting deltas to the event handler.
  Streaming
  /// Answer as an object matching the agent's structured-output schema.
  StructuredOutput
}

///|
/// Which calls an execution node runs.
pub(all) enum ExecuteMode {
  /// Every call in the reply.
  All
  /// Only the call at this position, for a run that executes calls one at a time.
  Single(Int32)
}

///|
/// Which part of the conversation a compression node folds into a summary.
pub(all) enum HistoryPolicy {
  Whole
  FromLast(Int32)
}

///|
/// One position in a strategy graph.
///
/// Four kinds cover the twenty-six node functions the graph DSL of the framework this one is
/// designed after exposes: every request variant is one `Request` mode, every tool-result
/// variant folds into the request that follows it, tool execution is one node, history
/// compression and the exit are one each. The moderation nodes are a middleware here, because
/// what they do — inspect or rewrite messages on the way through — is a pipeline concern.
pub(all) enum NodeKind {
  /// The run-start node: seeds the system message and runs the middleware's start hooks.
  Start
  Request(RequestMode)
  Execute(ExecuteMode)
  Compress(HistoryPolicy)
  Finish
  /// Reason without tools, every `every` rounds of the run.
  Think(prompt~ : String, every~ : Int32)
  /// Add a message and ask again — how a strategy nudges the model.
  Advise(String)
  /// A body the caller registered on the runtime.
  Custom(String)
}

///|
/// The request this node sends: the conversation so far, the tools the mode allows, and the
/// agent's options.
pub fn Runtime::request_for(
  self : Runtime,
  mode : RequestMode,
  state : AgentState,
) -> @moonmuse.Request {
  let tools = match mode {
    NoTools | StructuredOutput => []
    _ => self.toolbox.tools()
  }
  let choice = match mode {
    OnlyCalling => @moonmuse.ToolChoice::Required
    ForceOne(name) => @moonmuse.ToolChoice::Named(name)
    _ => self.options.choice
  }
  let messages = state.messages
  let stop = self.options.stop
  let extra = self.options.extra
  match (self.options.temperature, self.options.max_tokens) {
    (Some(temperature), Some(max_tokens)) =>
      @moonmuse.Request::new(
        self.model,
        messages,
        tools~,
        choice~,
        temperature~,
        max_tokens~,
        stop~,
        extra~,
      )
    (Some(temperature), None) =>
      @moonmuse.Request::new(
        self.model,
        messages,
        tools~,
        choice~,
        temperature~,
        stop~,
        extra~,
      )
    (None, Some(max_tokens)) =>
      @moonmuse.Request::new(
        self.model,
        messages,
        tools~,
        choice~,
        max_tokens~,
        stop~,
        extra~,
      )
    (None, None) =>
      @moonmuse.Request::new(
        self.model,
        messages,
        tools~,
        choice~,
        stop~,
        extra~,
      )
  }
}

///|
/// The calls the last assistant message asked for.
fn pending_calls(state : AgentState) -> Array[@moonmuse.Part] {
  let mut index = state.messages.length() - 1
  while index >= 0 {
    let message = state.messages[index]
    if message.role is Assistant {
      return message.calls()
    }
    index = index - 1
  }
  []
}

///|
/// End the run with a recorded failure. The walk stops at the finish node and `Agent::run`
/// turns the record into the error it raises.
fn failed(reason : String) -> Array[@moonstate.Step[AgentState, Update]] {
  [
    @moonstate.Step::Write(Store(key=error_key, value=Json::string(reason))),
    @moonstate.Step::Goto(finish_node),
  ]
}

///|
/// End the run because a cap was reached, with the cap that stopped it.
fn exhausted(limit : Int32) -> Array[@moonstate.Step[AgentState, Update]] {
  [
    @moonstate.Step::Write(
      Store(
        key=error_key,
        value=Json::object(
          Map([("exhausted", Json::number(limit.to_double()))]),
        ),
      ),
    ),
    @moonstate.Step::Goto(finish_node),
  ]
}

///|
/// The run-start node.
pub async fn node_agent(
  runtime : Runtime,
  state : AgentState,
  run : @moonstate.Run,
) -> Array[@moonstate.Step[AgentState, Update]] {
  let steps : Array[@moonstate.Step[AgentState, Update]] = []
  match runtime.instructions {
    Some(instructions) =>
      if !has_system_message(state.messages) {
        let messages = [@moonmuse.Message::system(instructions)]
        for message in state.messages {
          messages.push(message)
        }
        steps.push(@moonstate.Step::Write(Replace(messages)))
      }
    None => ()
  }
  let context = runtime.context(run, state)
  for update in before_agent_hooks(runtime, context) {
    steps.push(@moonstate.Step::Write(update))
  }
  steps.push(@moonstate.Step::Goto(model_node))
  steps
}

///|
/// Whether the conversation already opens with a system message.
fn has_system_message(messages : Array[@moonmuse.Message]) -> Bool {
  for message in messages {
    if message.role is System {
      return true
    }
  }
  false
}

///|
/// The model node: one call, then route on what came back.
pub async fn node_request(
  runtime : Runtime,
  mode : RequestMode,
  state : AgentState,
  run : @moonstate.Run,
) -> Array[@moonstate.Step[AgentState, Update]] {
  if state.model_calls >= runtime.limits.iterations {
    return exhausted(runtime.limits.iterations)
  }
  let context = runtime.context(run, state)
  runtime.events.report(ModelStarted(name=runtime.name, model=runtime.model))
  let outcome = match mode {
    Choice(count) => choose_reply(runtime, context, state, mode, count)
    _ => {
      let request = runtime.request_for(mode, state)
      let call : ModelCall = { request, }
      pipeline_model(runtime, context, call, mode)
    }
  }
  match outcome {
    Replied(reply) => {
      runtime.events.report(ModelFinished(name=runtime.name, usage=reply.usage))
      let calls = reply.calls()
      let steps : Array[@moonstate.Step[AgentState, Update]] = [
        @moonstate.Step::Write(Append([reply.message])),
        @moonstate.Step::Write(Spend(model_calls=1, tool_calls=0)),
      ]
      if calls.length() > 0 {
        steps.push(@moonstate.Step::Goto(tools_node))
      } else {
        steps.push(@moonstate.Step::Goto(finish_node))
      }
      steps
    }
    Halted(text) =>
      [@moonstate.Step::Write(Answer(text)), @moonstate.Step::Goto(finish_node)]
    Failed(reason~, ..) => failed(reason)
  }
}

///|
/// Ask `count` times, then keep the candidate the agent's chooser prefers.
async fn choose_reply(
  runtime : Runtime,
  context : RunContext,
  state : AgentState,
  mode : RequestMode,
  count : Int32,
) -> ModelOutcome {
  let candidates : Array[@moonmuse.Reply] = []
  let rounds = if count > 0 { count } else { 1 }
  for _ in 0..<rounds {
    let request = runtime.request_for(RequestMode::Tools, state)
    let call : ModelCall = { request, }
    match pipeline_model(runtime, context, call, mode) {
      Replied(reply) => candidates.push(reply)
      Halted(text) => return Halted(text)
      Failed(reason~, retryable~) => return Failed(reason~, retryable~)
    }
  }
  match runtime.chooser {
    Some(chooser) => {
      let reply = chooser.choose(candidates)
      Replied(reply)
    }
    None =>
      match candidates {
        [first, ..] => Replied(first)
        [] =>
          Replied(
            @moonmuse.Reply::new(
              @moonmuse.Message::assistant(""),
              finish=@moonmuse.Finish::Stop,
            ),
          )
      }
  }
}

///|
/// The tool node: run the calls, feed the results back, and route to the next agent when a tool
/// asked for a handover.
pub async fn node_execute(
  runtime : Runtime,
  mode : ExecuteMode,
  state : AgentState,
  run : @moonstate.Run,
) -> Array[@moonstate.Step[AgentState, Update]] {
  let calls = pending_calls(state)
  let context = runtime.context(run, state)
  let results : Array[@moonmuse.Part] = []
  let mut executed = 0
  if state.tool_calls >= runtime.limits.tool_calls {
    return exhausted(runtime.limits.tool_calls)
  }
  for index, part in calls {
    let selected = match mode {
      All => true
      Single(at) => at == index
    }
    if selected {
      match part {
        @moonmuse.Part::Call(id~, name~, args~) => {
          runtime.events.report(ToolStarted(name~, call_id=id))
          let args = (runtime.events.on_tool_call_starting)(name, args)
          let call : ToolCall = {
            part: @moonmuse.Part::Call(id~, name~, args~),
          }
          let (content, failed) = match pipeline_tool(runtime, context, call) {
            Done(content) => (content, false)
            Failed(reason) => (reason, true)
          }
          let content = (runtime.events.on_tool_call_completed)(name, content)
          if failed {
            (runtime.events.on_tool_call_failed)(name, content)
          }
          runtime.events.report(ToolFinished(name~, call_id=id, failed~))
          results.push(@moonmuse.Part::result(id, content, error=failed))
          executed = executed + 1
        }
        _ => ()
      }
    }
  }
  let steps : Array[@moonstate.Step[AgentState, Update]] = [
    @moonstate.Step::Write(Append([@moonmuse.Message::new(Tool, results)])),
    @moonstate.Step::Write(Spend(model_calls=0, tool_calls=executed)),
  ]
  match runtime.exit_tool {
    Some(exit_tool) =>
      if called_tool(calls, exit_tool) {
        steps.push(@moonstate.Step::Write(Answer("Chat finished")))
        steps.push(@moonstate.Step::Goto(finish_node))
        return steps
      }
    None => ()
  }
  match state.storage.get(handoff_key) {
    Some(String(target)) => {
      runtime.events.report(HandedOver(from=runtime.name, to=target))
      steps.push(@moonstate.Step::Write(Forget(key=handoff_key)))
      steps.push(@moonstate.Step::Goto(target))
    }
    _ => steps.push(@moonstate.Step::Goto(model_node))
  }
  steps
}

///|
/// The compression node: replace older messages with a summary the model wrote.
pub async fn node_compress(
  runtime : Runtime,
  policy : HistoryPolicy,
  state : AgentState,
  run : @moonstate.Run,
) -> Array[@moonstate.Step[AgentState, Update]] {
  let context = runtime.context(run, state)
  match compress(runtime, context, state.messages, policy) {
    Done(messages) => [@moonstate.Step::Write(Replace(messages))]
    Refused(reason~) => failed(reason)
  }
}

///|
/// The run-end node: settle the answer, then let the middleware add anything it kept for the
/// end. A node with no successors ends the walk.
pub async fn node_finish(
  runtime : Runtime,
  state : AgentState,
  run : @moonstate.Run,
) -> Array[@moonstate.Step[AgentState, Update]] {
  let steps : Array[@moonstate.Step[AgentState, Update]] = [
    @moonstate.Step::Write(Answer(state.text())),
  ]
  let context = runtime.context(run, state)
  for update in after_agent_hooks(runtime, context, state) {
    steps.push(@moonstate.Step::Write(update))
  }
  steps
}

///|
/// Whether a reply asked for the named tool.
fn called_tool(calls : Array[@moonmuse.Part], name : String) -> Bool {
  for call in calls {
    match call {
      @moonmuse.Part::Call(name=requested, ..) =>
        if requested == name {
          return true
        }
      _ => ()
    }
  }
  false
}

///|
/// The reasoning node: ask the model what it has learned, without tools, and keep its answer in
/// the conversation so the next action is informed by it. Skipped on rounds that are not due.
pub async fn node_think(
  runtime : Runtime,
  state : AgentState,
  run : @moonstate.Run,
  prompt~ : String,
  every~ : Int32,
) -> Array[@moonstate.Step[AgentState, Update]] {
  let interval = if every > 0 { every } else { 1 }
  if state.model_calls % interval != 0 {
    return [@moonstate.Step::Goto(model_node)]
  }
  let context = runtime.context(run, state)
  let seeded_messages = state.messages.copy()
  seeded_messages.push(@moonmuse.Message::user(prompt))
  let seeded = { ..state, messages: seeded_messages, }
  let request = runtime.request_for(RequestMode::NoTools, seeded)
  let call : ModelCall = { request, }
  match pipeline_model(runtime, context, call, RequestMode::NoTools) {
    Replied(reply) =>
      [
        @moonstate.Step::Write(
          Append([@moonmuse.Message::user(prompt), reply.message]),
        ),
        @moonstate.Step::Write(Spend(model_calls=1, tool_calls=0)),
        @moonstate.Step::Goto(model_node),
      ]
    Halted(text) =>
      [@moonstate.Step::Write(Answer(text)), @moonstate.Step::Goto(finish_node)]
    Failed(reason~, ..) => failed(reason)
  }
}

///|
/// A node the caller registered on the runtime, by name.
pub async fn node_custom(
  runtime : Runtime,
  name : String,
  state : AgentState,
  run : @moonstate.Run,
) -> Array[@moonstate.Step[AgentState, Update]] {
  match runtime.custom.get(name) {
    Some(body) => body(state, run)
    None => failed("no node named \"" + name + "\" is registered")
  }
}
