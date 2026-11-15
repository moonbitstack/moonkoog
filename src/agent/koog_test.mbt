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

///|
async test "koog: test event handler for agent without nodes and tools — a run without tools reports three positions" {
  let positions : Array[String] = []
  let opened : Array[String] = []
  let closed : Array[String] = []
  let handlers = @agent.EventHandler::new()
    .on_agent_starting(text => opened.push("agent:" + text))
    .on_strategy_starting(name => opened.push("strategy:" + name))
    .on_strategy_completed((name, _text) => closed.push("strategy:" + name))
    .on_agent_completed(text => closed.push("agent:" + text))
    .on_node_execution_starting(name => positions.push(name))
  let agent = @agent.create_agent(
    @fake.Fake::text("done"),
    @agent.AgentConfig::new("test-model", name="bare").with_events(handlers),
  )
  let _ = agent.run("go")
  // No tools are advertised, so the walk is the agent, one request, and the exit.
  assert_eq(positions, ["agent", "model", "finish"])
  assert_eq(opened, ["agent:go", "strategy:single_run"])
  assert_eq(closed, ["strategy:single_run", "agent:done"])
}

///|
async test "koog: test event handler several nodes — a longer walk reports each position in order" {
  let positions : Array[String] = []
  let handlers = @agent.EventHandler::new().on_node_execution_starting(name => {
    positions.push(name)
  })
  let agent = @agent.create_agent(
    @fake.Fake::new([
      call_reply("add", Json::object(Map([]))),
      text_reply("the total is 42"),
      text_reply("{\"slots\": 3}"),
    ]),
    @agent.AgentConfig::new("test-model")
    .with_tools([koog_adder()])
    .with_structured(@agent.Structured::new("meeting", koog_meeting_schema()))
    .with_strategy(@agent.structured_output())
    .with_events(handlers),
  )
  let _ = agent.run("book a meeting")
  assert_eq(positions, [
    "agent", "model", "tools", "model", "structure", "finish",
  ])
}

///|
async test "koog: test event handler for agent with node execution error — the failing position is named" {
  let failed : Array[(String, String)] = []
  let ended : Array[String] = []
  let handlers = @agent.EventHandler::new()
    .on_node_execution_failed((name, reason) => failed.push((name, reason)))
    .on_agent_execution_failed(reason => ended.push(reason))
  let config = @agent.AgentConfig::new("test-model", name="broken")
    .with_strategy(
      @agent.Strategy::new("two-step")
      .node(@agent.agent_node, @agent.Start(then="boom"))
      .node("boom", @agent.Custom("boom"))
      .node(@agent.finish_node, @agent.Finish)
      .edge(@agent.agent_node, "boom")
      .edge("boom", @agent.finish_node),
    )
    .with_node("boom", (_runtime, _state, _run) => fail("boom"))
    .with_events(handlers)
  let agent = @agent.create_agent(@fake.Fake::text("unused"), config)
  let outcome = Ok(agent.run("go")) catch { error => Err(error) }
  assert_eq(outcome is Err(_), true)
  assert_eq(failed.length(), 1)
  assert_eq(failed[0].0, "boom")
  assert_eq(failed[0].1.contains("boom"), true)
  assert_eq(ended.length(), 1)
}

///|
async test "koog: test llm streaming events success — deltas arrive, then the reply" {
  let frames : Array[String] = []
  let started : Array[Int32] = []
  let finished : Array[String] = []
  let handlers = @agent.EventHandler::new()
    .on_llm_streaming_starting(_request => started.push(1))
    .on_llm_streaming_frame(chunk => frames.push(chunk))
    .on_llm_streaming_completed(reply => {
      finished.push(reply.message.text_content())
    })
  let agent = @agent.create_agent(
    @fake.Fake::text("hello there"),
    @agent.AgentConfig::new("test-model")
    .with_strategy(@agent.single_run(streaming=true))
    .with_events(handlers),
  )
  let answer = agent.run("greet")
  assert_eq(answer, "hello there")
  assert_eq(started.length(), 1)
  // The scripted provider slices the text into five-character deltas.
  assert_eq(frames.length(), 3)
  assert_eq(frames[0], "hello")
  assert_eq(finished, ["hello there"])
}

