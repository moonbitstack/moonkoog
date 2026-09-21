// The LLM planner (Koog agents-planner `SimpleLLMPlanner` / `SimpleLLMWithCriticPlanner`):
// a string-in/string-out agent that asks a model for an ordered plan of steps, then executes
// them one at a time, threading the state through each step. `with_critic` turns on a second
// model call that re-judges the plan before every step and asks for a replan when it has gone
// stale. Koog serialises the plan as JSON via reflection; MoonBit has no such reflection, so the
// faithful equivalent is a fixed line protocol (`GOAL:` + `- ` bullets) the parser reads back.

///|
/// One step of a plan: what to do, and whether it is already done (Koog `PlanStep`).
pub(all) struct PlanStep {
  description : String
  mut is_completed : Bool
} derive(Eq, Debug)

///|
/// A plan: the overall goal and the ordered steps that reach it (Koog `SimplePlan`).
pub(all) struct SimplePlan {
  goal : String
  steps : Array[PlanStep]
} derive(Eq, Debug)

///|
/// A verdict on the current plan before a step runs (Koog `SimplePlanAssessment`): keep going,
/// throw it away and replan with a reason, or there is no plan yet.
pub(all) enum PlanAssessment {
  Replan(SimplePlan, String)
  Continue(SimplePlan)
  NoPlan
} derive(Eq, Debug)

///|
/// A planner backed by `client` / `model`. With `with_critic` set it re-judges the plan with the
/// model before each step (Koog `SimpleLLMWithCriticPlanner`); otherwise it keeps any existing
/// plan (Koog `SimpleLLMPlanner`).
pub struct LLMPlanner {
  client : &LLMClient
  model : @llm.LLModel
  with_critic : Bool
}

///|
/// A planner over `client` / `model` that keeps its plan once built.
pub fn LLMPlanner::new(client : &LLMClient, model : @llm.LLModel) -> LLMPlanner {
  { client, model, with_critic: false, }
}

///|
/// The same planner with the LLM critic enabled (Koog `Planners.llmBasedWithCritic`).
pub fn LLMPlanner::with_critic(self : LLMPlanner) -> LLMPlanner {
  { ..self, with_critic: true, }
}

///|
/// Judge the current plan. With no plan there is nothing to judge; without the critic the plan is
/// always kept; with the critic the model replies `CONTINUE` to keep it or `REPLAN: <reason>` to
/// discard it.
pub async fn LLMPlanner::assess_plan(
  self : LLMPlanner,
  state : String,
  plan : SimplePlan?,
) -> PlanAssessment {
  guard plan is Some(p) else { return NoPlan }
  guard self.with_critic else { return Continue(p) }
  let prompt = @prompt.PromptBuilder::new()
    .system(
      "You are a critical evaluator of plans. Decide whether the plan below is still valid for the current state, or whether it must be replanned. Reply exactly 'CONTINUE' to keep it, or 'REPLAN: <reason>' to discard it.",
    )
    .user("Current state:\n" + state + "\n\n" + render_plan(p))
    .build()
  let reply = LLMClient::execute(self.client, prompt~, model=self.model, tools=[]).text_content()
  let t = trim_spaces(reply)
  if t.has_prefix("REPLAN") {
    Replan(p, feedback_after_colon(reply))
  } else {
    Continue(p)
  }
}

///|
/// Produce the plan to execute next: keep the current one if the assessment says so, otherwise ask
/// the model for a fresh plan (feeding it the failed plan and the reason when replanning).
pub async fn LLMPlanner::build_plan(
  self : LLMPlanner,
  state : String,
  plan : SimplePlan?,
) -> SimplePlan {
  let assessment = self.assess_plan(state, plan)
  if assessment is Continue(p) {
    return p
  }
  let sb = StringBuilder()
  sb.write_string(
    "You are a planning agent. Create a detailed, ordered plan of steps that solves the user's problem.\n",
  )
  if assessment is Replan(prev, reason) {
    sb.write_string(
      "\nA previous plan failed and must be revised. Previous plan:\n",
    )
    sb.write_string(render_plan(prev))
    sb.write_string("\nReason to replan: ")
    sb.write_string(reason)
    sb.write_string("\n")
  }
  sb.write_string("\nProblem:\n")
  sb.write_string(state)
  sb.write_string(
    "\n\nReply with the plan in exactly this format and nothing else:\nGOAL: <one-line goal>\n- <step>\n- <step>\nUse \"- \" for every step; mark an already-done step as \"- [x] <step>\".",
  )
  let prompt = @prompt.PromptBuilder::new()
    .system(sb.to_string())
    .user("Problem:\n" + state)
    .build()
  let reply = LLMClient::execute(self.client, prompt~, model=self.model, tools=[]).text_content()
  parse_plan(reply)
}

