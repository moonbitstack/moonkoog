// Cases from the test suite this framework is measured against, transcribed one by one: the
// strategy graph's nodes and edges, the presets, history compression, agent-as-tool, the event
// stream and a checkpoint. The mapping table is in the delivery note; the name after `koog:` is
// the upstream test.

///|
/// Two integers added by a tool, for the tool-call cases.
fn koog_adder() -> @agent.ToolSpec {
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
    run=fn(_args, _context) { "42" },
  )
}

///|
/// The nodes a run started, in order.
fn koog_nodes(events : Array[@agent.Event]) -> Array[String] {
  let names : Array[String] = []
  for event in events {
    if event is NodeStarted(name~) {
      names.push(name)
    }
  }
  names
}

///|
async test "koog: testSend — a message runs the model, the tool, the model, then the exit" {
  let provider = @fake.Fake::new([
    call_reply(
      "add",
      Json::object(Map([("a", Json::number(2.0)), ("b", Json::number(40.0))])),
    ),
    text_reply("Buy!"),
  ])
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model").with_tools([koog_adder()]),
  )
  let events : Array[@agent.Event] = []
  let answer = agent.stream("Koog", event => events.push(event))
  assert_eq(answer, "Buy!")
  assert_eq(koog_nodes(events), ["agent", "model", "tools", "model", "finish"])
  // The tool's answer travels back to the model as a result part of a tool message, which is
  // what the request sent after the tool node carries.
  let second = provider.seen()[1].messages
  let last = second[second.length() - 1]
  assert_eq(last.role is Tool, true)
  assert_eq(last.results().length(), 1)
}

///|
async test "koog: testEdgeOnToolCall — a reply that asks for a tool goes through the tools node" {
  let provider = @fake.Fake::new([
    call_reply("add", Json::object(Map([]))),
    text_reply("Done"),
  ])
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model").with_tools([koog_adder()]),
  )
  let events : Array[@agent.Event] = []
  let answer = agent.stream("", event => events.push(event))
  assert_eq(answer, "Done")
  assert_eq(koog_nodes(events), ["agent", "model", "tools", "model", "finish"])
}

///|
async test "koog: testEdgeOnToolCall — a reply in prose goes straight to the exit" {
  let provider = @fake.Fake::text("Done")
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model").with_tools([koog_adder()]),
  )
  let events : Array[@agent.Event] = []
  let answer = agent.stream("", event => events.push(event))
  assert_eq(answer, "Done")
  assert_eq(koog_nodes(events), ["agent", "model", "finish"])
}

///|
async test "koog: testEdgeOnToolCallWithCondition — only the exit tool ends the chat" {
  let provider = @fake.Fake::new([
    call_reply("add", Json::object(Map([]))),
    call_reply("__exit__", Json::object(Map([])), id="call_2"),
  ])
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::chat("test-model"),
  )
  let events : Array[@agent.Event] = []
  let answer = agent.stream("", event => events.push(event))
  assert_eq(answer, "Chat finished")
  // The add tool runs, then the exit tool ends the run there rather than asking again.
  assert_eq(koog_nodes(events), [
    "agent", "model", "tools", "model", "tools", "finish",
  ])
  assert_eq(provider.hits(), 2)
}

///|
async test "koog: testChatStrategyDefaultName" {
  let agent = @agent.create_agent(
    @fake.Fake::text("hi"),
    @agent.AgentConfig::chat("test-model"),
  )
  assert_eq(agent.strategy_name(), "chat")
}

///|
async test "koog: testReActStrategyDefaultName" {
  let agent = @agent.create_agent(
    @fake.Fake::text("hi"),
    @agent.AgentConfig::react("test-model"),
  )
  assert_eq(agent.strategy_name(), "re_act")
}

///|
async test "koog: testReActStrategyWithCustomReasoningInterval" {
  let agent = @agent.create_agent(
    @fake.Fake::text("hi"),
    @agent.AgentConfig::react("test-model", interval=2),
  )
  assert_eq(agent.strategy_name(), "re_act")
}

// Upstream's `testReActStrategyInvalidReasoningInterval` has no case here: an interval below one
// is a programming error, and this runtime stops the run rather than raising something a caller
// could catch, so the only way to observe it is the process ending.

///|
/// A conversation of `pairs` user turns and as many replies, seeded through a saver so the
/// compression node has something to fold.
fn koog_history(pairs : Int32) -> Array[@moonmuse.Message] {
  let messages : Array[@moonmuse.Message] = []
  for index in 0..<pairs {
    messages.push(@moonmuse.Message::user("question " + index.to_string()))
    messages.push(@moonmuse.Message::assistant("answer " + index.to_string()))
  }
  messages
}

