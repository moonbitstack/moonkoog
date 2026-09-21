///|
/// Koog's agent strategy as a directed graph of nodes joined by conditional
/// edges. `AIAgent.run`'s tool-calling loop is not special-cased — it is one
/// wiring of this graph (`single_run_strategy` below), the way Koog builds
/// `singleRunStrategy` from the same `strategy { ... }` DSL. A run threads a
/// value from the start node along the first outgoing edge whose condition holds,
/// node to node, until it reaches the finish node.
///
/// Koog's nodes are statically typed on their input/output; MoonBit has no per-node
/// generics across a heterogeneous graph, so the value in flight is the `NodeValue`
/// sum and the standard node behaviours are named `NodeKind`s. Arbitrary nodes are
/// `NodeCustom` handlers run against a `NodeSession` — the MoonBit-idiomatic stand-in
/// for Kotlin's receiver-lambda node DSL. Edge conditions and edge transforms take
/// arbitrary functions, as Koog's `onCondition { }` and `transformed { }` do.
///
/// A whole strategy nests as one node (`NodeSubgraph`, Koog's `subgraph`), with a
/// retrying form (`NodeSubgraphRetry`, Koog's `SubgraphWithRetry`), and several nodes
/// run at once and merge (`NodeParallel`, Koog's `parallel`).
/// Source: agents/agents-core/.../agent/entity/{AIAgentStrategy,AIAgentNode,
/// AIAgentEdge}.kt and AIAgentSimpleStrategies.kt (`singleRunStrategy`).

///|
/// The value passed between strategy nodes: the text that enters at the start and
/// leaves at the finish, an LLM assistant reply, the JSON a structured request
/// parsed, a moderation verdict, or a bare token from a node whose effect is on the
/// conversation (tools executed) rather than on a carried value.
pub(all) enum NodeValue {
  VText(String)
  VReply(@prompt.Message)
  VJson(Json)
  VModeration(ModerationResult)
  VUnit
} derive(Eq, Debug)

///|
/// The text a `NodeValue` carries: the raw text, an assistant reply's text, the JSON
/// re-serialized, a moderation verdict as `harmful` / `safe`, or empty.
pub fn NodeValue::text(self : NodeValue) -> String {
  match self {
    VText(s) => s
    VReply(m) => m.text_content()
    VJson(j) => j.stringify()
    VModeration(r) => if r.is_harmful { "harmful" } else { "safe" }
    VUnit => ""
  }
}

///|
/// The value as Json, tagged by variant, so a checkpoint can carry what was in flight
/// between two nodes.
pub fn NodeValue::to_json(self : NodeValue) -> Json {
  match self {
    VText(s) => { "kind": "text", "value": s.to_json() }
    VReply(m) => { "kind": "reply", "value": m.to_json() }
    VJson(j) => { "kind": "json", "value": j }
    VModeration(r) => { "kind": "moderation", "value": ToJson::to_json(r) }
    VUnit => { "kind": "unit" }
  }
}

///|
/// Read back a value written by `to_json`. Raises `AgentError` on a tag or payload that does
/// not belong to a `NodeValue` — a checkpoint that cannot be decoded cannot be resumed from,
/// and saying so beats resuming at the right node with the wrong value.
pub fn NodeValue::from_json(json : Json) -> NodeValue raise AgentError {
  guard json is Object(fields) else {
    raise AgentError("checkpoint value is not a JSON object")
  }
  guard fields.get("kind") is Some(String(kind)) else {
    raise AgentError("checkpoint value has no 'kind'")
  }
  let payload = fields.get("value").unwrap_or(Json::null())
  match kind {
    "unit" => VUnit
    "json" => VJson(payload)
    "text" =>
      match payload {
        String(s) => VText(s)
        _ => raise AgentError("checkpoint text value is not a string")
      }
    "reply" =>
      VReply(@json.from_json(payload)) catch {
        _ => raise AgentError("checkpoint reply value is not a message")
      }
    "moderation" =>
      VModeration(@json.from_json(payload)) catch {
        _ => raise AgentError("checkpoint moderation value is not a verdict")
      }
    _ => raise AgentError("unknown checkpoint value kind '" + kind + "'")
  }
}

