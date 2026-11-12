///|
/// Read a string field out of a tool call's arguments.
fn arg_string(args : Json, key : String) -> String? {
  match args {
    Object(fields) =>
      match fields.get(key) {
        Some(String(value)) => Some(value)
        _ => None
      }
    _ => None
  }
}

///|
/// Read an array field out of a tool call's arguments.
fn arg_array(args : Json, key : String) -> Array[Json] {
  match args {
    Object(fields) =>
      match fields.get(key) {
        Some(Array(items)) => items
        _ => []
      }
    _ => []
  }
}

///|
/// A message whose text parts have each been through `rewrite`; other parts are kept as they
/// are, so an image or a call survives a redaction pass untouched.
fn rewrite_message(
  message : @moonmuse.Message,
  rewrite : (String) -> String,
) -> @moonmuse.Message {
  let parts : Array[@moonmuse.Part] = []
  for part in message.parts {
    match part {
      Text(text) => parts.push(@moonmuse.Part::text(rewrite(text)))
      other => parts.push(other)
    }
  }
  { role: message.role, parts, }
}

///|
/// Every message of a request rewritten in place of the original list.
fn rewrite_request(
  request : @moonmuse.Request,
  rewrite : (Array[@moonmuse.Message]) -> Array[@moonmuse.Message],
) -> @moonmuse.Request {
  request.with_messages(rewrite(request.messages))
}

///|
/// The last user message of a conversation, which is what a selector or a redactor is usually
/// interested in.
fn last_user_text(messages : Array[@moonmuse.Message]) -> String {
  let mut index = messages.length() - 1
  while index >= 0 {
    if messages[index].role is @moonmuse.User {
      return messages[index].text_content()
    }
    index = index - 1
  }
  ""
}

///|
/// Note the tool call that is running, so a report can name it.
fn describe_call(call : @agent.ToolCall) -> String {
  match call.part {
    @moonmuse.Part::Call(name~, ..) => name
    _ => "?"
  }
}