///|

///|
/// A provider whose stream breaks after the first delta — the failure the upstream case covers.
struct BrokenStream {}

///|
impl @moonmuse.Provider for BrokenStream with fn chat(self, request) {
  ignore(self)
  ignore(request)
  raise @moonmuse.LlmError::Stream("the stream broke")
}

///|
impl @moonmuse.Provider for BrokenStream with fn stream(self, request, on_delta) {
  ignore(self)
  ignore(request)
  on_delta(@moonmuse.Delta::Text("half"))
  raise @moonmuse.LlmError::Stream("the stream broke")
}

///|
impl @moonmuse.Provider for BrokenStream with fn embed(self, model, inputs) {
  ignore(self)
  ignore(model)
  ignore(inputs)
  raise @moonmuse.LlmError::Unsupported("no vectors here")
}

///|
impl @moonmuse.Provider for BrokenStream with fn models(self) {
  ignore(self)
  []
}

///|
async test "koog: test llm streaming events failure — a stream that breaks ends the run" {
  let started : Array[Int32] = []
  let frames : Array[String] = []
  let finished : Array[String] = []
  let handlers = @agent.EventHandler::new()
    .on_llm_streaming_starting(_request => started.push(1))
    .on_llm_streaming_frame(chunk => frames.push(chunk))
    .on_llm_streaming_completed(reply => {
      finished.push(reply.message.text_content())
    })
  let agent = @agent.create_agent(
    BrokenStream::{ },
    @agent.AgentConfig::new("test-model")
    .with_strategy(@agent.single_run(streaming=true))
    .with_events(handlers),
  )
  let outcome = Ok(agent.run("greet")) catch { error => Err(error) }
  assert_eq(outcome is Err(_), true)
  assert_eq(started.length(), 1)
  // The delta that arrived before the break is reported; nothing completed.
  assert_eq(frames, ["half"])
  assert_eq(finished.length(), 0)
}

///|
async test "koog: test subgraph execution events success — a nested graph is reported as one" {
  let inner = @agent.create_agent(
    @fake.Fake::text("inner answer"),
    @agent.AgentConfig::new("test-model", name="inner"),
  )
  let nested : Array[String] = []
  let texts : Array[String] = []
  let handlers = @agent.EventHandler::new()
    .on_subgraph_execution_starting(name => nested.push("start:" + name))
    .on_subgraph_execution_completed((name, text) => {
      nested.push("done:" + name)
      texts.push(text)
    })
  let strategy = @agent.Strategy::new("outer")
    .node(@agent.agent_node, @agent.Start(then="inner"))
    .node("inner", @agent.Delegate(inner.graph()))
    .node(@agent.finish_node, @agent.Finish)
    .edge(@agent.agent_node, "inner")
    .edge("inner", @agent.finish_node)
  let outer = @agent.create_agent(
    @fake.Fake::text("outer"),
    @agent.AgentConfig::new("test-model", name="outer")
    .with_strategy(strategy)
    .with_events(handlers),
  )
  let answer = outer.run("go")
  assert_eq(answer, "inner answer")
  assert_eq(nested, ["start:inner", "done:inner"])
  assert_eq(texts.length(), 1)
  assert_eq(texts[0], "inner answer")
}

