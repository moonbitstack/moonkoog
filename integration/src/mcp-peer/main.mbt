// The agent as an MCP client against a server in another process: the peer is the official
// Python SDK's stdio server, the agent lists whatever it offers, and a scripted model asks for
// two of its tools. Everything the tools answer is computed by the peer.
//
//     moon run --target native integration/src/mcp-peer -- <path to mcp_server.py>

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
/// The last message the model was shown, which after a tool call is the tool's answer. A tool
/// answer travels as a result part rather than as text, so both are read here.
fn last_content(provider : @fake.Fake) -> String {
  let seen = provider.seen()
  let messages = seen[seen.length() - 1].messages
  let last = messages[messages.length() - 1]
  let results = last.results()
  if results.length() == 0 {
    return last.text_content()
  }
  match results[results.length() - 1] {
    @moonmuse.Part::Result(content~, ..) => content
    _ => ""
  }
}

///|
/// Ask the peer for `tool` with `args` through an agent, and return what came back to the model.
async fn through_agent(
  client : @client.Client,
  tool : String,
  args : Json,
) -> (String, String) {
  let provider = @fake.Fake::new([call_reply(tool, args), text_reply("done")])
  let agent = @moonkoog.create_agent(
    provider,
    @moonkoog.AgentConfig::new("scripted", name="caller").with_tools(
      @mcp.tools(client),
    ),
  )
  let answer = agent.run("use the tool")
  (last_content(provider), answer)
}

///|
/// A failure the caller can see: the process exits non-zero and the reason is on stderr.
fn fail(reason : String) -> Unit {
  println("mcp-peer: " + reason)
  abort("mcp-peer: " + reason)
}

///|
/// The checks, with the peer spawned into `group` so that the child cannot outlive them.
async fn check(group : @async.TaskGroup[Unit]) -> Unit {
  let args = @env.args()
  let script = if args.length() > 1 {
    args[1]
  } else {
    "integration/peers/mcp_server.py"
  }
  let python = @env.get_env_var("MOONKOOG_PYTHON").unwrap_or("python3")

  // One pipe each way: the peer reads requests from its stdin and writes answers to its stdout.
  let (from_peer, sink) = @process.read_from_process()
  let (source, to_peer) = @process.write_to_process()
  let child = @process.spawn(group, python, [script], stdin=source, stdout=sink)

  // The frame is one line per message, which is what `Lines` carries: the framing adds the
  // newline, so the two closures move the text and nothing else.
  let transport = @client.Lines::new(
    read=async fn() { from_peer.read_until("\n") },
    write=async fn(line) { to_peer.write(line) },
  )
  let client = @client.Client::connect(
    transport,
    name="moonkoog-interop",
    protocol_version="2025-11-25",
  )

  let offered = client.list_tools()
  let names = offered.map(tool => tool.name)
  if !names.contains("add") || !names.contains("shout") {
    fail("the peer did not list its tools: " + names.join(", "))
  }
  println("mcp-peer: the peer offers " + names.join(", "))

  let (added, _) = through_agent(
    client,
    "add",
    Json::object(Map([("a", Json::number(2.0)), ("b", Json::number(40.0))])),
  )
  if added != "42" {
    fail("add came back as \"" + added + "\", not \"42\"")
  }
  println("mcp-peer: add(2, 40) answered " + added)

  let (shouted, _) = through_agent(
    client,
    "shout",
    Json::object(Map([("text", Json::string("hello"))])),
  )
  if shouted != "HELLO" {
    fail("shout came back as \"" + shouted + "\", not \"HELLO\"")
  }
  println("mcp-peer: shout(\"hello\") answered " + shouted)

  client.close()
  from_peer.close()
  to_peer.close()
  child.cancel()
  ignore(child.wait())
  println("mcp-peer: both tools answered from another process")
}

///|
async fn main {
  @async.with_task_group(async fn(group) { check(group) })
}
