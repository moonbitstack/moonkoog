///|
/// The world of the search test: three flags packed into an integer, which is comparable and
/// hashable, so the frontier can key states directly.
let wood : Int32 = 1

///|
let sword : Int32 = 2

///|
let axe : Int32 = 4

///|
/// A planning world for the tests: gather wood, then make either tool.
fn world() -> Array[@plan.GoapAction[Int32]] {
  [
    @plan.GoapAction::new(
      name="gather wood",
      applies=state => (state & wood) == 0,
      effect=state => state | wood,
    ),
    @plan.GoapAction::new(
      name="forge a sword",
      applies=state => (state & wood) != 0 && (state & sword) == 0,
      effect=state => state | sword,
      cost=_ => 2.0,
    ),
    @plan.GoapAction::new(
      name="chop with an axe",
      applies=state => (state & axe) != 0,
      effect=state => state,
    ),
  ]
}

///|
test "goap: the cheapest plan reaches the goal" {
  let goal = @plan.GoapGoal::new(reached=state => (state & sword) != 0)
  let plan = @plan.search(world(), 0, goal).unwrap()
  assert_eq(plan, ["gather wood", "forge a sword"])
}

///|
test "goap: an unreachable goal has no plan" {
  let goal = @plan.GoapGoal::new(reached=state => (state & axe) != 0)
  assert_eq(@plan.search(world(), 0, goal) is None, true)
}

///|
test "goap: the estimate decides between two routes" {
  // Reaching the goal needs either a sword or an axe; the estimate makes the axe look nearer
  // from the start, so the search takes that branch.
  let actions = [
    @plan.GoapAction::new(
      name="sword route",
      applies=_ => true,
      effect=state => state | sword,
      cost=_ => 5.0,
    ),
    @plan.GoapAction::new(
      name="axe route",
      applies=_ => true,
      effect=state => state | axe,
      cost=_ => 1.0,
    ),
  ]
  let goal = @plan.GoapGoal::new(
    reached=state => (state & sword) != 0 || (state & axe) != 0,
    estimate=_ => 0.0,
  )
  assert_eq(@plan.search(actions, 0, goal).unwrap(), ["axe route"])
}

///|
test "steps: a JSON array is read as written" {
  let steps = @plan.parse_steps("[\"read the code\", \"write the test\"]", 5)
  assert_eq(steps, ["read the code", "write the test"])
}

///|
test "steps: a numbered list is read line by line" {
  let steps = @plan.parse_steps("1. read the code\n2. write the test", 5)
  assert_eq(steps, ["read the code", "write the test"])
}

///|
test "steps: the limit is honoured" {
  let steps = @plan.parse_steps("[\"a\", \"b\", \"c\"]", 2)
  assert_eq(steps, ["a", "b"])
}

///|
/// A reply that answers in prose.
fn says(text : String) -> @moonmuse.Reply {
  @moonmuse.Reply::new(@moonmuse.Message::assistant(text))
}

///|
async test "plan and execute: the model works through the steps the planner wrote" {
  let provider = @fake.Fake::new([
    says("[\"look up the answer\", \"report it\"]"),
    says("the answer is 42"),
    says("it is 42"),
  ])
  let config = @plan.plan_and_execute(
    @agent.AgentConfig::new("test-model"),
    limit=4,
  )
  let agent = @agent.create_agent(provider, config)
  assert_eq(agent.run("what is the answer?"), "it is 42")
  let seen = provider.seen()
  assert_eq(seen.length(), 3)
  assert_eq(
    seen[1].messages[seen[1].messages.length() - 1]
    .text_content()
    .contains("Step 1 of 2"),
    true,
  )
  assert_eq(
    seen[2].messages[seen[2].messages.length() - 1]
    .text_content()
    .contains("Step 2 of 2"),
    true,
  )
}

///|
async test "plan and execute: an empty plan ends the run with a reason" {
  let provider = @fake.Fake::new([says("")])
  let config = @plan.plan_and_execute(@agent.AgentConfig::new("test-model"))
  let agent = @agent.create_agent(provider, config)
  let outcome = Ok(agent.run("task")) catch { error => Err(error) }
  match outcome {
    Ok(_) => fail("the run should have failed")
    Err(@agent.Refused(reason~)) => assert_eq(reason.contains("no steps"), true)
    Err(other) => fail("unexpected " + @agent.describe(other))
  }
}
