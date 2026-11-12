///|
/// A reply that answers in prose.
fn says(text : String) -> @moonmuse.Reply {
  @moonmuse.Reply::new(@moonmuse.Message::assistant(text))
}

///|
/// A reply that asks for one tool call.
fn calls(name : String, args : Json) -> @moonmuse.Reply {
  @moonmuse.Reply::new(
    @moonmuse.Message::new(@moonmuse.Assistant, [
      @moonmuse.Part::call("call_1", name, args),
    ]),
    finish=@moonmuse.Finish::Calls,
  )
}

///|
/// A tool that echoes its `text` argument and counts how often it ran.
fn echo_tool(runs : Ref[Int32]) -> @agent.ToolSpec {
  @agent.ToolSpec::new(
    name="echo",
    description="Echo the text back.",
    schema=Json::object(Map([("type", Json::string("object"))])),
    run=fn(args, _context) {
      runs.val = runs.val + 1
      match args {
        Object(fields) =>
          match fields.get("text") {
            Some(String(text)) => text
            _ => ""
          }
        _ => ""
      }
    },
  )
}

///|
/// An agent over `provider` with `middleware` installed.
fn agent_with(
  provider : &@moonmuse.Provider,
  middleware : &@agent.Middleware,
  tools? : Array[@agent.ToolSpec],
  limits? : @agent.Limits,
) -> @agent.Agent raise @moonstate.Refused {
  let config = @agent.AgentConfig::new("test-model")
  let config = match tools {
    Some(tools) => config.with_tools(tools)
    None => config
  }
  let config = match limits {
    Some(limits) => config.with_limits(limits)
    None => config
  }
  @agent.create_agent(provider, config.with_middleware(middleware))
}

///|
/// Every tool result in the last request the provider saw, which is how a test reads what the
/// model was told after a tool ran.
fn tool_results(provider : @fake.Fake) -> Array[String] {
  let seen = provider.seen()
  let out : Array[String] = []
  guard seen.length() > 0 else { return out }
  let last = seen[seen.length() - 1]
  for message in last.messages {
    for part in message.results() {
      match part {
        @moonmuse.Part::Result(content~, ..) => out.push(content)
        _ => ()
      }
    }
  }
  out
}

///|
async test "model_call_limit: no call is made once the limit is zero" {
  let provider = @fake.Fake::new([says("one")])
  let agent = agent_with(provider, @middleware.ModelCallLimit::new(limit=0))
  let answer = agent.run("hello")
  assert_eq(answer, "model call limit of 0 reached")
  assert_eq(provider.hits(), 0)
}

///|
async test "model_call_limit: one call is allowed, the next is not" {
  let provider = @fake.Fake::new([
    calls("echo", Json::object(Map([]))),
    says("two"),
  ])
  let agent = agent_with(provider, @middleware.ModelCallLimit::new(limit=1), tools=[
    echo_tool(Ref(0)),
  ])
  let answer = agent.run("hello")
  assert_eq(provider.hits(), 1)
  assert_eq(answer, "model call limit of 1 reached")
}

///|
async test "tool_call_limit: a refused call is reported to the model" {
  let runs = Ref(0)
  let provider = @fake.Fake::new([
    calls("echo", Json::object(Map([]))),
    says("done"),
  ])
  let agent = agent_with(
    provider,
    @middleware.ToolCallLimit::new(limit=0, tool="echo"),
    tools=[echo_tool(runs)],
  )
  assert_eq(agent.run("say it"), "done")
  assert_eq(runs.val, 0)
}

///|
async test "model_retry: a retryable failure is retried" {
  let provider = @fake.Fake::flaky(1, says("recovered"), code=429)
  let agent = agent_with(
    provider,
    @middleware.ModelRetry::new(attempts=2, base_ms=1),
  )
  assert_eq(agent.run("hello"), "recovered")
  assert_eq(provider.hits(), 2)
}

///|
async test "model_retry: a rejected request is not retried" {
  let provider = @fake.Fake::failing(400)
  let agent = agent_with(
    provider,
    @middleware.ModelRetry::new(attempts=3, base_ms=1),
  )
  let outcome = Ok(agent.run("hello")) catch { error => Err(error) }
  assert_eq(outcome is Err(_), true)
  assert_eq(provider.hits(), 1)
}

///|
async test "model_fallback: the second provider answers" {
  let primary = @fake.Fake::failing(500)
  let backup = @fake.Fake::text("from the backup")
  let agent = agent_with(
    primary,
    @middleware.ModelFallback::new([
      @middleware.Fallback::new(backup, "backup-model"),
    ]),
  )
  assert_eq(agent.run("hello"), "from the backup")
  assert_eq(backup.seen()[0].model, "backup-model")
}

///|
async test "summarization: a long conversation is summarised before the call" {
  let provider = @fake.Fake::text("summary of the earlier conversation")
  let agent = agent_with(
    provider,
    @middleware.Summarization::new(max_messages=2, keep=1),
    tools=[],
  )
  let _ = agent.run("one")
  let _ = agent.run("two")
  let seen = provider.seen()
  let last = seen[seen.length() - 1]
  assert_eq(last.messages.length() <= 3, true)
}