///|
/// A standard node's behaviour (Koog's `nodeStart` / `nodeFinish` /
/// `nodeLLMRequest` / `nodeExecuteTool` / `nodeLLMSendToolResult`).
/// `NodeExecuteTools` runs every tool call in the reply (Koog's multiple-tool
/// variant), matching the conversation the loop builds.
pub(all) enum NodeKind {
  NodeStart
  NodeFinish
  NodeLLMRequest
  NodeExecuteTools
  NodeLLMSendToolResult
  // A parametrized LLM request that first appends a fixed instruction (Koog's custom
  // `node { ... appendPrompt { user(...) }; requestLLM() }` — e.g. the chat strategy's
  // "call a tool instead of chatting" nudge), then requests the model.
  NodeLLMRequestWith(String)
  // A node whose behaviour is an arbitrary handler registered by name (Koog's fully
  // general `node<In, Out> { ... }`). The handler runs against a `NodeSession` — the
  // MoonBit-idiomatic stand-in for Kotlin's receiver-lambda session, giving closures the
  // request/append/storage operations a custom node needs (e.g. reAct's reasoning steps).
  NodeCustom(String)
  // A whole strategy nested as one node (Koog's `subgraph`): its graph is walked with the
  // same conversation, tool registry and budgets, and its finish value is this node's output.
  NodeSubgraph(AIAgentStrategy)
  // A subgraph re-run until `until` accepts its result, at most `max_retries` extra times
  // (Koog's `SubgraphWithRetry`). Attempts share the conversation, so a retry sees what the
  // failed one produced; the last attempt's value is the output when none is accepted.
  NodeSubgraphRetry(
    AIAgentStrategy,
    until~ : (NodeValue) -> Bool,
    max_retries~ : Int
  )
  // Several of this strategy's nodes run at once on the same input, their results merged
  // into one value (Koog's `parallel`). Each branch runs on a forked conversation so the
  // branches cannot interleave into one another's prompt; the parent's conversation is
  // unchanged and the merged value is what flows on.
  NodeParallel(Array[String], merge~ : (Array[NodeValue]) -> NodeValue)
  // Ask the provider for `choices` candidate replies (`execute_multiple`, Koog
  // `executeMultipleChoices`) and pick one with a `ChoiceSelectionStrategy`.
  NodeLLMRequestMultiple(&ChoiceSelectionStrategy, choices~ : Int)
  // Run the conversation so far through the provider's safety endpoint
  // (`LLMClient.moderate`), carrying the verdict on as a `VModeration`.
  NodeModerate
  // Request the model with the reply streamed, handing each incremental text delta to
  // `on_chunk` as it arrives (`execute_streaming`, Koog `LLMClient.executeStreaming`).
  NodeLLMRequestStreaming((String) -> Unit)
  // Request a reply constrained to a schema and carry the parsed JSON on as a `VJson`
  // (Koog `requestLLMStructured`). A reply that does not parse is re-asked up to `fixes`
  // times, Koog's `StructureFixingParser`.
  NodeLLMRequestStructured(StructuredSchema[Json], fixes~ : Int)
}

///|
/// When an edge fires, tested against the source node's output. `Always` is an
/// unconditional edge; `OnAssistantMessage` fires on a plain-text reply (no tool
/// calls); `OnToolCalls` fires on a reply that requests tools; `OnPredicate` fires
/// on any test of the value at all. Koog's `onCondition` / `onAssistantMessage` /
/// `onToolCall`.
pub(all) enum EdgeCondition {
  Always
  OnAssistantMessage
  OnToolCalls
  OnToolNamed(String)
  OnPredicate((NodeValue) -> Bool)
}

