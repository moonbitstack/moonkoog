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
/// The world of the transcription tests: five flags packed into an integer, in the shape of the
/// state the reference suite plans over.
let has_wood : Int32 = 1

///|
let has_stone : Int32 = 2

///|
let has_axe : Int32 = 4

///|
let has_pickaxe : Int32 = 8

///|
let has_shelter : Int32 = 16

///|
/// Runs a plan's actions in order against a start state, so a test can assert the state the
/// reference suite asserts rather than only the names.
fn walk(
  actions : Array[@plan.GoapAction[Int32]],
  start : Int32,
  plan : Array[String],
) -> Int32 {
  let mut state = start
  for name in plan {
    for action in actions {
      if action.name == name {
        state = (action.effect)(state)
      }
    }
  }
  state
}

///|
test "koog: testGOAPLinearPath — three actions in a row reach the treasure" {
  let key : Int32 = 1
  let door : Int32 = 2
  let treasure : Int32 = 4
  let actions = [
    @plan.GoapAction::new(name="Get key", applies=state => (state & key) == 0, effect=state => {
      state | key
    }),
    @plan.GoapAction::new(
      name="Unlock door",
      applies=state => (state & key) != 0 && (state & door) == 0,
      effect=state => state | door,
    ),
    @plan.GoapAction::new(
      name="Find treasure",
      applies=state => (state & door) != 0 && (state & treasure) == 0,
      effect=state => state | treasure,
    ),
  ]
  let goal = @plan.GoapGoal::new(reached=state => (state & treasure) != 0)
  let plan = @plan.search(actions, 0, goal).unwrap()
  assert_eq(plan, ["Get key", "Unlock door", "Find treasure"])
  let end = walk(actions, 0, plan)
  assert_eq((end & key) != 0, true)
  assert_eq((end & door) != 0, true)
  assert_eq((end & treasure) != 0, true)
}

///|
test "koog: testGOAPOptimalPathSelection — the cheap route is chosen, the dear one never is" {
  let item : Int32 = 1
  let reached : Int32 = 2
  let actions = [
    @plan.GoapAction::new(
      name="Expensive route",
      applies=state => (state & item) == 0,
      effect=state => state | item,
      cost=_ => 10.0,
    ),
    @plan.GoapAction::new(
      name="Cheap route",
      applies=state => (state & item) == 0,
      effect=state => state | item,
      cost=_ => 1.0,
    ),
    @plan.GoapAction::new(
      name="Reach goal",
      applies=state => (state & item) != 0 && (state & reached) == 0,
      effect=state => state | reached,
      cost=_ => 1.0,
    ),
  ]
  let goal = @plan.GoapGoal::new(reached=state => (state & reached) != 0)
  let plan = @plan.search(actions, 0, goal).unwrap()
  assert_eq(plan, ["Cheap route", "Reach goal"])
  let end = walk(actions, 0, plan)
  assert_eq((end & item) != 0, true)
  assert_eq((end & reached) != 0, true)
}

///|
test "koog: testGOAPComplexDependencies — two materials, two tools, one shelter" {
  let actions = [
    @plan.GoapAction::new(
      name="Gather wood",
      applies=state => (state & has_wood) == 0,
      effect=state => state | has_wood,
      cost=_ => 2.0,
    ),
    @plan.GoapAction::new(
      name="Gather stone",
      applies=state => (state & has_stone) == 0,
      effect=state => state | has_stone,
      cost=_ => 2.0,
    ),
    @plan.GoapAction::new(
      name="Craft axe",
      applies=state => {
        (state & has_wood) != 0 &&
        (state & has_stone) != 0 &&
        (state & has_axe) == 0
      },
      effect=state => state | has_axe,
      cost=_ => 1.0,
    ),
    @plan.GoapAction::new(
      name="Craft pickaxe",
      applies=state => {
        (state & has_wood) != 0 &&
        (state & has_stone) != 0 &&
        (state & has_pickaxe) == 0
      },
      effect=state => state | has_pickaxe,
      cost=_ => 1.0,
    ),
    @plan.GoapAction::new(
      name="Build shelter",
      applies=state => {
        (state & has_axe) != 0 &&
        (state & has_pickaxe) != 0 &&
        (state & has_shelter) == 0
      },
      effect=state => state | has_shelter,
      cost=_ => 3.0,
    ),
  ]
  let goal = @plan.GoapGoal::new(reached=state => (state & has_shelter) != 0)
  let plan = @plan.search(actions, 0, goal).unwrap()
  assert_eq(plan.length(), 5)
  let end = walk(actions, 0, plan)
  assert_eq((end & has_wood) != 0, true)
  assert_eq((end & has_stone) != 0, true)
  assert_eq((end & has_axe) != 0, true)
  assert_eq((end & has_pickaxe) != 0, true)
  assert_eq((end & has_shelter) != 0, true)
}

///|
test "koog: testBuildAction — an action keeps its name, its precondition and its cost" {
  let action = @plan.GoapAction::new(name="test-action", applies=_ => true, effect=state => {
    state | has_wood
  })
  assert_eq(action.name, "test-action")
  assert_eq((action.cost)(0), 1.0)
  let after = (action.effect)(0)
  assert_eq((action.applies)(after), true)
  assert_eq((after & has_wood) != 0, true)
  let dear = @plan.GoapAction::new(
    name="dear",
    applies=_ => false,
    effect=state => state,
    cost=_ => 7.5,
  )
  assert_eq((dear.cost)(0), 7.5)
  assert_eq((dear.applies)(0), false)
}

///|
test "koog: testBuildGoal — a goal keeps its condition and its estimate" {
  let plain = @plan.GoapGoal::new(reached=state => state == 3)
  assert_eq((plain.reached)(3), true)
  assert_eq((plain.reached)(2), false)
  // The default estimate is zero on the goal and one everywhere else, which makes the search
  // breadth-first rather than guided.
  assert_eq((plain.estimate)(3), 0.0)
  assert_eq((plain.estimate)(0), 1.0)
  let guided = @plan.GoapGoal::new(reached=_ => false, estimate=(state : Int32) => {
    state.to_double() * 2.0
  })
  assert_eq((guided.estimate)(5), 10.0)
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
async test "koog: testSimplePlannerCreatesAndExecutesPlan — one planning call, then one per step" {
  // The reference suite's case: the model writes a plan of three steps, then works each of them,
  // the third answer being the result the run ends on.
  let provider = @fake.Fake::new([
    says(
      "[\"Find available time slots\", \"Send calendar invites\", \"Prepare meeting agenda\"]",
    ),
    says("Found three slots"),
    says("Found three slots; invites sent"),
    says("Found three slots; invites sent; agenda prepared"),
  ])
  let config = @plan.plan_and_execute(
    @agent.AgentConfig::new("test-model"),
    limit=5,
  )
  let agent = @agent.create_agent(provider, config)
  let answer = agent.run("Organize a team meeting")
  assert_eq(answer, "Found three slots; invites sent; agenda prepared")
  let seen = provider.seen()
  assert_eq(seen.length(), 4)
  assert_eq(seen[1].messages[1].text_content().contains("Step 1 of 3"), true)
  assert_eq(
    seen[2].messages[seen[2].messages.length() - 1]
    .text_content()
    .contains("Step 2 of 3"),
    true,
  )
  assert_eq(
    seen[3].messages[seen[3].messages.length() - 1]
    .text_content()
    .contains("Step 3 of 3"),
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
