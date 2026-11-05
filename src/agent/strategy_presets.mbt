///|
/// Koog's `singleRunStrategy` expressed as a graph: request the LLM; on a
/// plain-text reply finish, on a tool-call reply execute the tools, feed the
/// results back, and request again — looping until the model answers in text.
pub fn single_run_strategy(max_steps~ : Int32 = 1000) -> AIAgentStrategy {
  AIAgentStrategy::new("single_run", max_steps~)
  .node("llm_request", NodeLLMRequest)
  .node("execute_tools", NodeExecuteTools)
  .node("send_tool_result", NodeLLMSendToolResult)
  .edge(start_node, "llm_request")
  .edge("llm_request", finish_node, condition=OnAssistantMessage)
  .edge("llm_request", "execute_tools", condition=OnToolCalls)
  .edge("execute_tools", "send_tool_result")
  .edge("send_tool_result", finish_node, condition=OnAssistantMessage)
  .edge("send_tool_result", "execute_tools", condition=OnToolCalls)
}

///|
/// Koog's `chatAgentStrategy` expressed as a graph: request the LLM; a tool call is
/// executed, but a plain-text reply is nudged ("call a tool instead of chatting") and the
/// LLM re-requested until it calls a tool; the loop finishes when the model calls the exit
/// tool (`__exit__`), whose edge carries "Chat finished" as the result.
pub fn chat_agent_strategy(max_steps~ : Int32 = 1000) -> AIAgentStrategy {
  let nudge = "Don't reply with plain text. Call one of the available tools instead."
  AIAgentStrategy::new("chat", max_steps~)
  .node("llm_request", NodeLLMRequest)
  .node("feedback", NodeLLMRequestWith(nudge))
  .node("execute_tools", NodeExecuteTools)
  .node("send_tool_result", NodeLLMSendToolResult)
  .edge(start_node, "llm_request")
  .edge("llm_request", "execute_tools", condition=OnToolCalls)
  .edge("llm_request", "feedback", condition=OnAssistantMessage)
  .edge("feedback", "feedback", condition=OnAssistantMessage)
  .edge("feedback", "execute_tools", condition=OnToolCalls)
  .edge("execute_tools", "send_tool_result")
  .edge("send_tool_result", finish_node, condition=OnToolNamed("__exit__"), transform=_ => {
    VText("Chat finished")
  })
  .edge("send_tool_result", finish_node, condition=OnAssistantMessage)
  .edge("send_tool_result", "execute_tools", condition=OnToolCalls)
}

///|
/// Koog's `reActStrategy`: alternate reasoning and action. Each round reasons (a tools-off
/// request seeded with `reasoning_prompt`), then acts (a request with tools); a tool call is
/// executed and, every `reasoning_interval` rounds, the results are reasoned over before the
/// next action; a plain-text reply finishes. Built on custom nodes carrying a reasoning-step
/// counter in the session's per-run store.
pub fn react_strategy(
  reasoning_interval~ : Int32 = 1,
  reasoning_prompt~ : String = "Please give your thoughts about the task and plan the next steps.",
  max_steps~ : Int32 = 1000,
) -> AIAgentStrategy {
  let interval = if reasoning_interval > 0 { reasoning_interval } else { 1 }
  AIAgentStrategy::new("re_act", max_steps~)
  .custom_node("setup", (s, v) => {
    s.set("step", 0)
    v
  })
  .custom_node("reason_input", (s, v) => {
    s.append_user(v.text())
    s.append_user(reasoning_prompt)
    s.append(s.request_llm_no_tools())
    VUnit
  })
  .custom_node("call_llm", (s, _v) => VReply(s.request_llm()))
  .node("execute_tools", NodeExecuteTools)
  .custom_node("reason_after", (s, _v) => {
    let step = match s.get("step") {
      Some(n) => n
      None => 0
    }
    if step % interval == 0 {
      s.append_user(reasoning_prompt)
      s.append(s.request_llm_no_tools())
    }
    s.set("step", step + 1)
    VUnit
  })
  .edge(start_node, "setup")
  .edge("setup", "reason_input")
  .edge("reason_input", "call_llm")
  .edge("call_llm", "execute_tools", condition=OnToolCalls)
  .edge("call_llm", finish_node, condition=OnAssistantMessage)
  .edge("execute_tools", "reason_after")
  .edge("reason_after", "call_llm")
}

///|
/// Take one LLM call out of the run's budget, refusing past the agent's `max_iterations`
/// (Koog's iteration cap).
fn charge_llm(ctx : StrategyContext) -> Unit raise AgentError {
  guard ctx.llm_calls.val < ctx.max_iterations else {
    raise AgentError(
      "max iterations (" + ctx.max_iterations.to_string() + ") exceeded",
    )
  }
  ctx.llm_calls.val = ctx.llm_calls.val + 1
}

///|
/// The session a custom node runs against (Koog's `AIAgentLLMWriteSession` receiver): the
/// request/append/storage operations a node closure needs, without exposing the whole
/// context. This is the MoonBit stand-in for Kotlin's receiver-lambda node DSL.
pub struct NodeSession {
  ctx : StrategyContext
}