///|
/// The body of the node that puts `pairs` turns of history in front of the compressor.
fn koog_seed(pairs : Int32) -> @agent.NodeFn {
  (_runtime, _state, _run) => {
    [
      @moonstate.Step::Write(@agent.Update::Replace(koog_history(pairs))),
      @moonstate.Step::Goto("compress"),
    ]
  }
}

///|
/// A strategy that starts from seeded history, compresses it, and exits.
fn koog_compression(policy : @agent.HistoryPolicy) -> @agent.Strategy {
  @agent.Strategy::new("compress")
  .node(@agent.agent_node, @agent.NodeKind::Start(then="seed"))
  .edge(@agent.agent_node, "seed")
  .node("seed", @agent.NodeKind::Custom("seed"))
  .edge("seed", "compress")
  .node("compress", @agent.NodeKind::Compress(policy))
  .node(@agent.finish_node, @agent.NodeKind::Finish)
  .edge("compress", @agent.finish_node)
}

///|
async test "koog: testNodeLLMCompressHistoryWithWholeHistory — one summary replaces the history" {
  let provider = @fake.Fake::text("TLDR: the conversation so far")
  let saver = @moonstate.MemorySaver::new()
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model")
    .with_strategy(koog_compression(@agent.HistoryPolicy::Whole))
    .with_node("seed", koog_seed(6)),
    saver~,
  )
  let _ = agent.run("go", thread="compressed")
  let messages = agent.state("compressed").unwrap().state.messages()
  // The whole history is gone, replaced by the one summary the model wrote.
  assert_eq(messages.length(), 1)
  assert_eq(
    messages[0]
    .text_content()
    .has_prefix("Summary of the earlier conversation: TLDR"),
    true,
  )
}

///|
async test "koog: testNodeLLMCompressHistoryWithFromLastNMessages — the newest turns are kept" {
  let provider = @fake.Fake::text("TLDR: everything before the tail")
  let saver = @moonstate.MemorySaver::new()
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model")
    .with_strategy(koog_compression(@agent.HistoryPolicy::FromLast(2)))
    .with_node("seed", koog_seed(6)),
    saver~,
  )
  let _ = agent.run("go", thread="tail")
  let messages = agent.state("tail").unwrap().state.messages()
  // The summary, then the two newest turns as they were.
  assert_eq(messages.length(), 3)
  assert_eq(
    messages[0]
    .text_content()
    .has_prefix("Summary of the earlier conversation: TLDR"),
    true,
  )
  assert_eq(messages[1].text_content(), "question 5")
  assert_eq(messages[2].text_content(), "answer 5")
}

///|
async test "koog: testAsToolCreation — another agent becomes a tool with a message argument" {
  let other = @agent.create_agent(
    @fake.Fake::text("the other agent"),
    @agent.AgentConfig::new("test-model", name="testAgent"),
  )
  let tool = @multi.as_tool(other, description="Test agent description")
  assert_eq(tool.tool.name, "testAgent")
  assert_eq(tool.tool.description, "Test agent description")
  let schema = tool.tool.schema
  assert_eq(
    match schema {
      Object(fields) =>
        match fields.get("required") {
          Some(Array(items)) => items.length()
          _ => 0
        }
      _ => 0
    },
    1,
  )
}

///|
async test "koog: testAsToolExecution — the tool answers with the other agent's reply" {
  let other = @agent.create_agent(
    @fake.Fake::text("the other agent"),
    @agent.AgentConfig::new("test-model", name="testAgent"),
  )
  let provider = @fake.Fake::new([
    call_reply(
      "testAgent",
      Json::object(Map([("message", Json::string("what is your name?"))])),
    ),
    text_reply("done"),
  ])
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model").with_tools([@multi.as_tool(other)]),
  )
  let answer = agent.run("ask the other agent")
  assert_eq(answer, "done")
  let messages = provider.seen()[1].messages
  let result = messages[messages.length() - 1].results()[0]
  assert_eq(
    match result {
      @moonmuse.Part::Result(content~, ..) => content
      _ => ""
    },
    "the other agent",
  )
}

///|
async test "koog: testAsToolErrorHandling — a failed run comes back as text, not an exception" {
  let other = @agent.create_agent(
    @fake.Fake::failing(500),
    @agent.AgentConfig::new("test-model", name="testAgent"),
  )
  let provider = @fake.Fake::new([
    call_reply(
      "testAgent",
      Json::object(Map([("message", Json::string("hello"))])),
    ),
    text_reply("done"),
  ])
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model").with_tools([@multi.as_tool(other)]),
  )
  assert_eq(agent.run("ask"), "done")
  let messages = provider.seen()[1].messages
  let result = messages[messages.length() - 1].results()[0]
  let text = match result {
    @moonmuse.Part::Result(content~, ..) => content
    _ => ""
  }
  assert_eq(text.has_prefix("error: the agent failed: "), true)
}

