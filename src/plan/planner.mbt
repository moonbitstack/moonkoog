///|
/// The steps a run is working through, in order.
pub let plan_key : String = "moonkoog.plan"

///|
/// How many steps are done.
pub let index_key : String = "moonkoog.plan.index"

///|
/// The names of the nodes a plan-and-execute run adds to a graph.
pub let planner_node : String = "planner"

///|
/// The node that hands the next step to the model.
pub let step_node : String = "step"

///|
/// The node that records a step as done, and decides whether to plan again.
pub let advance_node : String = "advance"

///|
/// The plan a state holds.
pub fn steps(state : @agent.AgentState) -> Array[String] {
  match state.storage.get(plan_key) {
    Some(Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          String(step) => out.push(step)
          _ => ()
        }
      }
      out
    }
    _ => []
  }
}

///|
/// How many steps the state has finished.
pub fn done(state : @agent.AgentState) -> Int32 {
  match state.storage.get(index_key) {
    Some(Number(value, ..)) => value.to_int()
    _ => 0
  }
}

///|
/// The prompt that turns a task into steps.
pub fn planning_prompt(task : String, limit : Int32) -> String {
  "Break the task below into at most " +
  limit.to_string() +
  " steps. Reply with a JSON array of strings and nothing else — no prose, no numbering, no code fence.\n\nTask:\n" +
  task
}

///|
/// Read a list of steps out of a model reply: the JSON array when there is one, otherwise the
/// lines that look like steps. A model that answers with a numbered list instead of JSON is
/// common enough that refusing it would make the feature unusable.
pub fn parse_steps(text : String, limit : Int32) -> Array[String] {
  let out : Array[String] = []
  let looks_like_json = text.contains("[")
  if looks_like_json {
    let parsed = Ok(@moonjson.loads(text, @moonjson.strict)) catch {
      _ => Err(())
    }
    match parsed {
      Ok(Array(items)) => {
        for item in items {
          match item {
            String(step) => if out.length() < limit { out.push(step) }
            _ => ()
          }
        }
        if out.length() > 0 {
          return out
        }
      }
      _ => ()
    }
  }
  for line in text.split("\n") {
    let trimmed = strip_numbering(line)
    if trimmed != "" && out.length() < limit {
      out.push(trimmed)
    }
  }
  out
}

///|
/// A line without its list marker: `1. `, `- `, `* `, or a leading bullet.
fn strip_numbering(line : StringView) -> String {
  let mut text : String = line.trim().to_owned()
  while text.length() > 0 {
    let first = text[0]
    if first == '-' ||
      first == '*' ||
      first == '•' ||
      (first >= '0' && first <= '9') {
      text = text[1:].to_owned()
      text = text.trim().to_owned()
    } else if first == '.' || first == ')' || first == ':' {
      text = text[1:].to_owned()
      text = text.trim().to_owned()
    } else {
      break
    }
  }
  text
}

///|
/// Ask the model to break the run's task into steps.
async fn ask_steps(
  runtime : @agent.Runtime,
  context : @agent.RunContext,
  task : String,
  limit : Int32,
) -> @agent.ModelOutcome {
  let request = @moonmuse.Request::new(runtime.model, [
    @moonmuse.Message::user(planning_prompt(task, limit)),
  ])
  @agent.pipeline_model(runtime, context, { request, }, @agent.NoTools)
}

///|
/// The planner node: write a plan into the state, then start on its first step.
pub async fn planner(
  runtime : @agent.Runtime,
  state : @agent.AgentState,
  run : @moonstate.Run,
  limit~ : Int32,
) -> Array[@moonstate.Step[@agent.AgentState, @agent.Update]] {
  let context = runtime.context(run, state)
  let task = last_task(state)
  let outcome = ask_steps(runtime, context, task, limit)
  match outcome {
    @agent.ModelOutcome::Replied(reply) => {
      let steps = parse_steps(reply.text(), limit)
      if steps.length() == 0 {
        return [
          @moonstate.Step::Write(
            @agent.Store(
              key=@agent.error_key,
              value=Json::string("the planner produced no steps"),
            ),
          ),
          @moonstate.Step::Goto(@agent.finish_node),
        ]
      }
      let items : Array[Json] = []
      for step in steps {
        items.push(Json::string(step))
      }
      [
        @moonstate.Step::Write(
          @agent.Store(key=plan_key, value=Json::array(items)),
        ),
        @moonstate.Step::Write(
          @agent.Store(key=index_key, value=Json::number(0.0)),
        ),
        @moonstate.Step::Goto(step_node),
      ]
    }
    @agent.ModelOutcome::Halted(text) =>
      [
        @moonstate.Step::Write(@agent.Answer(text)),
        @moonstate.Step::Goto(@agent.finish_node),
      ]
    @agent.ModelOutcome::Failed(reason~, ..) =>
      [
        @moonstate.Step::Write(
          @agent.Store(key=@agent.error_key, value=Json::string(reason)),
        ),
        @moonstate.Step::Goto(@agent.finish_node),
      ]
  }
}