///|
async test "koog: test pipeline interceptors for llm call events — request and reply are both rewritten" {
  let seen : Array[String] = []
  let handlers = @agent.EventHandler::new()
    .intercept_llm_call_starting(request => {
      seen.push("asked")
      request.push(@moonmuse.Message::user("and one more thing"))
    })
    .intercept_llm_call_completed(_reply => {
      @moonmuse.Reply::new(@moonmuse.Message::assistant("rewritten"))
    })
  let provider = @fake.Fake::text("original")
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model").with_events(handlers),
  )
  let answer = agent.run("go")
  assert_eq(seen, ["asked"])
  assert_eq(answer, "rewritten")
  // The interceptor's extra message travelled to the provider.
  let sent = provider.seen()[0]
  assert_eq(
    sent.messages[sent.messages.length() - 1].text_content(),
    "and one more thing",
  )
}

///|
async test "koog: test pipeline interceptors before agent started events — the opening hooks run in order" {
  let order : Array[String] = []
  let handlers = @agent.EventHandler::new()
    .on_agent_starting(_text => order.push("agent"))
    .on_strategy_starting(_name => order.push("strategy"))
    .on_llm_call_starting(_request => order.push("llm"))
    .on_node_execution_starting(name => order.push("node:" + name))
  let agent = @agent.create_agent(
    @fake.Fake::text("ok"),
    @agent.AgentConfig::new("test-model").with_events(handlers),
  )
  let _ = agent.run("go")
  // The model-call hook fires inside the model position, so the node reports first.
  assert_eq(order, [
    "agent", "strategy", "node:agent", "node:model", "llm", "node:finish",
  ])
}

///|
async test "koog: test several agents share one pipeline — one handler set reports both runs" {
  let texts : Array[String] = []
  let handlers = @agent.EventHandler::new().on_agent_starting(text => {
    texts.push(text)
  })
  let first = @agent.create_agent(
    @fake.Fake::text("one"),
    @agent.AgentConfig::new("test-model", name="first").with_events(handlers),
  )
  let second = @agent.create_agent(
    @fake.Fake::text("two"),
    @agent.AgentConfig::new("test-model", name="second").with_events(handlers),
  )
  let _ = first.run("from first")
  let _ = second.run("from second")
  assert_eq(texts, ["from first", "from second"])
}

///|
async test "koog: test handlers are called in feature installation order" {
  let order : Array[String] = []
  let handlers = @agent.EventHandler::new()
    .on_llm_call_starting(_request => order.push("first"))
    .on_llm_call_starting(_request => order.push("second"))
    .on_llm_call_starting(_request => order.push("third"))
  let agent = @agent.create_agent(
    @fake.Fake::text("ok"),
    @agent.AgentConfig::new("test-model").with_events(handlers),
  )
  let _ = agent.run("go")
  assert_eq(order, ["first", "second", "third"])
}

///|
async test "koog: test AgentExecutionInfo for tool calls — the context names the agent, the model and the step" {
  let seen : Array[String] = []
  let tool = @agent.ToolSpec::new(
    name="report",
    description="Report the context it was given.",
    schema=Json::object(Map([("type", Json::string("object"))])),
    run=fn(_args, context) {
      seen.push(
        context.name + "|" + context.model + "|" + context.step.to_string(),
      )
      "reported"
    },
  )
  let agent = @agent.create_agent(
    @fake.Fake::new([
      call_reply("report", Json::object(Map([]))),
      text_reply("done"),
    ]),
    @agent.AgentConfig::new("test-model", name="profiler").with_tools([tool]),
  )
  let _ = agent.run("go")
  assert_eq(seen.length(), 1)
  // The name and the model come from the config; the step counts the supersteps taken so far.
  assert_eq(seen[0].contains("profiler|test-model|"), true)
}

///|
async test "koog: test filter llm call finish events — a handler can ignore a reply it does not want" {
  let kept : Array[String] = []
  let handlers = @agent.EventHandler::new().on_llm_call_completed(reply => {
    let text = reply.message.text_content()
    if text.contains("keep") {
      kept.push(text)
    }
  })
  let agent = @agent.create_agent(
    @fake.Fake::text("keep this"),
    @agent.AgentConfig::new("test-model").with_events(handlers),
  )
  let _ = agent.run("go")
  assert_eq(kept, ["keep this"])
  let quiet = @agent.create_agent(
    @fake.Fake::text("discard this"),
    @agent.AgentConfig::new("test-model").with_events(handlers),
  )
  let _ = quiet.run("go")
  assert_eq(kept.length(), 1)
}