///|
/// Execute the first not-yet-done step of `plan` against `state`, mark it done, and return the
/// model's output as the new state. When every step is done the plan is complete.
pub async fn LLMPlanner::execute_step(
  self : LLMPlanner,
  state : String,
  plan : SimplePlan,
) -> String {
  guard first_incomplete(plan) is Some(step) else {
    return "All steps of the plan are completed!"
  }
  let prompt = @prompt.PromptBuilder::new()
    .system("You are executing a step in a plan. The goal is: " + plan.goal)
    .user(
      "Execute the following step: " +
      step.description +
      "\nCurrent state: " +
      state,
    )
    .build()
  let reply = LLMClient::execute(self.client, prompt~, model=self.model, tools=[]).text_content()
  step.is_completed = true
  reply
}

///|
/// Whether every step of `plan` is done (Koog `isPlanCompleted`).
pub fn LLMPlanner::is_plan_completed(
  self : LLMPlanner,
  plan : SimplePlan,
) -> Bool {
  ignore(self)
  for s in plan.steps {
    guard s.is_completed else { return false }
  }
  true
}

///|
/// Run the planner end to end (Koog `AIAgentPlanner.execute`): build a plan, execute its steps one
/// by one re-judging before each, and return the final state. `max_steps` bounds the loop the way
/// Koog's `maxAgentIterations` does.
pub async fn LLMPlanner::run(
  self : LLMPlanner,
  input : String,
  max_steps? : Int = 32,
) -> String {
  let mut state = input
  let mut plan : SimplePlan? = None
  for _ in 0..<max_steps {
    let p = self.build_plan(state, plan)
    plan = Some(p)
    state = self.execute_step(state, p)
    if self.is_plan_completed(p) {
      return state
    }
  }
  state
}

///|
/// The first step of `plan` that is not yet done, if any.
fn first_incomplete(plan : SimplePlan) -> PlanStep? {
  for s in plan.steps {
    guard s.is_completed else { return Some(s) }
  }
  None
}

///|
/// Render a plan back into the line protocol, for feeding a failed plan to a replan prompt.
fn render_plan(plan : SimplePlan) -> String {
  let sb = StringBuilder()
  sb.write_string("GOAL: ")
  sb.write_string(plan.goal)
  sb.write_string("\n")
  for s in plan.steps {
    sb.write_string(if s.is_completed { "- [x] " } else { "- " })
    sb.write_string(s.description)
    sb.write_string("\n")
  }
  sb.to_string()
}

///|
/// Parse a plan from the model's reply: the text after `GOAL:` is the goal, and each `- ` bullet
/// is a step, with `[x]` / `[COMPLETED]` marking one already done.
fn parse_plan(text : String) -> SimplePlan {
  let mut goal = ""
  let steps : Array[PlanStep] = []
  for line in split_lines(text) {
    let t = trim_spaces(line)
    if t.has_prefix("GOAL:") {
      goal = trim_spaces(drop_n(t, 5))
    } else if t.has_prefix("- ") || t.has_prefix("* ") {
      let (completed, body) = strip_completed(trim_spaces(drop_n(t, 2)))
      let d = trim_spaces(body)
      if d != "" {
        steps.push({ description: d, is_completed: completed, })
      }
    }
  }
  { goal, steps, }
}

///|
/// Split off a leading done-marker, returning whether the step is done and the remaining text.
fn strip_completed(body : String) -> (Bool, String) {
  if body.has_prefix("[x] ") || body.has_prefix("[X] ") {
    (true, drop_n(body, 4))
  } else if body.has_prefix("[COMPLETED] ") {
    (true, drop_n(body, 12))
  } else if body.has_prefix("[ ] ") {
    (false, drop_n(body, 4))
  } else {
    (false, body)
  }
}

///|
/// The text with its first `n` characters dropped.
fn drop_n(s : String, n : Int) -> String {
  let sb = StringBuilder()
  let mut i = 0
  for c in s {
    if i >= n {
      sb.write_string(c.to_string())
    }
    i = i + 1
  }
  sb.to_string()
}

///|
/// `s` split on newlines, carriage returns dropped.
fn split_lines(s : String) -> Array[String] {
  let out : Array[String] = []
  let sb = StringBuilder()
  for c in s {
    if c == '\n' {
      out.push(sb.to_string())
      sb.reset()
    } else if c != '\r' {
      sb.write_string(c.to_string())
    }
  }
  out.push(sb.to_string())
  out
}

///|
/// `s` without leading or trailing spaces and tabs.
fn trim_spaces(s : String) -> String {
  let chars : Array[Char] = []
  for c in s {
    chars.push(c)
  }
  let mut start = 0
  let mut end = chars.length()
  while start < end && (chars[start] == ' ' || chars[start] == '\t') {
    start = start + 1
  }
  while end > start && (chars[end - 1] == ' ' || chars[end - 1] == '\t') {
    end = end - 1
  }
  let sb = StringBuilder()
  for i in start..<end {
    sb.write_string(chars[i].to_string())
  }
  sb.to_string()
}

///|
pub extend PlanAssessment with Debug::{to_repr}

///|
pub extend PlanAssessment with Eq::{not_equal, equal}

///|
pub extend PlanStep with Debug::{to_repr}

///|
pub extend PlanStep with Eq::{not_equal, equal}

///|
pub extend SimplePlan with Debug::{to_repr}

///|
pub extend SimplePlan with Eq::{not_equal, equal}
