// The LLM planner: parse a plan from the model, execute its steps threading state, mark each done,
// and (with the critic) keep or replan on the model's CONTINUE / REPLAN reply.

///|
async test "llm planner: parses a plan, executes each step, and completes" {
  @async.with_task_group(_g => {
    let plan_text = "GOAL: greet the user\n- say hello\n- say goodbye"
    let mock = @agent.MockClient::new([
      @moonmuse.Message::assistant(plan_text),
      @moonmuse.Message::assistant("did step 1"),
      @moonmuse.Message::assistant("did step 2"),
    ])
    let planner = @agent.LLMPlanner::new(mock, @models.deepseek_v4_flash)
    let plan = planner.build_plan("start", None)
    assert_eq(plan.goal, "greet the user")
    assert_eq(plan.steps.length(), 2)
    assert_eq(plan.steps[0].description, "say hello")
    assert_eq(plan.steps[1].description, "say goodbye")
    assert_eq(planner.is_plan_completed(plan), false)
    let s1 = planner.execute_step("start", plan)
    assert_eq(s1, "did step 1")
    assert_eq(plan.steps[0].is_completed, true)
    assert_eq(plan.steps[1].is_completed, false)
    assert_eq(planner.is_plan_completed(plan), false)
    let s2 = planner.execute_step(s1, plan)
    assert_eq(s2, "did step 2")
    assert_eq(plan.steps[1].is_completed, true)
    assert_eq(planner.is_plan_completed(plan), true)
  })
}

///|
async test "llm planner run: drives build/execute until the plan is complete" {
  @async.with_task_group(_g => {
    let mock = @agent.MockClient::new([
      @moonmuse.Message::assistant("GOAL: g\n- a\n- b"),
      @moonmuse.Message::assistant("did a"),
      @moonmuse.Message::assistant("did b"),
    ])
    let planner = @agent.LLMPlanner::new(mock, @models.deepseek_v4_flash)
    assert_eq(planner.run("problem"), "did b")
  })
}

///|
async test "llm planner critic: CONTINUE keeps the plan, REPLAN discards it with the reason" {
  @async.with_task_group(_g => {
    let plan : @agent.SimplePlan = {
      goal: "g",
      steps: [{ description: "a", is_completed: false, }],
    }
    let keep = @agent.MockClient::new([@moonmuse.Message::assistant("CONTINUE")])
    let a1 = @agent.LLMPlanner::new(keep, @models.deepseek_v4_flash)
      .with_critic()
      .assess_plan("state", Some(plan))
    assert_eq(a1, @agent.Continue(plan))
    let redo = @agent.MockClient::new([
      @moonmuse.Message::assistant("REPLAN: step a is no longer feasible"),
    ])
    let a2 = @agent.LLMPlanner::new(redo, @models.deepseek_v4_flash)
      .with_critic()
      .assess_plan("state", Some(plan))
    assert_eq(a2, @agent.Replan(plan, "step a is no longer feasible"))
  })
}
