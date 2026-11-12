///|
/// A tool that adds the two integers in its arguments.
fn adder() -> @agent.ToolSpec {
  @agent.ToolSpec::new(
    name="add",
    description="Add a and b.",
    schema=Json::object(
      Map([
        ("type", Json::string("object")),
        (
          "properties",
          Json::object(
            Map([
              ("a", Json::object(Map([("type", Json::string("number"))]))),
              ("b", Json::object(Map([("type", Json::string("number"))]))),
            ]),
          ),
        ),
      ]),
    ),
    run=fn(args, _context) {
      let inner = match args {
        Object(fields) => fields
        _ => Map([])
      }
      let number = key => {
        match inner.get(key) {
          Some(Number(value, ..)) => value
          _ => 0.0
        }
      }
      (number("a") + number("b")).to_string()
    },
  )
}

///|
/// A reply that asks for one tool call.
fn call_reply(
  name : String,
  args : Json,
  id~ : String = "call_1",
) -> @moonmuse.Reply {
  @moonmuse.Reply::new(
    @moonmuse.Message::new(Assistant, [@moonmuse.Part::call(id, name, args)]),
    finish=@moonmuse.Finish::Calls,
  )
}

///|
/// A reply that answers in prose.
fn text_reply(text : String) -> @moonmuse.Reply {
  @moonmuse.Reply::new(@moonmuse.Message::assistant(text))
}

///|
async test "single run asks, calls the tool, and answers" {
  let provider = @fake.Fake::new([
    call_reply(
      "add",
      Json::object(Map([("a", Json::number(2.0)), ("b", Json::number(40.0))])),
    ),
    text_reply("42"),
  ])
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model").with_tools([adder()]),
  )
  let answer = agent.run("what is 2 + 40?")
  assert_eq(answer, "42")
  assert_eq(provider.hits(), 2)
  let second = provider.seen()[1].messages
  assert_eq(second[second.length() - 1].role is Tool, true)
}

///|
async test "the toolbox reaches the model as a tool descriptor" {
  let provider = @fake.Fake::text("done")
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model").with_tools([adder()]),
  )
  let _ = agent.run("hello")
  let tools = provider.seen()[0].tools
  assert_eq(tools.length(), 1)
  assert_eq(tools[0].name, "add")
}

///|
async test "the iteration cap stops a loop that never answers" {
  let provider = @fake.Fake::calls("add", Json::object(Map([])))
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model")
    .with_tools([adder()])
    .with_limits(@agent.default_limits.with_iterations(3)),
  )
  let outcome = Ok(agent.run("loop")) catch { error => Err(error) }
  match outcome {
    Ok(_) => fail("the run should have hit the cap")
    Err(@agent.Exhausted(limit~)) => assert_eq(limit, 3)
    Err(other) => fail("unexpected " + @agent.describe(other))
  }
}

///|
async test "a provider failure surfaces as a refusal" {
  let provider = @fake.Fake::failing(500)
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model"),
  )
  let outcome = Ok(agent.run("hello")) catch { error => Err(error) }
  match outcome {
    Ok(_) => fail("the run should have failed")
    Err(@agent.Refused(reason~)) => assert_eq(reason.contains("500"), true)
    Err(other) => fail("unexpected " + @agent.describe(other))
  }
}

///|
async test "a missing tool is reported to the model, not raised" {
  let provider = @fake.Fake::new([
    call_reply("nope", Json::object(Map([]))),
    text_reply("sorry"),
  ])
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model"),
  )
  assert_eq(agent.run("use a tool"), "sorry")
}

///|
async test "the system message is seeded once" {
  let provider = @fake.Fake::text("ok")
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model").with_instructions("be brief"),
  )
  let _ = agent.run("hello")
  let messages = provider.seen()[0].messages
  assert_eq(messages.length(), 2)
  assert_eq(messages[0].role, @moonmuse.System)
  assert_eq(messages[0].text_content(), "be brief")
}

///|
async test "a checkpointed thread can be read back" {
  let provider = @fake.Fake::text("remembered")
  let saver = @moonstate.MemorySaver::new()
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model"),
    saver~,
  )
  let _ = agent.run("first", thread="t1")
  let snapshot = agent.state("t1").unwrap()
  assert_eq(snapshot.state.text(), "remembered")
}