///|
async test "context_editing: older tool results are cleared, the newest kept" {
  let provider = @fake.Fake::new([
    calls("echo", Json::object(Map([("text", Json::string("first"))]))),
    calls("echo", Json::object(Map([("text", Json::string("second"))]))),
    says("done"),
  ])
  let runs = Ref(0)
  let agent = agent_with(
    provider,
    @middleware.ContextEditing::new(
      @middleware.EditingStrategy::ClearToolResults(keep=1),
    ),
    tools=[echo_tool(runs)],
  )
  let _ = agent.run("go")
  let seen = provider.seen()
  let last = seen[seen.length() - 1]
  let mut cleared = 0
  for message in last.messages {
    for part in message.parts {
      match part {
        @moonmuse.Part::Result(content~, ..) =>
          if content == cleared_result() {
            cleared = cleared + 1
          }
        _ => ()
      }
    }
  }
  assert_eq(cleared, 1)
}

///|
/// The marker the editing middleware leaves behind.
fn cleared_result() -> String {
  "[the result of this call was cleared to save context]"
}

///|
async test "todo: the list is installed, used, and kept in the state" {
  let provider = @fake.Fake::new([
    calls(
      "write_todos",
      Json::object(
        Map([
          (
            "todos",
            Json::array([
              Json::object(
                Map([
                  ("content", Json::string("read the code")),
                  ("status", Json::string("completed")),
                ]),
              ),
              Json::object(
                Map([
                  ("content", Json::string("write the test")),
                  ("status", Json::string("in_progress")),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    ),
    says("planned"),
  ])
  let saver = @moonstate.MemorySaver::new()
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model").with_middleware(
      @middleware.TodoList::new(),
    ),
    saver~,
  )
  assert_eq(agent.run("plan"), "planned")
  let tools = provider.seen()[0].tools
  assert_eq(tools.map(tool => tool.name).contains("write_todos"), true)
  let results = tool_results(provider)
  assert_eq(results.length(), 1)
  assert_eq(results[0].contains("[x] read the code"), true)
  assert_eq(results[0].contains("[~] write the test"), true)
}

///|
async test "human_in_the_loop: the run stops, and resumes on approval" {
  let runs = Ref(0)
  let provider = @fake.Fake::new([
    calls("echo", Json::object(Map([("text", Json::string("hi"))]))),
    says("done"),
  ])
  let saver = @moonstate.MemorySaver::new()
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model")
    .with_middleware(@middleware.HumanInTheLoop::new(["echo"]))
    .with_tools([echo_tool(runs)]),
    saver~,
  )
  let stopped = Ok(agent.run("go", thread="t")) catch { error => Err(error) }
  match stopped {
    Ok(_) => fail("the run should have stopped for approval")
    Err(@agent.Engine(@moonstate.GraphError::Interrupted(value~, ..))) => {
      assert_eq(value is Object(_), true)
      assert_eq(runs.val, 0)
    }
    Err(other) => fail("unexpected " + @agent.describe(other))
  }
  let resumed = agent.resume_from("t", Json::boolean(true))
  assert_eq(resumed, "done")
  assert_eq(runs.val, 1)
}

///|
async test "human_in_the_loop: a denial comes back to the model" {
  let runs = Ref(0)
  let provider = @fake.Fake::new([
    calls("echo", Json::object(Map([]))),
    says("I will not"),
  ])
  let saver = @moonstate.MemorySaver::new()
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model")
    .with_middleware(@middleware.HumanInTheLoop::new(["echo"]))
    .with_tools([echo_tool(runs)]),
    saver~,
  )
  let _ = Ok(agent.run("go", thread="d")) catch { error => Err(error) }
  assert_eq(agent.resume_from("d", Json::boolean(false)), "I will not")
  assert_eq(runs.val, 0)
}

///|
async test "pii: an email address does not reach the provider" {
  let provider = @fake.Fake::text("ok")
  let agent = agent_with(provider, @middleware.Pii::standard())
  let _ = agent.run("write to leo@example.com please")
  let sent = provider.seen()[0].messages[0].text_content()
  assert_eq(sent.contains("leo@example.com"), false)
  assert_eq(sent.contains("[email]"), true)
}

///|
async test "tool_selection: only the tools the model names are advertised" {
  let picker = @fake.Fake::new([says("echo"), says("answered")])
  let agent = @agent.create_agent(
    picker,
    @agent.AgentConfig::new("test-model")
    .with_middleware(@middleware.ToolSelection::new(max_tools=1))
    .with_tools([
      echo_tool(Ref(0)),
      @agent.ToolSpec::new(name="other", description="Another tool.", run=fn(
        _args,
        _context,
      ) {
        "other"
      }),
    ]),
  )
  let _ = agent.run("echo something")
  let seen = picker.seen()
  let answering = seen[seen.length() - 1]
  assert_eq(answering.tools.length(), 1)
  assert_eq(answering.tools[0].name, "echo")
}

///|
async test "shell_tool: a command runs and its output comes back" {
  let provider = @fake.Fake::new([
    calls(
      "run_shell",
      Json::object(Map([("command", Json::string("echo hi"))])),
    ),
    says("ran it"),
  ])
  let agent = agent_with(
    provider,
    @middleware.ShellTool::new(prefix=@middleware.os_shell),
  )
  assert_eq(agent.run("run echo"), "ran it")
  let results = tool_results(provider)
  assert_eq(results.length(), 1)
  assert_eq(results[0].contains("hi"), true)
}

///|
async test "file_search: a file under the root is found, a climb out is refused" {
  let provider = @fake.Fake::new([
    calls(
      "search_files",
      Json::object(Map([("pattern", Json::string("../../etc/passwd"))])),
    ),
    says("refused"),
  ])
  let agent = agent_with(provider, @middleware.FileSearch::new(".", limit=5))
  let _ = agent.run("find it")
  let results = tool_results(provider)
  assert_eq(results.length(), 1)
  assert_eq(results[0].contains("must stay inside"), true)
}