///|
async test "koog: test event handler single node with tools — the run reports every node" {
  let provider = @fake.Fake::new([
    call_reply("add", Json::object(Map([]))),
    text_reply("Buy!"),
  ])
  let started : Array[String] = []
  let finished : Array[String] = []
  let events = @agent.EventHandler::new()
    .on_node_execution_starting(name => started.push(name))
    .on_node_execution_completed(name => finished.push(name))
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model")
    .with_tools([koog_adder()])
    .with_events(events),
  )
  let _ = agent.run("Koog")
  assert_eq(started, ["agent", "model", "tools", "model", "finish"])
  assert_eq(finished, ["agent", "model", "tools", "model", "finish"])
}

///|
async test "koog: two handlers registered for the same event are both called" {
  let first : Array[String] = []
  let second : Array[String] = []
  let handlers = @agent.EventHandler::new()
    .on_agent_starting(text => first.push(text))
    .on_agent_starting(text => second.push(text))
  let agent = @agent.create_agent(
    @fake.Fake::text("hi"),
    @agent.AgentConfig::new("test-model").with_events(handlers),
  )
  let _ = agent.run("go")
  assert_eq(first, ["go"])
  assert_eq(second, ["go"])
}

///|
async test "koog: test pipeline interceptors for tool call events — the arguments are rewritten" {
  let seen = Ref("")
  let tool = @agent.ToolSpec::new(
    name="record",
    description="Record what it was given.",
    schema=Json::object(Map([("type", Json::string("object"))])),
    run=fn(args, _context) {
      seen.val = match args {
        Object(fields) =>
          match fields.get("text") {
            Some(String(text)) => text
            _ => ""
          }
        _ => ""
      }
      "recorded"
    },
  )
  let handlers = @agent.EventHandler::new().intercept_tool_call_starting((
    _tool,
    _args,
  ) => Json::object(Map([("text", Json::string("rewritten"))])))
  let agent = @agent.create_agent(
    @fake.Fake::new([
      call_reply(
        "record",
        Json::object(Map([("text", Json::string("original"))])),
      ),
      text_reply("done"),
    ]),
    @agent.AgentConfig::new("test-model")
    .with_tools([tool])
    .with_events(handlers),
  )
  let _ = agent.run("go")
  assert_eq(seen.val, "rewritten")
}

///|
async test "koog: ReceivedToolResult is a result part, not text in the history" {
  let provider = @fake.Fake::new([
    call_reply("add", Json::object(Map([]))),
    text_reply("done"),
  ])
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model").with_tools([koog_adder()]),
  )
  let _ = agent.run("go")
  let messages = provider.seen()[1].messages
  let tool_message = messages[messages.length() - 1]
  assert_eq(tool_message.results().length(), 1)
  assert_eq(tool_message.text_content(), "")
}

///|
async test "koog: checkpoint serialization — a thread reads back with the same conversation" {
  let provider = @fake.Fake::new([text_reply("first answer")])
  let saver = @moonstate.MemorySaver::new()
  let first = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model"),
    saver~,
  )
  let _ = first.run("hello", thread="kept")
  let written = first.state("kept").unwrap()
  let again = @agent.create_agent(
    @fake.Fake::text("second answer"),
    @agent.AgentConfig::new("test-model"),
    saver~,
  )
  let read = again.state("kept").unwrap()
  assert_eq(read.state.messages().length(), written.state.messages().length())
  assert_eq(read.id, written.id)
  assert_eq(read.state.messages()[0].text_content(), "hello")
}

///|
/// A reply that asks for two tool calls in the same turn — the parallel-tools case.
fn koog_parallel_calls(
  name : String,
  first : Json,
  second : Json,
) -> @moonmuse.Reply {
  @moonmuse.Reply::new(
    @moonmuse.Message::new(Assistant, [
      @moonmuse.Part::call("call_1", name, first),
      @moonmuse.Part::call("call_2", name, second),
    ]),
    finish=@moonmuse.Finish::Calls,
  )
}

///|
/// A schema with one required number, which is the shape the two simple cases ask for.
fn koog_meeting_schema() -> Json {
  Json::object(
    Map([
      ("type", Json::string("object")),
      (
        "properties",
        Json::object(
          Map([("slots", Json::object(Map([("type", Json::string("number"))])))]),
        ),
      ),
      ("required", Json::array([Json::string("slots")])),
    ]),
  )
}

