///|
/// What to do with the tool calls and results a conversation already carries when the agent
/// reading it does not offer those tools.
///
/// A thread outlives the configuration that wrote it: a checkpoint recorded by an agent with a
/// `search` tool may be resumed by one without it, and a provider that is handed a call it never
/// advertised, or a result whose call it cannot see, has every right to refuse the request. The
/// two converting policies replace those parts with text that says what happened, so the
/// conversation stays readable.
pub(all) enum MissingTools {
  /// Leave the conversation as it is. A provider that tolerates unfamiliar tool parts is happy
  /// with this, and it is the default.
  Keep
  /// Rewrite the parts that name a tool this agent does not have.
  Convert
  /// Rewrite every tool call and result, whether the tool exists or not.
  ConvertAll
}

///|
/// The text a converted call becomes: the id, the tool and the arguments it was given.
fn missing_call_text(id : String, name : String, args : Json) -> String {
  "{\"tool_call_id\":" +
  Json::string(id).stringify() +
  ",\"tool_name\":" +
  Json::string(name).stringify() +
  ",\"tool_args\":" +
  args.stringify() +
  "}"
}

///|
/// The text a converted result becomes. A result carries no tool name of its own, so the name is
/// looked up from the call it answers; when the conversation has no such call the field is left
/// out rather than filled with a guess.
fn missing_result_text(id : String, name : String?, content : String) -> String {
  let head = "{\"tool_call_id\":" + Json::string(id).stringify()
  let body = match name {
    Some(name) => ",\"tool_name\":" + Json::string(name).stringify()
    None => ""
  }
  head + body + ",\"tool_result\":" + Json::string(content).stringify() + "}"
}

///|
/// The conversation as the request should carry it, with the parts that name unknown tools
/// replaced by text.
///
/// `known` is the tool names this agent offers. A part is converted when the policy says so and
/// the tool is missing; text and image parts are never touched, and a message with nothing to
/// convert is returned unchanged rather than rebuilt.
pub fn convert_missing_tools(
  messages : Array[@moonmuse.Message],
  known : Array[String],
  policy : MissingTools,
) -> Array[@moonmuse.Message] {
  if policy is Keep {
    return messages
  }
  // The call each result answers, by id, so a converted result can still name its tool.
  let names : Map[String, String] = Map([])
  for message in messages {
    for part in message.parts {
      match part {
        @moonmuse.Part::Call(id~, name~, ..) => names[id] = name
        _ => ()
      }
    }
  }
  let converted : Array[@moonmuse.Message] = []
  for message in messages {
    let parts : Array[@moonmuse.Part] = []
    let mut changed = false
    for part in message.parts {
      match part {
        @moonmuse.Part::Call(id~, name~, args~) =>
          if policy is ConvertAll || !known.contains(name) {
            parts.push(@moonmuse.Part::Text(missing_call_text(id, name, args)))
            changed = true
          } else {
            parts.push(part)
          }
        @moonmuse.Part::Result(id~, content~, ..) => {
          let gone = match names.get(id) {
            Some(name) => !known.contains(name)
            None => true
          }
          if policy is ConvertAll || gone {
            parts.push(
              @moonmuse.Part::Text(
                missing_result_text(id, names.get(id), content),
              ),
            )
            changed = true
          } else {
            parts.push(part)
          }
        }
        _ => parts.push(part)
      }
    }
    if changed {
      converted.push(@moonmuse.Message::new(message.role, parts))
    } else {
      converted.push(message)
    }
  }
  converted
}
