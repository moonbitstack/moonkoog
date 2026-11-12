///|
/// A reply that asks for a handover.
fn handoff_reply(to : String) -> @moonmuse.Reply {
  @moonmuse.Reply::new(
    @moonmuse.Message::new(@moonmuse.Assistant, [
      @moonmuse.Part::call(
        "call_1",
        @multi.handoff_tool_name,
        Json::object(Map([("to", Json::string(to))])),
      ),
    ]),
    finish=@moonmuse.Finish::Calls,
  )
}

///|
async test "handoff tool: a target outside the team comes back as a failure to the model" {
  let provider = @fake.Fake::new([
    handoff_reply("stranger"),
    @moonmuse.Reply::new(@moonmuse.Message::assistant("I cannot go there")),
  ])
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("solo", name="solo").with_tools([
      @multi.handoff_tool(["writer"]),
    ]),
  )
  assert_eq(agent.run("go"), "I cannot go there")
  let seen = provider.seen()
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
  assert_eq(reported.contains("no agent named"), true)
}

///|
async test "swarm: a member hands the conversation to the next one" {
  let first_provider = @fake.Fake::new([handoff_reply("writer")])
  let second_provider = @fake.Fake::new([
    @moonmuse.Reply::new(
      @moonmuse.Message::assistant("written by the second agent"),
    ),
  ])
  let first = @agent.create_agent(
    first_provider,
    @agent.AgentConfig::new("researcher", name="researcher")
    .with_instructions("Research, then hand over to the writer.")
    .with_tools([@multi.handoff_tool(["writer"])]),
  )
  let second = @agent.create_agent(
    second_provider,
    @agent.AgentConfig::new("writer", name="writer").with_instructions(
      "Write the answer.",
    ),
  )
  let team = @agent.create_agent(
    first_provider,
    @multi.swarm(@agent.AgentConfig::new("team"), [first, second]),
  )
  assert_eq(team.run("write something"), "written by the second agent")
  assert_eq(second_provider.hits(), 1)
}

///|
async test "supervisor: the router picks the member and stops on FINISH" {
  let router = @fake.Fake::new([
    @moonmuse.Reply::new(@moonmuse.Message::assistant("writer")),
    @moonmuse.Reply::new(@moonmuse.Message::assistant("FINISH")),
  ])
  let writer_provider = @fake.Fake::new([
    @moonmuse.Reply::new(
      @moonmuse.Message::assistant("the supervisor's answer"),
    ),
  ])
  let writer = @agent.create_agent(
    writer_provider,
    @agent.AgentConfig::new("writer", name="writer"),
  )
  let team = @agent.create_agent(
    router,
    @multi.supervisor(@agent.AgentConfig::new("team"), [writer]),
  )
  assert_eq(team.run("write something"), "the supervisor's answer")
  assert_eq(writer_provider.hits(), 1)
  assert_eq(router.hits(), 2)
}
