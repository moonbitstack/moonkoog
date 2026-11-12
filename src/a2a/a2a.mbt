///|
/// An agent's answer to one A2A message.
///
/// The executor is the whole bridge: a request arrives as a message, the agent runs on its text,
/// and the answer goes back as a reply part. Everything else — discovery, task storage, push
/// notifications — belongs to the protocol's own server, which this adapter does not duplicate.
pub fn executor(agent : @agent.Agent) -> @moona2a.CallableExecutor {
  @moona2a.CallableExecutor::new(
    run=async fn(context, sink) {
      let question = context.message.text()
      let answered = Ok(agent.run(question)) catch { error => Err(error) }
      match answered {
        Ok(answer) =>
          sink.emit(
            context.replying(
              @moona2a.Message::agent(context.context_id, answer).parts,
            ),
          )
        Err(_) => sink.emit(context.status(@moona2a.TaskState::Failed))
      }
    },
    stop=fn(_task) { () },
  )
}

///|
/// A remote agent as a tool: the model calls another agent the way it calls any tool.
///
/// This is the direction that makes a fleet of agents useful — one agent delegates to another
/// over the network — and it costs a single tool rather than a second orchestration layer.
pub fn remote_tool(
  client : &@moona2a.Transport,
  name~ : String,
  description~ : String,
) -> @agent.ToolSpec {
  let peer = @moona2a.Client::new(client)
  @agent.ToolSpec::new(
    name~,
    description~,
    schema=Json::object(
      Map([
        ("type", Json::string("object")),
        (
          "properties",
          Json::object(
            Map([
              ("message", Json::object(Map([("type", Json::string("string"))]))),
            ]),
          ),
        ),
        ("required", Json::array([Json::string("message")])),
      ]),
    ),
    run=async fn(args, _context) {
      let message = match args {
        Object(fields) =>
          match fields.get("message") {
            Some(String(text)) => text
            _ => ""
          }
        _ => ""
      }
      guard message != "" else { return "error: no message was given" }
      let sent = peer.send_message(@moona2a.Message::user("1", message)) catch {
        error =>
          return "error: the remote agent could not be reached: " +
            error.to_string()
      }
      match sent {
        @moona2a.StreamEvent::TaskMessage(message) => message.text()
        other =>
          match other.state() {
            Some(@moona2a.TaskState::Failed) =>
              "the remote agent reported a failed task"
            _ => "the remote agent did not answer with a message"
          }
      }
    },
  )
}