///|
/// The task the run was asked to do: the first user message, which is the one the plan is for.
fn last_task(state : @agent.AgentState) -> String {
  for message in state.messages {
    if message.role is @moonmuse.User {
      return message.text_content()
    }
  }
  ""
}

///|
/// The step node: put the next step in front of the model, or finish when the plan is done.
pub fn step(
  _runtime : @agent.Runtime,
  state : @agent.AgentState,
  _run : @moonstate.Run,
) -> Array[@moonstate.Step[@agent.AgentState, @agent.Update]] {
  let steps = steps(state)
  let index = done(state)
  if index >= steps.length() {
    return [
      @moonstate.Step::Write(@agent.Answer(state.text())),
      @moonstate.Step::Goto(@agent.finish_node),
    ]
  }
  let text = "Step " +
    (index + 1).to_string() +
    " of " +
    steps.length().to_string() +
    ": " +
    steps[index]
  [
    @moonstate.Step::Write(@agent.Append([@moonmuse.Message::user(text)])),
    @moonstate.Step::Goto(@agent.model_node),
  ]
}

///|
/// The advance node: mark the step done, and plan again when it failed.
pub fn advance(
  _runtime : @agent.Runtime,
  state : @agent.AgentState,
  _run : @moonstate.Run,
  replan~ : Bool,
) -> Array[@moonstate.Step[@agent.AgentState, @agent.Update]] {
  let index = done(state) + 1
  let steps = [
    @moonstate.Step::Write(
      @agent.Store(key=index_key, value=Json::number(index.to_double())),
    ),
  ]
  if replan && last_round_failed(state) {
    steps.push(@moonstate.Step::Goto(planner_node))
  } else {
    steps.push(@moonstate.Step::Goto(step_node))
  }
  steps
}

///|
/// Whether the last tool round reported a failure, which is the signal that the step as planned
/// cannot be carried out.
fn last_round_failed(state : @agent.AgentState) -> Bool {
  let mut index = state.messages.length() - 1
  while index >= 0 {
    let message = state.messages[index]
    if message.role is @moonmuse.Tool {
      for part in message.parts {
        match part {
          @moonmuse.Part::Result(error~, ..) => if error { return true }
          _ => ()
        }
      }
      return false
    }
    index = index - 1
  }
  false
}

///|
/// Turn the config into a plan-and-execute agent: a planner writes the steps, the model works
/// through them with its tools, and a failed step sends the run back to the planner.
///
/// The loop lives in the graph, so a run that stops — for approval, for a checkpoint, for a cap —
/// resumes at the step it was on with the plan it had.
pub fn plan_and_execute(
  config : @agent.AgentConfig,
  limit~ : Int32 = 12,
  replan~ : Bool = true,
) -> @agent.AgentConfig {
  let strategy = @agent.Strategy::new("plan_execute")
    .node(@agent.agent_node, @agent.Start(then=planner_node))
    .edge(@agent.agent_node, planner_node)
    .node(planner_node, @agent.Custom(planner_node))
    .edge(planner_node, step_node)
    .node(step_node, @agent.Custom(step_node))
    .edge(step_node, @agent.model_node)
    .edge(step_node, @agent.finish_node)
    .node(@agent.model_node, @agent.Turn(mode=@agent.Tools, then=advance_node))
    .edge(@agent.model_node, @agent.tools_node)
    .edge(@agent.model_node, advance_node)
    .node(@agent.tools_node, @agent.Execute(@agent.All))
    .edge(@agent.tools_node, @agent.model_node)
    .edge(@agent.tools_node, advance_node)
    .node(advance_node, @agent.Custom(advance_node))
    .edge(advance_node, step_node)
    .edge(advance_node, planner_node)
    .edge(advance_node, @agent.finish_node)
    .node(@agent.finish_node, @agent.Finish)
  config
  .with_node(planner_node, async fn(runtime, state, run) {
    planner(runtime, state, run, limit~)
  })
  .with_node(step_node, fn(_runtime, state, run) { step(_runtime, state, run) })
  .with_node(advance_node, fn(runtime, state, run) {
    advance(runtime, state, run, replan~)
  })
  .with_strategy(strategy)
}
