// The agent as an A2A client against a server in another process: the peer is the official
// Python SDK's server, started here, and the run reaches it the way any caller would — over a
// socket, through the card the peer publishes.
//
//     moon run --target native integration/src/a2a-client -- <path to a2a_server.py>

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
/// The tool answer the model was shown last, which is what the remote agent said.
fn last_result(provider : @fake.Fake) -> String {
  let seen = provider.seen()
  let messages = seen[seen.length() - 1].messages
  let last = messages[messages.length() - 1]
  let results = last.results()
  guard results.length() > 0 else { return last.text_content() }
  match results[results.length() - 1] {
    @moonmuse.Part::Result(content~, ..) => content
    _ => ""
  }
}

///|
/// The number in the line the peer prints when its socket is bound.
fn port_of(line : String) -> Int32 {
  let digits = line.split("=").collect()
  guard digits.length() > 1 else { return 0 }
  // The line ends with the platform's newline, which is part of the text `read_until` leaves
  // behind beyond the separator, so only the digits are read and anything else ends the number.
  let mut port = 0
  for digit in digits[1] {
    guard digit >= '0' && digit <= '9' else { break }
    port = port * 10 + (digit.to_int() - '0'.to_int())
  }
  port
}

///|
fn fail(reason : String) -> Unit {
  println("a2a-client: " + reason)
  abort("a2a-client: " + reason)
}

///|
/// The check, with the peer started into `group` so that the server cannot outlive it.
async fn check(group : @async.TaskGroup[Unit]) -> Unit {
  let args = @env.args()
  let script = if args.length() > 1 { args[1] } else { "peers/a2a_server.py" }
  let python = @env.get_env_var("MOONKOOG_PYTHON").unwrap_or("python3")

  let (from_peer, sink) = @process.read_from_process()
  let child = @process.spawn(group, python, [script], stdout=sink)
  let announced = from_peer.read_until("\n")
  let port = match announced {
    Some(line) => port_of(line)
    None => 0
  }
  if port == 0 {
    fail("the peer did not say which port it bound: " + announced.unwrap_or(""))
  }
  println("a2a-client: the peer listens on port " + port.to_string())

  let transport = @fetch.HttpTransport::new(
    "http://127.0.0.1:" + port.to_string(),
  )
  let provider = @fake.Fake::new([
    call_reply(
      "python_peer",
      Json::object(Map([("message", Json::string("hello"))])),
    ),
    text_reply("done"),
  ])
  let agent = @moonkoog.create_agent(
    provider,
    @moonkoog.AgentConfig::new("scripted", name="delegator").with_tools([
      @a2a.remote_tool(
        transport,
        name="python_peer",
        description="Ask the agent on the other side of the socket.",
      ),
    ]),
  )
  let answer = agent.run("delegate this")
  let remote = last_result(provider)
  if remote != "answered by the Python agent" {
    fail("the remote agent answered \"" + remote + "\"")
  }
  if answer != "done" {
    fail("the run settled on \"" + answer + "\"")
  }
  println("a2a-client: the remote agent answered " + remote)
  child.cancel()
  ignore(child.wait())
  println("a2a-client: a run reached another process over A2A")
}

///|
async fn main {
  @async.with_task_group(async fn(group) { check(group) })
}
