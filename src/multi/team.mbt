///|
/// The node a team's router lives on.
pub let route_node : String = "route"

///|
/// The tool a peer calls to pass the conversation to another peer.
pub let handoff_tool_name : String = "handoff"

///|
/// A tool that hands the conversation to another peer of the team.
///
/// The tool records the destination in the run's state rather than jumping: the peer's own
/// graph has no node for an agent outside it, so it ends its turn and the team's router reads the
/// marker. That is what makes a handover work across a graph boundary, and it is why a peer
/// does not need to know how the team is wired.
pub fn handoff_tool(targets : Array[String]) -> @agent.ToolSpec {
  let names : Array[Json] = []
  for target in targets {
    names.push(Json::string(target))
  }
  @agent.ToolSpec::new(
    name=handoff_tool_name,
    description="Hand the conversation to another agent. Name the agent in `to`.",
    schema=Json::object(
      Map([
        ("type", Json::string("object")),
        (
          "properties",
          Json::object(
            Map([
              (
                "to",
                Json::object(
                  Map([
                    ("type", Json::string("string")),
                    ("enum", Json::array(names)),
                  ]),
                ),
              ),
              ("reason", Json::object(Map([("type", Json::string("string"))]))),
            ]),
          ),
        ),
        ("required", Json::array([Json::string("to")])),
      ]),
    ),
    run=fn(args, context) {
      let target = match args {
        Object(fields) =>
          match fields.get("to") {
            Some(String(target)) => target
            _ => ""
          }
        _ => ""
      }
      guard target != "" else { return "error: no agent was named" }
      guard targets.contains(target) else {
        return "error: there is no agent named " + target
      }
      context.handover.val = Some(target)
      context.pending.push(
        @agent.Store(key=@agent.handoff_key, value=Json::string(target)),
      )
      "handing over to " + target
    },
  )
}

///|
/// Whether the run recorded a handover that has not been followed yet.
fn handoff_target(state : @agent.AgentState) -> String? {
  match state.storage.get(@agent.handoff_key) {
    Some(String(target)) => Some(target)
    _ => None
  }
}

///|
/// The router's decision: hand the conversation to the peer a tool named, clearing the marker
/// so the same handover is not followed twice, or stop when nobody asked for it.
fn route_after(
  runtime : @agent.Runtime,
  state : @agent.AgentState,
) -> Array[@moonstate.Step[@agent.AgentState, @agent.Update]] {
  match handoff_target(state) {
    Some(target) =>
      if runtime.has_node(target) && target != route_node {
        [
          @moonstate.Step::Write(@agent.Forget(key=@agent.handoff_key)),
          @moonstate.Step::Goto(target),
        ]
      } else {
        [@moonstate.Step::Goto(@agent.finish_node)]
      }
    None => [@moonstate.Step::Goto(@agent.finish_node)]
  }
}

///|
/// A team whose members hand the conversation to each other through the handoff tool.
///
/// Each peer runs as a nested graph over the same conversation, so a peer sees what the ones
/// before it said. The run starts with the first peer and ends when a peer answers without
/// handing over. Nothing decides the order but the members themselves, which is what makes a
/// swarm different from a supervisor.
pub fn swarm(
  config : @agent.AgentConfig,
  members : Array[@agent.Agent],
) -> @agent.AgentConfig {
  guard members.length() > 0 else {
    return config.with_strategy(@agent.answer_only())
  }
  let first = members[0].name()
  let mut strategy = @agent.Strategy::new("swarm")
    .node(@agent.agent_node, @agent.Start(then=first))
    .edge(@agent.agent_node, first)
  for peer in members {
    strategy = strategy
      .node(peer.name(), @agent.Delegate(peer.graph()))
      .edge(peer.name(), route_node)
  }
  strategy = strategy
    .node(route_node, @agent.Custom(route_node))
    .node(@agent.finish_node, @agent.Finish)
    .edge(route_node, @agent.finish_node)
  for peer in members {
    strategy = strategy.edge(route_node, peer.name())
  }
  config
  .with_node(route_node, fn(runtime, state, _run) {
    route_after(runtime, state)
  })
  .with_strategy(strategy)
}

///|
/// A team with a lead that decides which peer acts next.
///
/// The router asks the model — the agent's own model, with the conversation in hand — which
/// peer should act, and stops when it answers `FINISH`. A supervisor costs one model call per
/// turn and buys a plan nobody has to write; a swarm costs nothing and only goes where the
/// members send it.
pub fn supervisor(
  config : @agent.AgentConfig,
  members : Array[@agent.Agent],
  instruction? : String,
  max_turns~ : Int32 = 8,
) -> @agent.AgentConfig {
  guard members.length() > 0 else {
    return config.with_strategy(@agent.answer_only())
  }
  let prompt = instruction.unwrap_or(router_prompt(members))
  let mut strategy = @agent.Strategy::new("supervisor")
    .node(@agent.agent_node, @agent.Start(then=route_node))
    .edge(@agent.agent_node, route_node)
    .node(route_node, @agent.Custom(route_node))
    .node(@agent.finish_node, @agent.Finish)
    .edge(route_node, @agent.finish_node)
  for peer in members {
    strategy = strategy
      .node(peer.name(), @agent.Delegate(peer.graph()))
      .edge(peer.name(), route_node)
      .edge(route_node, peer.name())
  }
  config
  .with_node(route_node, async fn(runtime, state, run) {
    supervisor_route(runtime, state, run, members, prompt, max_turns)
  })
  .with_strategy(strategy)
}

///|
/// What the router is told about its job.
fn router_prompt(members : Array[@agent.Agent]) -> String {
  let roster = StringBuilder()
  for peer in members {
    roster.write_string("- " + peer.name() + "\n")
  }
  "You route a conversation between agents. Reply with the name of the agent that should act next, or FINISH when the task is done. Reply with the name only.\n\nAgents:\n" +
  roster.to_string()
}

///|
/// The supervisor's turn: read the conversation, name the next agent, and go there.
async fn supervisor_route(
  runtime : @agent.Runtime,
  state : @agent.AgentState,
  _run : @moonstate.Run,
  members : Array[@agent.Agent],
  prompt : String,
  max_turns : Int32,
) -> Array[@moonstate.Step[@agent.AgentState, @agent.Update]] {
  match handoff_target(state) {
    Some(target) =>
      if runtime.has_node(target) {
        return [
          @moonstate.Step::Write(@agent.Forget(key=@agent.handoff_key)),
          @moonstate.Step::Goto(target),
        ]
      }
    None => ()
  }
  if state.model_calls >= max_turns {
    return [
      @moonstate.Step::Write(@agent.Answer(state.text())),
      @moonstate.Step::Goto(@agent.finish_node),
    ]
  }
  let messages = state.messages.copy()
  messages.push(@moonmuse.Message::user(prompt))
  let request = @moonmuse.Request::new(runtime.model, messages)
  let asked = Ok(runtime.provider.chat(request)) catch { error => Err(error) }
  match asked {
    Ok(reply) => {
      let decision = reply.text().trim().to_owned()
      for peer in members {
        if decision.contains(peer.name()) {
          return [@moonstate.Step::Goto(peer.name())]
        }
      }
      [
        @moonstate.Step::Write(@agent.Answer(state.text())),
        @moonstate.Step::Goto(@agent.finish_node),
      ]
    }
    Err(_) =>
      [
        @moonstate.Step::Write(@agent.Answer(state.text())),
        @moonstate.Step::Goto(@agent.finish_node),
      ]
  }
}
