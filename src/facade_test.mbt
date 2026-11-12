///|
async test "the facade reaches the agent, its middleware and the planner" {
  let provider = @fake.Fake::text("from the facade")
  let config = @moonkoog.AgentConfig::new("test-model")
    .with_middleware(@moonkoog.ModelCallLimit::new(limit=3))
    .with_tools([@moonkoog.calculator()])
  let agent = @moonkoog.create_agent(provider, config)
  assert_eq(agent.run("hello"), "from the facade")
}

///|
test "the facade reaches the planner's search" {
  let goal = @moonkoog.GoapGoal::new(reached=state => state > 0)
  let actions = [
    @moonkoog.GoapAction::new(name="step", applies=_ => true, effect=state => {
      state + 1
    }),
  ]
  assert_eq(@moonkoog.search(actions, 0, goal).unwrap(), ["step"])
}
