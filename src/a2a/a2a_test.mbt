///|
/// A request a peer would send: one user message in a fresh context.
fn request(text : String) -> @moona2a.RequestContext {
  {
    message: @moona2a.Message::user("m1", text),
    task_id: "t1",
    context_id: "c1",
    task: None,
    headers: [],
  }
}

///|
async test "a2a: the executor runs the agent and answers with its text" {
  let agent = @agent.create_agent(
    @fake.Fake::text("the remote answer"),
    @agent.AgentConfig::new("test-model", name="remote"),
  )
  let sink = @moona2a.Collected::new()
  @a2a.executor(agent).execute(request("hello"), sink)
  assert_eq(sink.message().unwrap().text(), "the remote answer")
}

///|
async test "a2a: a failed run is reported as a failed task" {
  let agent = @agent.create_agent(
    @fake.Fake::failing(500),
    @agent.AgentConfig::new("test-model", name="remote"),
  )
  let sink = @moona2a.Collected::new()
  @a2a.executor(agent).execute(request("hello"), sink)
  assert_eq(sink.message() is None, true)
  assert_eq(sink.events().length(), 1)
  assert_eq(sink.events()[0].state() is Some(@moona2a.TaskState::Failed), true)
}