///|
/// Append a user message to the conversation.
pub fn NodeSession::append_user(self : NodeSession, text : String) -> Unit {
  self.ctx.prompt = self.ctx.prompt.append(@moonmuse.Message::user(text))
}

///|
/// Append a ready message to the conversation.
pub fn NodeSession::append(
  self : NodeSession,
  message : @moonmuse.Message,
) -> Unit {
  self.ctx.prompt = self.ctx.prompt.append(message)
}

///|
/// Send `prompt` to the run's executor advertising `tools`, through the run's LLM
/// interceptors: the before-hook decides what is actually sent — the run's own conversation is
/// left as it is — and the after-hook what the graph goes on with.
async fn call_llm(
  ctx : StrategyContext,
  prompt : @moonmuse.Prompt,
  tools : Array[@toolbox.ToolDescriptor],
) -> @moonmuse.Message {
  let ask = (ctx.events.on_llm_call_starting)(prompt)
  let reply = ctx.executor.execute(prompt=ask, model=ctx.model, tools~)
  (ctx.events.on_llm_call_completed)(reply)
}

///|
/// Request the model with the advertised tools (Koog `requestLLM`).
pub async fn NodeSession::request_llm(self : NodeSession) -> @moonmuse.Message {
  call_llm(self.ctx, self.ctx.prompt, self.ctx.descriptors)
}

///|
/// Request the model with no tools — a reasoning step (Koog `requestLLMWithoutTools`).
pub async fn NodeSession::request_llm_no_tools(
  self : NodeSession,
) -> @moonmuse.Message {
  call_llm(self.ctx, self.ctx.prompt, [])
}

///|
/// The run's `AIAgentStorage` — what a node reaches for when it wants the whole store rather
/// than one entry (`contains`, `remove`, a snapshot).
pub fn NodeSession::storage(self : NodeSession) -> AgentStorage {
  self.ctx.storage
}

///|
/// Read the value stored under `key` at the type the call site asks for; `None` when the key
/// is unset or its Json does not decode to that type.
pub fn[T : @json.FromJson] NodeSession::get(
  self : NodeSession,
  key : String,
) -> T? {
  self.ctx.storage.get(key)
}

///|
/// Store any `ToJson` value under `key`, replacing what was there.
pub fn[T : ToJson] NodeSession::set(
  self : NodeSession,
  key : String,
  value : T,
) -> Unit {
  self.ctx.storage.set(key, value)
}

///|
/// The names of the tools advertised to the model.
pub fn NodeSession::tool_names(self : NodeSession) -> Array[String] {
  self.ctx.descriptors.map(d => d.name)
}

///|
/// Run `strategy` on `input`, returning the finish node's text. Seeds the prompt with the
/// agent's `params` and system message, then walks the graph. LLM requests are bounded
/// by the agent's `max_iterations` (Koog's iteration cap) across the whole run,
/// nested subgraphs and parallel branches included; node visits by each strategy's
/// `max_steps`.
///
/// With `checkpoints`, every top-level node boundary is snapshotted into the given store
/// before the node runs. Passing one of those snapshots back as `resume_from` replays its
/// conversation, storage and spent-iteration count and re-enters the walk at the node it was
/// taken before, so a run picks up where it stopped instead of starting over; `input` is then
/// unused, the value in flight coming from the checkpoint.
pub async fn AIAgent::run_strategy(
  self : AIAgent,
  strategy : AIAgentStrategy,
  input : String,
  stop? : RunHandle,
  checkpoints? : Checkpointer,
  resume_from? : AgentCheckpoint,
) -> String {
  let storage = AgentStorage::new()
  let (prompt, at, value, spent) = match resume_from {
    Some(cp) => {
      storage.restore(cp.storage)
      let prompt : @moonmuse.Prompt = {
        messages: [..cp.message_history],
        id: "prompt",
        params: cp.llm_params.unwrap_or(self.params),
      }
      let value = match cp.last_input {
        Some(json) => NodeValue::from_json(json)
        None => VUnit
      }
      (prompt, Some(cp.node_id), value, cp.agent_iterations)
    }
    None => {
      let builder = @moonmuse.PromptBuilder::new(params=self.params)
      if self.system_prompt is Some(sp) {
        builder.system(sp) |> ignore
      }
      (builder.build(), None, VText(input), 0)
    }
  }
  let ctx : StrategyContext = {
    executor: self.executor,
    model: self.model,
    tool_registry: self.tool_registry,
    prompt,
    descriptors: self.tool_registry.descriptors(),
    events: self.events,
    storage,
    llm_calls: Ref(spent),
    max_iterations: self.max_iterations,
    stop,
    checkpoint: checkpoints,
  }
  (self.events.on_agent_starting)(input)
  (self.events.on_strategy_starting)(strategy.name)
  let walked = Ok(run_graph(ctx, strategy, value, at?, top=true)) catch {
    e => Err(e)
  }
  let result = match walked {
    Ok(v) => v.text()
    Err(e) => {
      (self.events.on_agent_execution_failed)(error_text(e))
      raise e
    }
  }
  (self.events.on_strategy_completed)(strategy.name, result)
  (self.events.on_agent_completed)(result)
  result
}

