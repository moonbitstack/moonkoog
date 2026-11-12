///|
/// A node body: what a custom position in a strategy does.
pub type NodeFn = async (Runtime, AgentState, @moonstate.Run) -> Array[
  @moonstate.Step[AgentState, Update],
]

///|
/// A node body bound to one runtime: what the graph engine calls.
type NodeBody = async (AgentState, @moonstate.Run) -> Array[
  @moonstate.Step[AgentState, Update],
]

///|
/// A strategy as data: named positions, what each one does, and the edges between them.
///
/// Keeping it data means a strategy can be inspected, compared and documented without a
/// provider in hand, and compiled against whichever runtime an agent was built with. A node
/// that decides where to go next does so by returning a `Goto`, so edges only describe the
/// fixed part of the flow.
pub(all) struct Strategy {
  name : String
  entry : String
  nodes : Array[(String, NodeKind)]
  edges : Array[(String, String)]
  limit : Int32
}

///|
/// An empty strategy starting at the agent node, with the engine's default walk limit.
pub fn Strategy::new(name : String, limit~ : Int32 = 1000) -> Strategy {
  { name, entry: agent_node, nodes: [], edges: [], limit, }
}

///|
/// Add a node.
pub fn Strategy::node(
  self : Strategy,
  name : String,
  kind : NodeKind,
) -> Strategy {
  let nodes = self.nodes.copy()
  nodes.push((name, kind))
  { ..self, nodes, }
}

///|
/// Add a fixed edge.
pub fn Strategy::edge(self : Strategy, from : String, to : String) -> Strategy {
  let edges = self.edges.copy()
  edges.push((from, to))
  { ..self, edges, }
}

///|
/// The names of the strategy's nodes, in the order they were added.
pub fn Strategy::node_names(self : Strategy) -> Array[String] {
  self.nodes.map(pair => pair.0)
}

///|
/// Compile against a runtime into the graph engine's own graph. `saver`, `store` and `executor`
/// are what the engine checkpoints through and runs nodes on; without a saver a run keeps its
/// checkpoints in memory for the length of the call.
pub fn Strategy::compile(
  self : Strategy,
  runtime : Runtime,
  saver? : &@moonstate.Saver,
  store? : &@moonstate.Store,
  executor? : &@moonstate.Executor,
) -> @moonstate.Graph[AgentState, Update] raise @moonstate.Refused {
  let names = self.node_names()
  let runtime = { ..runtime, nodes: names, }
  let builder = @moonstate.Builder::new(merge~, initial=AgentState::new())
  let mut builder = builder.entry(self.entry)
  for pair in self.nodes {
    let (name, kind) = pair
    match kind {
      Delegate(graph) =>
        builder = builder.subgraph(name, graph, enter=state => state, leave=state => {
          Adopt(state)
        })
      _ => builder = builder.node(name, node_run(runtime, kind))
    }
  }
  for pair in self.edges {
    let (from, to) = pair
    builder = builder.edge(from, to)
  }
  builder.compile(self.name, saver?, store?, executor?, limit=self.limit)
}

///|
/// The closure a node kind compiles to.
fn node_run(runtime : Runtime, kind : NodeKind) -> NodeBody {
  match kind {
    Start(then~) =>
      async fn(state, run) { node_agent(runtime, then, state, run) }
    Request(mode) =>
      async fn(state, run) { node_request(runtime, mode, state, run) }
    Turn(mode~, then~) =>
      async fn(state, run) { node_request_to(runtime, mode, then, state, run) }
    Execute(mode) =>
      async fn(state, run) { node_execute(runtime, mode, state, run) }
    Compress(policy) =>
      async fn(state, run) { node_compress(runtime, policy, state, run) }
    Finish => async fn(state, run) { node_finish(runtime, state, run) }
    Think(prompt~, every~) =>
      async fn(state, run) { node_think(runtime, prompt~, every~, state, run) }
    Advise(text) =>
      fn(_state, _run) {
        [
          @moonstate.Step::Write(Append([@moonmuse.Message::user(text)])),
          @moonstate.Step::Goto(model_node),
        ]
      }
    Custom(name) =>
      async fn(state, run) { node_custom(runtime, name, state, run) }
    // Compiled through the graph engine's own subgraph support, never as a plain node.
    Delegate(_) => fn(_state, _run) { [@moonstate.Step::Goto(finish_node)] }
  }
}

///|
/// The one-run loop: ask, run whatever was asked for, ask again until the model answers in
/// prose. This is the strategy an agent gets when nothing else is asked for.
pub fn single_run() -> Strategy {
  Strategy::new("single_run")
  .node(agent_node, Start(then=model_node))
  .edge(agent_node, model_node)
  .node(model_node, Request(Tools))
  .node(tools_node, Execute(All))
  .node(finish_node, Finish)
  .edge(model_node, tools_node)
  .edge(model_node, finish_node)
  .edge(tools_node, model_node)
  .edge(tools_node, finish_node)
}

///|
/// The chat loop: the model must call a tool rather than answer in prose, and the run ends when
/// it calls the exit tool. `exit_tool` is what the run watches for.
pub fn chat() -> Strategy {
  Strategy::new("chat")
  .node(agent_node, Start(then=model_node))
  .edge(agent_node, model_node)
  .node(model_node, Request(OnlyCalling))
  .node(tools_node, Execute(All))
  .node(finish_node, Finish)
  .edge(tools_node, model_node)
  .edge(tools_node, finish_node)
  .edge(model_node, finish_node)
}

///|
/// Reason-and-act: after each round of tools the model is asked to think about what it learned,
/// without tools in reach, before it acts again. `interval` spaces the thinking out, so a long
/// loop does not pay for a reasoning call on every round.
pub fn react(
  reasoning_prompt~ : String = "Think about what you have learned and what the next step should be.",
  interval~ : Int32 = 1,
) -> Strategy {
  Strategy::new("re_act")
  .node(agent_node, Start(then=model_node))
  .edge(agent_node, model_node)
  .node(model_node, Request(Tools))
  .node(tools_node, Execute(All))
  .node("reason", Think(prompt=reasoning_prompt, every=interval))
  .node(finish_node, Finish)
  .edge(model_node, tools_node)
  .edge(model_node, finish_node)
  .edge(tools_node, "reason")
  .edge(tools_node, finish_node)
  .edge("reason", model_node)
  .edge("reason", finish_node)
}

///|
/// A strategy with a single model call: no tools, one answer. Useful as a judge, a classifier or
/// the planner half of a plan-and-execute run.
pub fn answer_only(name~ : String = "answer") -> Strategy {
  Strategy::new(name)
  .node(agent_node, Start(then=model_node))
  .edge(agent_node, model_node)
  .node(model_node, Request(NoTools))
  .node(finish_node, Finish)
}