///|
/// A directed edge `from -> to` that fires when `condition` holds.
pub(all) struct StrategyEdge {
  from : String
  to : String
  condition : EdgeCondition
  // When set, the value carried to `to` is what this returns for the source node's output
  // (Koog's edge `transformed { ... }`) — e.g. the chat strategy finishing on the exit tool
  // with "Chat finished" rather than the tool call. Synchronous: a step that has to reach
  // the model is a node, not an edge.
  transform : ((NodeValue) -> NodeValue)?
}

///|
/// A strategy graph: named nodes, edges between them, and the start / finish node
/// names. `max_steps` bounds node visits, a backstop against a cyclic graph that
/// never reaches finish (the per-agent `max_iterations` bounds LLM calls).
pub struct AIAgentStrategy {
  name : String
  nodes : Map[String, NodeKind]
  edges : Array[StrategyEdge]
  // Handlers for `NodeCustom` nodes, keyed by node name.
  custom : Map[String, async (NodeSession, NodeValue) -> NodeValue]
  start : String
  finish : String
  max_steps : Int
}

///|
/// The canonical start / finish node names.
pub let start_node : String = "__start__"

///|
pub let finish_node : String = "__finish__"

///|
/// A strategy seeded with the start and finish nodes, ready to have nodes and
/// edges added. `max_steps` defaults to a generous backstop.
pub fn AIAgentStrategy::new(
  name : String,
  max_steps? : Int = 1000,
) -> AIAgentStrategy {
  {
    name,
    nodes: Map([(start_node, NodeStart), (finish_node, NodeFinish)]),
    edges: [],
    custom: Map([]),
    start: start_node,
    finish: finish_node,
    max_steps,
  }
}

///|
/// Add a named node, returning the strategy so calls chain.
pub fn AIAgentStrategy::node(
  self : AIAgentStrategy,
  name : String,
  kind : NodeKind,
) -> AIAgentStrategy {
  self.nodes[name] = kind
  self
}

///|
/// Add a custom node `name` whose behaviour is `handler` — an arbitrary step run against a
/// `NodeSession` (Koog's `node<In, Out> { ... }`). Returns the strategy so calls chain.
pub fn AIAgentStrategy::custom_node(
  self : AIAgentStrategy,
  name : String,
  handler : async (NodeSession, NodeValue) -> NodeValue,
) -> AIAgentStrategy {
  self.nodes[name] = NodeCustom(name)
  self.custom[name] = handler
  self
}

///|
/// Add node `name` that runs the whole of `strategy` and carries its finish value on
/// (Koog's `subgraph`). Returns the strategy so calls chain.
pub fn AIAgentStrategy::subgraph(
  self : AIAgentStrategy,
  name : String,
  strategy : AIAgentStrategy,
) -> AIAgentStrategy {
  self.nodes[name] = NodeSubgraph(strategy)
  self
}

///|
/// Add node `name` that runs `strategy` and re-runs it while `until` rejects the result,
/// at most `max_retries` extra times (Koog's `SubgraphWithRetry`). Returns the strategy so
/// calls chain.
pub fn AIAgentStrategy::subgraph_retry(
  self : AIAgentStrategy,
  name : String,
  strategy : AIAgentStrategy,
  until~ : (NodeValue) -> Bool,
  max_retries? : Int = 2,
) -> AIAgentStrategy {
  self.nodes[name] = NodeSubgraphRetry(strategy, until~, max_retries~)
  self
}

///|
/// Add node `name` that runs every node in `nodes` at once on the same input and hands
/// their results, in that order, to `merge` (Koog's `parallel`). Returns the strategy so
/// calls chain.
pub fn AIAgentStrategy::parallel(
  self : AIAgentStrategy,
  name : String,
  nodes : Array[String],
  merge~ : (Array[NodeValue]) -> NodeValue,
) -> AIAgentStrategy {
  self.nodes[name] = NodeParallel(nodes, merge~)
  self
}

