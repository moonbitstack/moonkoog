// The graph this library builds for a single run, replayed against the sequence another engine
// produced for the same graph: the same four nodes, the same scripted answers, the same steps.

///|
/// A tool that echoes what it was given.
fn echoed_tool() -> ToolSpec {
  ToolSpec::new(
    name="echo",
    description="Echo the text back.",
    schema=Json::object(
      Map([
        ("type", Json::string("object")),
        (
          "properties",
          Json::object(
            Map([
              ("text", Json::object(Map([("type", Json::string("string"))]))),
            ]),
          ),
        ),
      ]),
    ),
    run=fn(args, _context) {
      let text = match args {
        Object(fields) =>
          match fields.get("text") {
            Some(String(text)) => text
            _ => ""
          }
        _ => ""
      }
      "echoed " + text
    },
  )
}

///|
/// The steps a run's stream projects to, in the vocabulary the fixture is written in: a node was
/// entered, a tool ran, and the run settled on an answer.
fn projected(events : Array[Event], answer : String) -> Array[String] {
  let steps : Array[String] = []
  for event in events {
    match event {
      NodeStarted(name~) => steps.push("node:" + name)
      ToolStarted(name~, ..) => steps.push("tool:" + name)
      _ => ()
    }
  }
  steps.push("answer:" + answer)
  steps
}

///|
async test "langgraph: the same graph and the same scripted answers yield the same steps" {
  let provider = @fake.Fake::new([
    @moonmuse.Reply::new(
      @moonmuse.Message::new(@moonmuse.Assistant, [
        @moonmuse.Part::call(
          "call_1",
          "echo",
          Json::object(Map([("text", Json::string("hello"))])),
        ),
      ]),
      finish=@moonmuse.Finish::Calls,
    ),
    @moonmuse.Reply::new(@moonmuse.Message::assistant("done")),
  ])
  let agent = create_agent(
    provider,
    AgentConfig::new("stub", name="compared").with_tools([echoed_tool()]),
  )
  let events : Array[Event] = []
  let answer = agent.stream("hello", event => events.push(event))
  let steps = projected(events, answer)
  assert_eq(steps.length(), langgraph_steps.length())
  for index, step in steps {
    assert_eq(step, langgraph_steps[index])
  }
  assert_eq(steps, [
    "node:agent", "node:model", "node:tools", "tool:echo", "node:model", "node:finish",
    "answer:done",
  ])
}
