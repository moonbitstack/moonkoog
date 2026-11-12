///|
async test "mcp: an agent served over the protocol answers a caller's tool call" {
  let provider = @fake.Fake::text("hello from the served agent")
  let served = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("m", name="helper"),
  )
  let server = @mcp.serve(served)
  let client = @client.Client::connect(@client.Memory::new(server))
  let specs = @mcp.tools(client)
  assert_eq(specs.length(), 1)
  assert_eq(specs[0].tool.name, @mcp.chat_tool)
  let caller_provider = @fake.Fake::new([
    @moonmuse.Reply::new(
      @moonmuse.Message::new(@moonmuse.Assistant, [
        @moonmuse.Part::call(
          "call_1",
          @mcp.chat_tool,
          Json::object(Map([("message", Json::string("hi"))])),
        ),
      ]),
      finish=@moonmuse.Finish::Calls,
    ),
    @moonmuse.Reply::new(@moonmuse.Message::assistant("relayed")),
  ])
  let caller = @agent.create_agent(
    caller_provider,
    @agent.AgentConfig::new("caller").with_tools(specs),
  )
  assert_eq(caller.run("ask the helper"), "relayed")
  let seen = caller_provider.seen()
  let last = seen[seen.length() - 1]
  let mut reported = ""
  for message in last.messages {
    for part in message.results() {
      match part {
        @moonmuse.Part::Result(content~, ..) => reported = content
        _ => ()
      }
    }
  }
  assert_eq(reported, "hello from the served agent")
}

///|
async test "mcp: a prefix namespaces the tools of a server" {
  let served = @agent.create_agent(
    @fake.Fake::text("ok"),
    @agent.AgentConfig::new("m", name="helper"),
  )
  let client = @client.Client::connect(@client.Memory::new(@mcp.serve(served)))
  let specs = @mcp.tools(client, prefix="helper")
  assert_eq(specs[0].tool.name, "helper_" + @mcp.chat_tool)
}