///|
async test "koog: testConstructorWithDefaultStrategy — a config with no strategy runs the one-run loop" {
  let config = @agent.AgentConfig::new("test-model")
  assert_eq(config.name, "agent")
  assert_eq(config.model, "test-model")
  assert_eq(config.strategy is None, true)
  assert_eq(config.tools.length(), 0)
  assert_eq(config.limits.iterations, 50)
  assert_eq(config.limits.tool_calls, 200)
  let agent = @agent.create_agent(@fake.Fake::text("ok"), config)
  assert_eq(agent.strategy_name(), "single_run")
}

///|
async test "koog: testConstructorWithAllParameters — every field is kept as it was set" {
  let tool = koog_adder()
  let handlers = @agent.EventHandler::new()
  let config = @agent.AgentConfig::new("test-model", name="all-of-it")
    .with_instructions("be brief")
    .with_tools([tool])
    .with_strategy(@agent.chat())
    .with_limits(@agent.Limits::new())
    .with_events(handlers)
  assert_eq(config.name, "all-of-it")
  assert_eq(config.instructions, Some("be brief"))
  assert_eq(config.tools.length(), 1)
  assert_eq(config.tools[0].tool.name, "add")
  assert_eq(config.strategy.unwrap().name, "chat")
  // A strategy chosen this way carries no exit tool; the `chat` constructor is what adds one.
  assert_eq(config.exit_tool is None, true)
  let ending = @agent.AgentConfig::chat("test-model")
  assert_eq(ending.exit_tool, Some("__exit__"))
}

///|
async test "koog: testWithSystemPromptAllParameters — the instructions reach the model as a system message" {
  let provider = @fake.Fake::text("ok")
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model").with_instructions(
      "answer in one word",
    ),
  )
  let _ = agent.run("hello")
  let sent = provider.seen()[0]
  let system = sent.messages.filter(message => message.role is System)
  assert_eq(system.length(), 1)
  assert_eq(system[0].text_content(), "answer in one word")
}

///|
async test "koog: testWithSystemPromptDefaultParameters — a config without instructions sends none" {
  let provider = @fake.Fake::text("ok")
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model"),
  )
  let _ = agent.run("hello")
  let system = provider.seen()[0].messages.filter(message => {
    message.role is System
  })
  assert_eq(system.length(), 0)
}

///|
async test "koog: testZeroMaxIterations — a run with no model calls refuses at the first request" {
  let agent = @agent.create_agent(
    @fake.Fake::text("never"),
    @agent.AgentConfig::new("test-model").with_limits({
      iterations: 0,
      tool_calls: 0,
      steps: 10,
    }),
  )
  let outcome = Ok(agent.run("go")) catch { error => Err(error) }
  match outcome {
    Ok(_) => fail("the run should have been refused")
    Err(@agent.Exhausted(limit~)) => assert_eq(limit, 0)
    Err(other) => fail("unexpected " + @agent.describe(other))
  }
}

///|
async test "koog: testNegativeMaxIterations — a negative budget refuses the same way" {
  let agent = @agent.create_agent(
    @fake.Fake::text("never"),
    @agent.AgentConfig::new("test-model").with_limits({
      iterations: -1,
      tool_calls: -1,
      steps: 10,
    }),
  )
  let outcome = Ok(agent.run("go")) catch { error => Err(error) }
  match outcome {
    Ok(_) => fail("the run should have been refused")
    Err(@agent.Exhausted(limit~)) => assert_eq(limit, -1)
    Err(other) => fail("unexpected " + @agent.describe(other))
  }
}
