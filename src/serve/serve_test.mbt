///|
/// A server over an agent that always answers the same thing.
fn server() -> @serve.Server raise @moonstate.Refused {
  @serve.Server::new(
    @agent.create_agent(
      @fake.Fake::text("the answer"),
      @agent.AgentConfig::new("test-model"),
    ),
  )
}

///|
async test "serve: a thread is created and can be read back" {
  let server = server()
  let thread = server.create_thread(
    Json::object(Map([("user", Json::string("leo"))])),
  )
  assert_eq(thread.thread_id, "thread-1")
  assert_eq(server.thread("thread-1").unwrap().metadata is Object(_), true)
  assert_eq(server.thread("nope") is None, true)
}

///|
async test "serve: a run executes the agent and is recorded on the thread" {
  let server = server()
  let thread = server.create_thread(Json::null())
  let ran = Ok(server.create_run(thread.thread_id, "hello")) catch {
    error => Err(error)
  }
  match ran {
    Ok(run) => {
      assert_eq(run.status, "completed")
      assert_eq(run.answer.unwrap(), "the answer")
      assert_eq(server.run(run.run_id).unwrap().thread_id, thread.thread_id)
    }
    Err(error) => fail("the run failed: " + @agent.describe(error))
  }
}

///|
async test "serve: a run on a thread that does not exist is refused" {
  let server = server()
  let ran = Ok(server.create_run("thread-404", "hello")) catch {
    error => Err(error)
  }
  match ran {
    Ok(_) => fail("the run should have been refused")
    Err(@agent.Refused(reason~)) =>
      assert_eq(reason.contains("thread-404"), true)
    Err(other) => fail("unexpected " + @agent.describe(other))
  }
}

///|
async test "serve: a failed run is recorded as failed, with the reason" {
  let server = @serve.Server::new(
    @agent.create_agent(
      @fake.Fake::failing(500),
      @agent.AgentConfig::new("test-model"),
    ),
  )
  let thread = server.create_thread(Json::null())
  let ran = Ok(server.create_run(thread.thread_id, "hello")) catch {
    error => Err(error)
  }
  match ran {
    Ok(run) => {
      assert_eq(run.status, "failed")
      assert_eq(run.answer is None, true)
    }
    Err(error) => fail("unexpected " + @agent.describe(error))
  }
}

///|
test "serve: the thread and run documents name their object" {
  let thread : @serve.Thread = {
    thread_id: "thread-1",
    created_at: 0L,
    metadata: Json::null(),
  }
  assert_eq(thread.to_json() is Object(_), true)
  let run : @serve.Run = {
    run_id: "run-1",
    thread_id: "thread-1",
    status: "completed",
    answer: Some("done"),
    reason: None,
  }
  assert_eq(run.to_json() is Object(_), true)
}
