///|
/// What a summarising call produced.
priv enum Summary {
  Written(String)
  Unavailable(reason~ : String)
}

///|
/// The result of compressing a conversation: the messages to carry on with, or why the summary
/// could not be written.
pub(all) enum Compressed {
  Done(Array[@moonmuse.Message])
  Refused(reason~ : String)
}

///|
/// Fold older conversation into a summary, keeping the system message and the newest turns.
///
/// A run that goes on long enough meets the model's context window; compressing is cheaper than
/// failing, and the summary keeps the thread of the work. `Whole` summarises everything but the
/// system message, `FromLast(n)` keeps the last `n` messages word for word.
pub async fn compress(
  runtime : Runtime,
  context : RunContext,
  messages : Array[@moonmuse.Message],
  policy : HistoryPolicy,
) -> Compressed {
  let total = messages.length()
  guard total > 0 else { return Done(messages) }
  let (head, body) = split_system(messages)
  let keep = match policy {
    Whole => 0
    FromLast(count) => if count < body.length() { count } else { body.length() }
  }
  let cut = body.length() - keep
  guard cut > 0 else { return Done(messages) }
  let older : Array[@moonmuse.Message] = []
  for index in 0..<cut {
    older.push(body[index])
  }
  let summary = match summarize(runtime, context, older) {
    Written(text) => text
    Unavailable(reason~) => return Refused(reason~)
  }
  let out = head.copy()
  out.push(
    @moonmuse.Message::assistant(
      "Summary of the earlier conversation: " + summary,
    ),
  )
  for index in cut..<body.length() {
    out.push(body[index])
  }
  Done(out)
}

///|
/// Split the leading system message off a conversation.
fn split_system(
  messages : Array[@moonmuse.Message],
) -> (Array[@moonmuse.Message], Array[@moonmuse.Message]) {
  let head : Array[@moonmuse.Message] = []
  let start = if messages.length() > 0 && messages[0].role is System {
    head.push(messages[0])
    1
  } else {
    0
  }
  let body : Array[@moonmuse.Message] = []
  for index in start..<messages.length() {
    body.push(messages[index])
  }
  (head, body)
}

///|
/// Ask the model for a summary of `messages`.
async fn summarize(
  runtime : Runtime,
  context : RunContext,
  messages : Array[@moonmuse.Message],
) -> Summary {
  let transcript = StringBuilder()
  for message in messages {
    transcript.write_string(
      role_code(message.role) + ": " + message.text_content() + "\n",
    )
  }
  let request = @moonmuse.Request::new(runtime.model, [
    @moonmuse.Message::user(
      "Summarise this conversation in a short paragraph, keeping the decisions, the facts learned and what is still open:\n" +
      transcript.to_string(),
    ),
  ])
  let call : ModelCall = { request, }
  match pipeline_model(runtime, context, call, RequestMode::NoTools) {
    Replied(reply) => Written(reply.text())
    Failed(reason~, ..) => Unavailable(reason~)
    Halted(text) => Written(text)
  }
}
