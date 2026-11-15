// What the tour page plays: three runs of this library, recorded as the steps they took.
//
// The page cannot run the agent itself — the run is asynchronous and the browser has no driver
// for the runtime this library uses — so the site replays what a real run produced. The recording
// is made here, from the same event stream an application observes, and the docs workflow writes
// it fresh on every deploy, so the page cannot show a transcript older than the code.
//
//     moon run --target native src/examples/browser            (JSON on stdout)
//     moon run --target native src/examples/browser -- answer  (one scenario)

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
/// The tool the tool-calling scenarios use.
fn moon_tool() -> @agent.ToolSpec {
  @agent.ToolSpec::new(
    name="lookup",
    description="Look up what is known about a body in the sky.",
    schema=Json::object(
      Map([
        ("type", Json::string("object")),
        (
          "properties",
          Json::object(
            Map([
              ("body", Json::object(Map([("type", Json::string("string"))]))),
            ]),
          ),
        ),
        ("required", Json::array([Json::string("body")])),
      ]),
    ),
    run=fn(args, _context) {
      let body = match args {
        Object(fields) =>
          match fields.get("body") {
            Some(String(text)) => text
            _ => "nothing"
          }
        _ => "nothing"
      }
      if body == "moon" {
        "the moon is 384,400 km away and has no atmosphere"
      } else {
        "no record of " + body
      }
    },
  )
}

///|
/// One step, in the shape the page reads.
fn step_of(kind : String, name : String, detail~ : String = "") -> Json {
  let fields = Map([("kind", Json::string(kind)), ("name", Json::string(name))])
  if detail != "" {
    fields["detail"] = Json::string(detail)
  }
  Json::object(fields)
}

///|
/// The steps one event is worth on the page. Only the boundaries a reader can see: a node is
/// entered or left, a tool runs, and the model call finishes with its token counts.
fn steps_of(event : @agent.Event) -> Array[Json] {
  match event {
    NodeStarted(name~) => [step_of("enter", name)]
    NodeFinished(name~) => [step_of("leave", name)]
    ToolFinished(name~, failed~, ..) =>
      [step_of("tool", name, detail=if failed { "failed" } else { "ok" })]
    ModelFinished(name~, usage~) => {
      // A provider that reports no counts is shown without them rather than with question marks.
      let detail = match (usage.input, usage.output) {
        (Some(input), Some(output)) =>
          input.to_string() + " in, " + output.to_string() + " out"
        _ => ""
      }
      [step_of("model", name, detail~)]
    }
    _ => []
  }
}

///|
/// Run `agent` on `input` and return the steps it took, then how it ended.
async fn record(agent : @agent.Agent, input : String, thread? : String) -> Json {
  let steps : Array[Json] = []
  let answered = Ok(
    agent.stream(
      input,
      event => {
        for step in steps_of(event) {
          steps.push(step)
        }
      },
      thread?,
    ),
  ) catch {
    error => Err(error)
  }
  match answered {
    Ok(answer) =>
      steps.push(
        Json::object(
          Map([
            ("kind", Json::string("answer")),
            ("name", Json::string("answer")),
            ("detail", Json::string(answer)),
          ]),
        ),
      )
    Err(error) =>
      steps.push(
        Json::object(
          Map([
            ("kind", Json::string("stop")),
            ("name", Json::string("stop")),
            ("detail", Json::string(@agent.describe(error))),
          ]),
        ),
      )
  }
  Json::object(
    Map([
      ("steps", Json::array(steps)),
      ("thread", Json::string(thread.unwrap_or(""))),
    ]),
  )
}

///|
/// A scenario: what the page shows before the run, and the run itself.
async fn scenario(id : String) -> Json {
  let mut asked = ""
  let (title, note, recorded) = match id {
    "answer" => {
      let provider = @fake.Fake::text(
        "The moon is a good place to start: no weather, no traffic.",
      )
      let agent = @agent.create_agent(
        provider,
        @agent.AgentConfig::new("scripted", name="guide"),
      )
      asked = "Where should we start?"
      (
        "One answer",
        "The model answers in prose, so the run goes from the start, through one model call, to the exit.",
        record(agent, "Where should we start?"),
      )
    }
    "tool" => {
      let provider = @fake.Fake::new([
        call_reply(
          "lookup",
          Json::object(Map([("body", Json::string("moon"))])),
        ),
        text_reply("The moon is 384,400 km away."),
      ])
      let agent = @agent.create_agent(
        provider,
        @agent.AgentConfig::new("scripted", name="guide").with_tools([
          moon_tool(),
        ]),
      )
      asked = "How far away is the moon?"
      (
        "One tool call",
        "The model asks for a tool instead of answering; the tool runs, its result goes back, and the second call answers.",
        record(agent, "How far away is the moon?"),
      )
    }
    _ => {
      let provider = @fake.Fake::new([
        call_reply(
          "lookup",
          Json::object(Map([("body", Json::string("moon"))])),
          id="a",
        ),
        call_reply(
          "lookup",
          Json::object(Map([("body", Json::string("sun"))])),
          id="b",
        ),
        text_reply("unreachable"),
      ])
      let agent = @agent.create_agent(
        provider,
        @agent.AgentConfig::new("scripted", name="guide")
        .with_tools([moon_tool()])
        .with_middleware(@middleware.ModelCallLimit::new(limit=2)),
      )
      asked = "Look up everything."
      (
        "A cap that holds",
        "The same loop with a cap of two model calls. The tool keeps being asked for, and the run stops where the cap says.",
        record(agent, "Look up everything."),
      )
    }
  }
  Json::object(
    Map([
      ("id", Json::string(id)),
      ("title", Json::string(title)),
      ("note", Json::string(note)),
      ("input", Json::string(asked)),
      ("run", recorded),
    ]),
  )
}

///|
async fn main {
  let wanted = @env.args()
  let ids = if wanted.length() > 1 {
    [wanted[1]]
  } else {
    ["answer", "tool", "cap"]
  }
  let scenarios : Array[Json] = []
  for id in ids {
    scenarios.push(scenario(id))
  }
  let document = Json::object(Map([("scenarios", Json::array(scenarios))]))
  println(@moonjson.dumps(document))
}
