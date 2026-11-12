///|
/// The text of a prompt: every text block, in order.
pub fn prompt_text(prompt : @moonacp.Prompt) -> String {
  let out = StringBuilder()
  for block in prompt.prompt {
    match block {
      @moonacp.ContentBlock::Text(text) => out.write_string(text.text)
      _ => ()
    }
  }
  out.to_string()
}

///|
/// One agent message as a session update.
pub fn message_update(text : String) -> @moonacp.SessionUpdate {
  @moonacp.SessionUpdate::AgentMessageChunk({
    content: @moonacp.ContentBlock::Text({
      text,
      annotations: None,
      meta: None,
    }),
    message_id: None,
    meta: None,
  })
}

///|
/// A session update for each agent event worth reporting: the tool a run starts, the tool it
/// finishes, and the answer it settles on.
///
/// The translation is the whole of the ACP bridge on the streaming side: the protocol sends
/// `session/update` notifications, the agent already reports events, so an adapter is a mapping
/// and not a second event system.
pub fn updates(event : @agent.Event) -> Array[@moonacp.SessionUpdate] {
  match event {
    ToolStarted(name~, ..) =>
      [
        @moonacp.SessionUpdate::ToolCall({
          tool_call_id: name,
          title: name,
          name: Some(name),
          kind: None,
          status: None,
          content: None,
          locations: None,
          raw_input: None,
          raw_output: None,
          meta: None,
        }),
      ]
    ToolFinished(call_id~, failed~, ..) =>
      [
        @moonacp.SessionUpdate::ToolCallUpdate({
          tool_call_id: call_id,
          name: None,
          status: Some(
            if failed {
              @moonacp.ToolCallStatus::Failed
            } else {
              @moonacp.ToolCallStatus::Completed
            },
          ),
          title: None,
          kind: None,
          content: None,
          locations: None,
          raw_input: None,
          raw_output: None,
          meta: None,
        }),
      ]
    AgentFinished(text~, ..) => [message_update(text)]
    _ => []
  }
}

///|
/// An agent exported over ACP.
///
/// The protocol part is small: one initialize, one session per conversation, one prompt per
/// turn. The interest is in the translation — the run's events become `session/update`
/// notifications, and the protocol's own client renders them. A session update is sent once the
/// turn has settled rather than as it happens, because this runtime's hooks are synchronous
/// while the protocol's writes are not; the order of the notifications is the order the run
/// produced them.
pub struct Acp {
  agent : @agent.Agent
  mut sessions : Int32
}

///|
/// Export `agent` over ACP.
pub fn Acp::new(agent : @agent.Agent) -> Acp {
  { agent, sessions: 0, }
}

///|
pub extend Acp with @moonacp.Agent::{
  initialize,
  authenticate,
  logout,
  new_session,
  load_session,
  resume_session,
  list_sessions,
  delete_session,
  close_session,
  set_mode,
  set_config_option,
  prompt,
  cancel,
}

///|
pub impl @moonacp.Agent for Acp with fn initialize(_self, _request) {
  @moonacp.Initialized::new()
}

///|
pub impl @moonacp.Agent for Acp with fn new_session(self, _request) {
  self.sessions = self.sessions + 1
  {
    session_id: "session-" + self.sessions.to_string(),
    modes: None,
    config_options: None,
    meta: None,
  }
}

///|
pub impl @moonacp.Agent for Acp with fn prompt(self, request, session) {
  let text = prompt_text(request)
  let collected : Array[@agent.Event] = []
  let answered = Ok(self.agent.stream(text, event => collected.push(event))) catch {
    error => Err(error)
  }
  for event in collected {
    for update in updates(event) {
      session.update(update) catch {
        _ => ()
      }
    }
  }
  match answered {
    Ok(_) => @moonacp.StopReason::EndTurn
    Err(_) => @moonacp.StopReason::Refusal
  }
}
