// Checkpoints in a real PostgreSQL: one process stops for approval, another one resumes the
// thread it left behind, and the tool runs only after the approval that arrived later.
//
//     moon run --target native integration/src/postgres-checkpoint -- run
//     moon run --target native integration/src/postgres-checkpoint -- resume
//
// `MOONKOOG_LIVE=1` means the server is expected; without it the program reports that it was
// skipped, so a checkout without a database still builds and runs.

///|
/// A reply that asks for one tool call.
fn call_reply(name : String, args : Json) -> @moonmuse.Reply {
  @moonmuse.Reply::new(
    @moonmuse.Message::new(Assistant, [@moonmuse.Part::call("call_1", name, args)]),
    finish=@moonmuse.Finish::Calls,
  )
}

///|
/// A reply that answers in prose.
fn text_reply(text : String) -> @moonmuse.Reply {
  @moonmuse.Reply::new(@moonmuse.Message::assistant(text))
}

///|
/// The tool the approval guards: it changes the world, so the run asks first.
fn marker() -> @agent.ToolSpec {
  @agent.ToolSpec::new(
    name="mark",
    description="Record that the work happened.",
    schema=Json::object(Map([("type", Json::string("object"))])),
    run=fn(_args, _context) { "marked" },
  )
}

///|
/// One setting, from the environment with the value a test container uses by default.
fn setting(name : String, fallback : String) -> String {
  @env.get_env_var(name).unwrap_or(fallback)
}

///|
/// The port from the environment, or the one PostgreSQL listens on.
fn port_setting() -> Int32 {
  let text = setting("PGPORT", "5432")
  let mut port = 0
  for digit in text {
    guard digit >= '0' && digit <= '9' else { break }
    port = port * 10 + (digit.to_int() - '0'.to_int())
  }
  port
}

///|
fn fail(reason : String) -> Unit {
  println("postgres-checkpoint: " + reason)
  abort("postgres-checkpoint: " + reason)
}

///|
/// The connection every run of this program opens; each process gets its own.
async fn connect() -> @moonpostgres.PgConn raise @moondb.DbError {
  @moonpostgres.PgConn::connect(
    setting("PGHOST", "127.0.0.1"),
    port_setting(),
    setting("PGUSER", "postgres"),
    setting("PGPASSWORD", "postgres"),
    setting("PGDATABASE", "postgres"),
  )
}

///|
/// A role as it reads in a transcript.
fn role_name(role : @moonmuse.Role) -> String {
  match role {
    System => "system"
    User => "user"
    Assistant => "assistant"
    Tool => "tool"
  }
}

///|
/// What a message carries: its text, or the result part a tool answer travels as.
fn message_text(message : @moonmuse.Message) -> String {
  let results = message.results()
  if results.length() == 0 {
    return message.text_content()
  }
  match results[results.length() - 1] {
    @moonmuse.Part::Result(content~, ..) => content
    _ => ""
  }
}

///|
/// The conversation as `role: text` lines, newest last, which is what a resumed run carries.
fn transcript(state : @agent.AgentState) -> Array[String] {
  state.messages().map(message => role_name(message.role) + ": " + message_text(message))
}

///|
/// Stop the run for approval and leave the thread in the table.
async fn start_run(thread : String) -> Int32 raise {
  let connection = connect()
  let saver = @sql.saver(connection)
  saver.setup()
  let provider = @fake.Fake::new([
    call_reply("mark", Json::object(Map([]))),
    text_reply("done"),
  ])
  let agent = @moonkoog.create_agent(
    provider,
    @moonkoog.AgentConfig::new("scripted", name="durable")
    .with_middleware(@middleware.HumanInTheLoop::new(["mark"]))
    .with_tools([marker()]),
    saver~,
  )
  let stopped = Ok(agent.run("do the work", thread~)) catch { error => Err(error) }
  match stopped {
    Ok(answer) => fail("the run finished without asking: " + answer)
    Err(@agent.Engine(@moonstate.GraphError::Interrupted(..))) => ()
    Err(error) => fail("the run failed instead of stopping: " + @agent.describe(error))
  }
  let history = agent.history(thread)
  if history.length() == 0 {
    fail("nothing was checkpointed")
  }
  println(
    "postgres-checkpoint: the run stopped for approval with " +
    history.length().to_string() +
    " checkpoint(s) in PostgreSQL",
  )
  history.length()
}

///|
/// Read the thread another process left behind, approve, and finish the run.
async fn finish_run(thread : String) -> Unit raise {
  let connection = connect()
  let saver = @sql.saver(connection)
  let provider = @fake.Fake::new([text_reply("done")])
  let agent = @moonkoog.create_agent(
    provider,
    @moonkoog.AgentConfig::new("scripted", name="durable")
    .with_middleware(@middleware.HumanInTheLoop::new(["mark"]))
    .with_tools([marker()]),
    saver~,
  )
  let history = agent.history(thread)
  if history.length() == 0 {
    fail("the thread the first process wrote is not in the table")
  }
  let stored = agent.state(thread)
  if stored is None {
    fail("the thread is not in the table")
  }
  let before = transcript(stored.unwrap().state)
  let answered = agent.resume_from(thread, Json::boolean(true))
  if answered != "done" {
    fail("the resumed run settled on \"" + answered + "\"")
  }
  let settled = agent.state(thread)
  if settled is None {
    fail("the thread vanished after the resume")
  }
  let after = transcript(settled.unwrap().state)
  let marked = after.any(line => line.starts_with("tool: marked"))
  if !marked {
    fail("the approved tool did not run: " + after.join(" | "))
  }
  if after.length() <= before.length() {
    fail("the resumed run added nothing to the conversation")
  }
  println(
    "postgres-checkpoint: resumed in another process, the conversation grew from " +
    before.length().to_string() +
    " to " +
    after.length().to_string() +
    " messages",
  )
  println("postgres-checkpoint: the approved tool ran and the thread is durable")
}

///|
async fn main {
  let args = @env.args()
  let mode = if args.length() > 1 { args[1] } else { "run" }
  if @env.get_env_var("MOONKOOG_LIVE") is None {
    println("postgres-checkpoint: skipped, MOONKOOG_LIVE is not set")
    return
  }
  let thread = setting("MOONKOOG_PG_THREAD", "interop-thread")
  if mode == "run" {
    let written = start_run(thread) catch {
      error => {
        println("postgres-checkpoint: " + error.to_string())
        abort("postgres-checkpoint: the run could not be started")
        0
      }
    }
    println("postgres-checkpoint: wrote " + written.to_string() + " checkpoint(s)")
  } else if mode == "resume" {
    finish_run(thread) catch {
      error => {
        println("postgres-checkpoint: " + error.to_string())
        abort("postgres-checkpoint: the run could not be resumed")
      }
    }
  } else {
    fail("usage: run | resume")
  }
}
