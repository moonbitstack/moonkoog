///|
/// The LLM planner (Koog's plan-and-execute agent): parse a plan from the model,
/// run each step threading the running state, mark each done, and — with the critic
/// enabled — keep or discard the plan on the model's CONTINUE / REPLAN verdict. The
/// scripted model returns a plan, then a result per step.
///
///     moon run examples/16-planner --target native
#coverage.skip
async fn main {
  @async.with_task_group(_g => {
    let model = @models.deepseek_v4_flash

    // Build a plan, then step through it.
    let planner = @agent.LLMPlanner::new(
      @agent.MockClient::new([
        @moonmuse.Message::assistant(
          "GOAL: greet the user\n- say hello\n- say goodbye",
        ),
        @moonmuse.Message::assistant("did step 1"),
        @moonmuse.Message::assistant("did step 2"),
      ]),
      model,
    )
    let plan = planner.build_plan("start", None)
    println("goal: " + plan.goal)
    for i, step in plan.steps {
      println("  step \{i}: " + step.description)
    }
    let s1 = planner.execute_step("start", plan)
    println(
      "after step 1: '\{s1}', completed=\{planner.is_plan_completed(plan)}",
    )
    let s2 = planner.execute_step(s1, plan)
    println(
      "after step 2: '\{s2}', completed=\{planner.is_plan_completed(plan)}",
    )

    // `run` drives build+execute to completion in one call.
    let auto = @agent.LLMPlanner::new(
      @agent.MockClient::new([
        @moonmuse.Message::assistant("GOAL: g\n- a\n- b"),
        @moonmuse.Message::assistant("did a"),
        @moonmuse.Message::assistant("did b"),
      ]),
      model,
    )
    println("run() final output: " + auto.run("solve it"))

    // With the critic, the model's verdict keeps or replaces the plan.
    let sample : @agent.SimplePlan = {
      goal: "g",
      steps: [{ description: "a", is_completed: false, }],
    }
    let keep = @agent.LLMPlanner::new(
      @agent.MockClient::new([@moonmuse.Message::assistant("CONTINUE")]),
      model,
    ).with_critic()
    let verdict = keep.assess_plan("state", Some(sample))
    let kept = match verdict {
      @agent.Continue(_) => "CONTINUE"
      @agent.Replan(_, reason) => "REPLAN: " + reason
      @agent.NoPlan => "no plan"
    }
    println("critic verdict: " + kept)
  })
}