///|
/// Add an edge `from -> to` firing on `condition` (unconditional by default),
/// returning the strategy so calls chain. `transform` rewrites the value the next
/// node sees.
pub fn AIAgentStrategy::edge(
  self : AIAgentStrategy,
  from : String,
  to : String,
  condition? : EdgeCondition = Always,
  transform? : (NodeValue) -> NodeValue,
) -> AIAgentStrategy {
  self.edges.push({ from, to, condition, transform, })
  self
}

///|
/// Koog's `singleRunStrategy` expressed as a graph: request the LLM; on a
/// plain-text reply finish, on a tool-call reply execute the tools, feed the
/// results back, and request again — looping until the model answers in text.
pub fn single_run_strategy(max_steps? : Int = 1000) -> AIAgentStrategy {
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
pub fn chat_agent_strategy(max_steps? : Int = 1000) -> AIAgentStrategy {
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
  reasoning_interval? : Int = 1,
  reasoning_prompt? : String = "Please give your thoughts about the task and plan the next steps.",
  max_steps? : Int = 1000,
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
/// The mutable run context threaded through the nodes: the executor + model to
/// call, the tool registry to dispatch to, the growing prompt, and the tool
/// descriptors advertised on every request.
struct StrategyContext {
  executor : &LLMClient
  model : @llm.LLModel
  tool_registry : @tools.ToolRegistry
  mut prompt : @prompt.Prompt
  descriptors : Array[@tools.ToolDescriptor]
  events : EventHandler
  // The per-run `AIAgentStorage` custom nodes carry state through: any `ToJson` value, not
  // just the counters reAct needs.
  storage : AgentStorage
  // The LLM-call budget. A cell rather than a field so a forked branch and every nested
  // subgraph spend the one budget the agent was given, not a copy each.
  llm_calls : Ref[Int]
  max_iterations : Int
  stop : RunHandle?
  checkpoint : Checkpointer?
}

///|
/// A branch context: its own conversation and per-run store, sharing the budget, so
/// parallel branches cannot interleave into one another's prompt.
fn StrategyContext::fork(self : StrategyContext) -> StrategyContext {
  let storage = AgentStorage::new()
  storage.restore(self.storage.snapshot())
  { ..self, storage, }
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
  self.ctx.prompt = self.ctx.prompt.append(@prompt.Message::user(text))
}

///|
/// Append a ready message to the conversation.
pub fn NodeSession::append(
  self : NodeSession,
  message : @prompt.Message,
) -> Unit {
  self.ctx.prompt = self.ctx.prompt.append(message)
}

///|
/// Send `prompt` to the run's executor advertising `tools`, through the run's LLM
/// interceptors: the before-hook decides what is actually sent — the run's own conversation is
/// left as it is — and the after-hook what the graph goes on with.
async fn call_llm(
  ctx : StrategyContext,
  prompt : @prompt.Prompt,
  tools : Array[@tools.ToolDescriptor],
) -> @prompt.Message {
  let ask = (ctx.events.on_llm_call_starting)(prompt)
  let reply = ctx.executor.execute(prompt=ask, model=ctx.model, tools~)
  (ctx.events.on_llm_call_completed)(reply)
}

///|
/// Request the model with the advertised tools (Koog `requestLLM`).
pub async fn NodeSession::request_llm(self : NodeSession) -> @prompt.Message {
  call_llm(self.ctx, self.ctx.prompt, self.ctx.descriptors)
}

///|
/// Request the model with no tools — a reasoning step (Koog `requestLLMWithoutTools`).
pub async fn NodeSession::request_llm_no_tools(
  self : NodeSession,
) -> @prompt.Message {
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
/// Whether `condition` holds for `value`.
fn edge_matches(condition : EdgeCondition, value : NodeValue) -> Bool {
  match condition {
    Always => true
    OnAssistantMessage =>
      match value {
        VReply(m) => m.tool_calls().is_empty()
        _ => false
      }
    OnToolCalls =>
      match value {
        VReply(m) => !m.tool_calls().is_empty()
        _ => false
      }
    OnToolNamed(name) =>
      match value {
        VReply(m) => {
          let mut found = false
          for part in m.tool_calls() {
            if part is @prompt.ToolCall(tool~, ..) && tool == name {
              found = true
            }
          }
          found
        }
        _ => false
      }
    OnPredicate(holds) => holds(value)
  }
}

///|
/// What is wrong with `args` for the tool `descriptor` describes, or `None` when the call may
/// proceed. Koog decodes a tool call's arguments into the tool's typed argument class and reports
/// a decode failure as a validation failure; with no reflection here, the descriptor's required
/// parameters are what there is to check against. A tool that requires nothing rules out nothing,
/// so its arguments are taken as they come.
fn missing_argument(descriptor : @tools.ToolDescriptor, args : Json) -> String? {
  guard !descriptor.required_parameters.is_empty() else { return None }
  guard args is Object(fields) else {
    return Some("arguments for '" + descriptor.name + "' are not a JSON object")
  }
  for p in descriptor.required_parameters {
    if fields.get(p.name) is None {
      return Some(
        "missing required parameter '" +
        p.name +
        "' for '" +
        descriptor.name +
        "'",
      )
    }
  }
  None
}

///|
/// Run one node against the context, returning its output value. `strategy` is the graph
/// the node belongs to — a subgraph node is dispatched against its own.
async fn run_node(
  ctx : StrategyContext,
  strategy : AIAgentStrategy,
  kind : NodeKind,
  value : NodeValue,
) -> NodeValue {
  match kind {
    NodeStart => value
    NodeFinish => value
    NodeLLMRequest => {
      let input = value.text()
      ctx.prompt = ctx.prompt.append(@prompt.Message::user(input))
      charge_llm(ctx)
      VReply(call_llm(ctx, ctx.prompt, ctx.descriptors))
    }
    NodeExecuteTools => {
      guard value is VReply(reply) else { return VUnit }
      ctx.prompt = ctx.prompt.append(reply)
      for call in reply.tool_calls() {
        guard call is @prompt.ToolCall(id~, tool~, args~) else { continue }
        let args = (ctx.events.on_tool_call_starting)(tool, args)
        // A tool that failed has to say so on the result, not just put its message
        // in the text: the model reads `is_error` to decide whether to try again.
        let (output, failed) = match ctx.tool_registry.get_tool(tool) {
          None => {
            let reason = "unknown tool: " + tool
            (ctx.events.on_tool_call_failed)(tool, reason)
            (reason, true)
          }
          Some(t) =>
            match missing_argument(t.descriptor(), args) {
              Some(reason) => {
                (ctx.events.on_tool_validation_failed)(tool, args, reason)
                (reason, true)
              }
              None =>
                (t.execute_raw(args), false) catch {
                  e => {
                    let reason = "tool error: " + error_text(e)
                    (ctx.events.on_tool_call_failed)(tool, reason)
                    (reason, true)
                  }
                }
            }
        }
        let output = (ctx.events.on_tool_call_completed)(tool, output)
        ctx.prompt = ctx.prompt.append(
          @prompt.Message::tool_result(tool~, output~, id?, is_error=failed),
        )
      }
      VUnit
    }
    NodeLLMSendToolResult => {
      charge_llm(ctx)
      VReply(call_llm(ctx, ctx.prompt, ctx.descriptors))
    }
    NodeLLMRequestWith(instruction) => {
      // Keep the previous reply in the conversation, then nudge and re-request.
      if value is VReply(prev) {
        ctx.prompt = ctx.prompt.append(prev)
      }
      ctx.prompt = ctx.prompt.append(@prompt.Message::user(instruction))
      charge_llm(ctx)
      VReply(call_llm(ctx, ctx.prompt, ctx.descriptors))
    }
    NodeCustom(key) =>
      match strategy.custom.get(key) {
        Some(handler) => handler({ ctx, }, value)
        None => value
      }
    NodeSubgraph(sub) => {
      (ctx.events.on_subgraph_execution_starting)(sub.name)
      let out = run_graph(ctx, sub, value)
      (ctx.events.on_subgraph_execution_completed)(sub.name, out.text())
      out
    }
    NodeSubgraphRetry(sub, until~, max_retries~) => {
      (ctx.events.on_subgraph_execution_starting)(sub.name)
      let mut out = run_graph(ctx, sub, value)
      let mut left = max_retries
      while left > 0 && !until(out) {
        out = run_graph(ctx, sub, value)
        left = left - 1
      }
      // Once, on the attempt that was kept: the discarded attempts are the retry's business,
      // not a caller counting subgraph runs.
      (ctx.events.on_subgraph_execution_completed)(sub.name, out.text())
      out
    }
    NodeParallel(names, merge~) => {
      let branches : Array[async () -> Result[NodeValue, Error]] = []
      for name in names {
        guard strategy.nodes.get(name) is Some(branch) else {
          raise AgentError("parallel branch names no node '" + name + "'")
        }
        let ctx = ctx.fork()
        branches.push(() => {
          Ok(run_node(ctx, strategy, branch, value)) catch {
            e => Err(e)
          }
        })
      }
      let results = []
      for result in @async.all(branches[:]) {
        match result {
          Ok(v) => results.push(v)
          Err(e) => raise e
        }
      }
      merge(results)
    }
    NodeLLMRequestMultiple(selector, choices~) => {
      ctx.prompt = ctx.prompt.append(@prompt.Message::user(value.text()))
      // The candidate count rides on the prompt, which is where the provider reads it.
      let ask = {
        ..ctx.prompt,
        params: { ..ctx.prompt.params, number_of_choices: Some(choices), },
      }
      charge_llm(ctx)
      let ask = (ctx.events.on_llm_call_starting)(ask)
      let candidates = ctx.executor.execute_multiple(
        prompt=ask,
        model=ctx.model,
        tools=ctx.descriptors,
      )
      let picked = selector.choose(ask, candidates)
      VReply((ctx.events.on_llm_call_completed)(picked))
    }
    NodeModerate =>
      VModeration(ctx.executor.moderate(prompt=ctx.prompt, model=ctx.model))
    NodeLLMRequestStreaming(on_chunk) => {
      ctx.prompt = ctx.prompt.append(@prompt.Message::user(value.text()))
      charge_llm(ctx)
      // A streamed call goes through the LLM interceptors too, so a prompt rewrite installed
      // once holds whether or not the node happens to stream.
      let ask = (ctx.events.on_llm_call_starting)(ctx.prompt)
      (ctx.events.on_llm_streaming_starting)(ask)
      let reply = ctx.executor.execute_streaming(
        prompt=ask,
        model=ctx.model,
        tools=ctx.descriptors,
        on_chunk=chunk => {
          (ctx.events.on_llm_streaming_frame)(chunk)
          on_chunk(chunk)
        },
      )
      (ctx.events.on_llm_streaming_completed)(reply)
      VReply((ctx.events.on_llm_call_completed)(reply))
    }
    NodeLLMRequestStructured(schema, fixes~) => {
      ctx.prompt = {
        ..ctx.prompt,
        params: with_schema(ctx.prompt.params, ctx.model, schema),
      }
      ctx.prompt = ctx.prompt.append(@prompt.Message::user(value.text()))
      ctx.prompt = ctx.prompt.append(
        @prompt.Message::user(schema_instruction(schema)),
      )
      for attempt = 0; attempt <= fixes; attempt = attempt + 1 {
        charge_llm(ctx)
        let reply = call_llm(ctx, ctx.prompt, ctx.descriptors)
        let text = reply.text_content()
        let parsed = if extract_json_object(text) is Some(js) {
          (schema.parse)(@json.parse(js) catch { _ => Json::null() })
        } else {
          None
        }
        if parsed is Some(value) {
          return VJson(value)
        }
        ctx.prompt = ctx.prompt.append(reply)
        ctx.prompt = ctx.prompt.append(@prompt.Message::user(fix_instruction))
      }
      raise AgentError(
        "no valid structured response after " +
        (fixes + 1).to_string() +
        " attempts",
      )
    }
  }
}

///|
/// Run one node with the run's node hooks around it: started, then either completed or failed
/// with the error that is about to end the run. The error carries on unchanged — the hook
/// watches, it does not recover.
async fn run_node_hooked(
  ctx : StrategyContext,
  strategy : AIAgentStrategy,
  name : String,
  kind : NodeKind,
  value : NodeValue,
) -> NodeValue {
  (ctx.events.on_node_execution_starting)(name)
  let out = Ok(run_node(ctx, strategy, kind, value)) catch { e => Err(e) }
  match out {
    Ok(v) => {
      (ctx.events.on_node_execution_completed)(name)
      v
    }
    Err(e) => {
      (ctx.events.on_node_execution_failed)(name, error_text(e))
      raise e
    }
  }
}

///|
/// File a checkpoint for the node `node` that is about to run on `value` — everything a resume
/// needs: the conversation, the LLM configuration behind it, the serialized storage, the graph
/// position and the LLM calls already spent. Resuming re-runs `node` on `value`, so the
/// snapshot is taken before the node, never after.
fn snapshot(
  ctx : StrategyContext,
  cp : Checkpointer,
  node : String,
  value : NodeValue,
) -> Unit {
  let created_at = cp.now()
  cp.store.save_checkpoint(
    cp.session,
    @persistence.AgentCheckpoint::new(
      checkpoint_id="cp-" + cp.seq.to_string(),
      created_at~,
      node_id=node,
      message_history=[..ctx.prompt.messages],
      llm_params=ctx.prompt.params,
      llm_model=ctx.model,
      tools=ctx.descriptors.map(d => d.name),
      storage=ctx.storage.snapshot(),
      last_input=value.to_json(),
      agent_iterations=ctx.llm_calls.val,
    ),
  )
  cp.seq = cp.seq + 1
}

///|
/// Walk `strategy` from `at` (its start node by default) on `input` and return the finish
/// node's value: run the current node, follow the first outgoing edge whose condition holds,
/// stop at finish. Recursive — a subgraph node walks its own graph through this same function,
/// against the same context. Node visits are bounded by the strategy's `max_steps`; a
/// stop asked for through the run's `RunHandle` is honoured between nodes, so the node
/// in progress always finishes.
///
/// `top` marks the run's own graph. Only its boundaries are checkpointed: a node name is only
/// meaningful inside the graph that declares it, and a resume re-enters the top-level walk.
async fn run_graph(
  ctx : StrategyContext,
  strategy : AIAgentStrategy,
  input : NodeValue,
  at? : String,
  top? : Bool = false,
) -> NodeValue {
  for step = 0, current = at.unwrap_or(strategy.start), value = input; step <
     strategy.max_steps; {
    if ctx.stop is Some(handle) && handle.stopping {
      raise AgentStopped(value.text())
    }
    guard strategy.nodes.get(current) is Some(kind) else {
      raise AgentError("strategy has no node named '" + current + "'")
    }
    if top && ctx.checkpoint is Some(cp) {
      snapshot(ctx, cp, current, value)
    }
    let out = run_node_hooked(ctx, strategy, current, kind, value)
    if current == strategy.finish {
      return out
    }
    guard strategy.edges
      .iter()
      .find_first(e => e.from == current && edge_matches(e.condition, out))
      is Some(edge) else {
      raise AgentError("no edge out of '" + current + "' matched")
    }
    let carried = match edge.transform {
      Some(rewrite) => rewrite(out)
      None => out
    }
    continue step + 1, edge.to, carried
  }
  raise AgentError(
    "strategy '" +
    strategy.name +
    "' exceeded " +
    strategy.max_steps.to_string() +
    " node steps",
  )
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
      let prompt : @prompt.Prompt = {
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
      let builder = @prompt.PromptBuilder::new(params=self.params)
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

///|
pub extend NodeValue with Debug::{to_repr}

///|
pub extend NodeValue with Eq::{not_equal, equal}
