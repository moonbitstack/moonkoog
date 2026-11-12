///|
/// A prompt of one text block, the shape a client sends a turn in.
fn prompt(text : String) -> @moonacp.Prompt {
  {
    session_id: "session-1",
    prompt: [
      @moonacp.ContentBlock::Text({ text, annotations: None, meta: None, }),
    ],
    meta: None,
  }
}

///|
test "acp: a prompt's text is read out of its blocks" {
  assert_eq(@acp.prompt_text(prompt("hello there")), "hello there")
}

///|
test "acp: a tool event becomes a tool-call update, a finished run a message" {
  let started = @acp.updates(@agent.ToolStarted(name="search", call_id="c1"))
  assert_eq(started.length(), 1)
  assert_eq(started[0] is @moonacp.SessionUpdate::ToolCall(_), true)
  let finished = @acp.updates(
    @agent.ToolFinished(name="search", call_id="c1", failed=true),
  )
  assert_eq(finished[0] is @moonacp.SessionUpdate::ToolCallUpdate(_), true)
  let answered = @acp.updates(@agent.AgentFinished(name="a", text="done"))
  assert_eq(answered[0] is @moonacp.SessionUpdate::AgentMessageChunk(_), true)
}

///|
async test "acp: a session is opened with an identifier of its own" {
  let acp = @acp.Acp::new(
    @agent.create_agent(@fake.Fake::text("ok"), @agent.AgentConfig::new("m")),
  )
  let request : @moonacp.NewSession = {
    cwd: ".",
    additional_directories: None,
    mcp_servers: [],
    meta: None,
  }
  let first = acp.new_session(request)
  let second = acp.new_session(request)
  assert_eq(first.session_id, "session-1")
  assert_eq(second.session_id, "session-2")
}