///|
async test "koog: testStructuredOutputWithToolsStrategyDefaultName — tools, then an answer that fits" {
  let strategy = @agent.structured_output()
  assert_eq(strategy.name, "structured_output_with_tools")
  let provider = @fake.Fake::new([
    call_reply(
      "add",
      Json::object(Map([("a", Json::number(2.0)), ("b", Json::number(40.0))])),
    ),
    text_reply("the total is 42"),
    text_reply("{\"slots\": 3}"),
  ])
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model")
    .with_tools([koog_adder()])
    .with_structured(@agent.Structured::new("meeting", koog_meeting_schema()))
    .with_strategy(strategy),
  )
  let events : Array[@agent.Event] = []
  let answer = agent.stream("book a meeting for three", event => {
    events.push(event)
  })
  assert_eq(answer.contains("\"slots\""), true)
  assert_eq(answer.contains("3"), true)
  // The run walks the structure node, which is where the schema is enforced.
  assert_eq(koog_nodes(events).contains("structure"), true)
  assert_eq(provider.seen().length(), 3)
}

///|
async test "koog: testStructuredOutputWithToolsStrategyWithParallelTools — two calls, one answer" {
  let provider = @fake.Fake::new([
    koog_parallel_calls(
      "add",
      Json::object(Map([("a", Json::number(1.0)), ("b", Json::number(1.0))])),
      Json::object(Map([("a", Json::number(2.0)), ("b", Json::number(2.0))])),
    ),
    text_reply("both sums are in"),
    text_reply("{\"slots\": 2}"),
  ])
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model")
    .with_tools([koog_adder()])
    .with_structured(@agent.Structured::new("meeting", koog_meeting_schema()))
    .with_strategy(@agent.structured_output()),
  )
  let answer = agent.run("two sums, then a meeting")
  assert_eq(answer.contains("\"slots\""), true)
  // Both calls of the same reply are executed before the model is asked again.
  let events : Array[@agent.Event] = []
  let _ = @agent.create_agent(
    @fake.Fake::new([
      koog_parallel_calls(
        "add",
        Json::object(Map([("a", Json::number(1.0)), ("b", Json::number(1.0))])),
        Json::object(Map([("a", Json::number(2.0)), ("b", Json::number(2.0))])),
      ),
      text_reply("done"),
      text_reply("{\"slots\": 2}"),
    ]),
    @agent.AgentConfig::new("test-model")
    .with_tools([koog_adder()])
    .with_structured(@agent.Structured::new("meeting", koog_meeting_schema()))
    .with_strategy(@agent.structured_output()),
  ).stream("again", event => events.push(event))
  let mut executed = 0
  for event in events {
    if event is ToolStarted(_) {
      executed = executed + 1
    }
  }
  assert_eq(executed, 2)
}

///|
async test "koog: testStructuredOutputWithToolsStrategyComplexTypes — a nested object survives" {
  let schema = Json::object(
    Map([
      ("type", Json::string("object")),
      (
        "properties",
        Json::object(
          Map([
            (
              "who",
              Json::object(
                Map([
                  ("type", Json::string("object")),
                  (
                    "properties",
                    Json::object(
                      Map([
                        (
                          "name",
                          Json::object(Map([("type", Json::string("string"))])),
                        ),
                        (
                          "tags",
                          Json::object(
                            Map([
                              ("type", Json::string("array")),
                              (
                                "items",
                                Json::object(
                                  Map([("type", Json::string("string"))]),
                                ),
                              ),
                            ]),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    ]),
  )
  let provider = @fake.Fake::new([
    text_reply(
      "{\"who\": {\"name\": \"ada\", \"tags\": [\"host\", \"guest\"]}}",
    ),
  ])
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model")
    .with_structured(@agent.Structured::new("guest", schema))
    .with_strategy(@agent.structured_output()),
  )
  let answer = agent.run("who is coming?")
  assert_eq(answer.contains("ada"), true)
  assert_eq(answer.contains("host"), true)
  assert_eq(answer.contains("guest"), true)
}

///|
async test "koog: testStructuredOutputWithToolsStrategyDifferentConfigs — each agent keeps its schema" {
  let slots = @fake.Fake::new([text_reply("{\"slots\": 4}")])
  let meetings = @agent.create_agent(
    slots,
    @agent.AgentConfig::new("test-model")
    .with_structured(@agent.Structured::new("meeting", koog_meeting_schema()))
    .with_strategy(@agent.structured_output()),
  )
  let name_schema = Json::object(
    Map([
      ("type", Json::string("object")),
      (
        "properties",
        Json::object(
          Map([("name", Json::object(Map([("type", Json::string("string"))])))]),
        ),
      ),
    ]),
  )
  let people = @fake.Fake::new([text_reply("{\"name\": \"ada\"}")])
  let guests = @agent.create_agent(
    people,
    @agent.AgentConfig::new("test-model")
    .with_structured(@agent.Structured::new("guest", name_schema))
    .with_strategy(@agent.structured_output()),
  )
  assert_eq(meetings.run("four people").contains("\"slots\""), true)
  assert_eq(guests.run("who").contains("\"name\""), true)
}
