///|
/// A message as JSON. The conversation is part of a checkpoint, so it has to survive a
/// round trip through the saver: `role`, then one entry per part, each tagged with the
/// part's kind.
pub fn message_to_json(message : @moonmuse.Message) -> Json {
  let parts : Array[Json] = []
  for part in message.parts {
    parts.push(part_to_json(part))
  }
  Json::object(
    Map([
      ("role", Json::string(role_code(message.role))),
      ("parts", Json::array(parts)),
    ]),
  )
}

///|
/// The wire name of a role, the same spelling the providers use.
pub fn role_code(role : @moonmuse.Role) -> String {
  match role {
    System => "system"
    User => "user"
    Assistant => "assistant"
    Tool => "tool"
  }
}

///|
/// A role from its wire name.
pub fn role_of(code : String) -> @moonmuse.Role? {
  match code {
    "system" => Some(System)
    "user" => Some(User)
    "assistant" => Some(Assistant)
    "tool" => Some(Tool)
    _ => None
  }
}

///|
/// One part as JSON, tagged with its kind.
pub fn part_to_json(part : @moonmuse.Part) -> Json {
  match part {
    Text(text) =>
      Json::object(
        Map([("kind", Json::string("text")), ("text", Json::string(text))]),
      )
    Image(url~, media~) => {
      let fields : Map[String, Json] = Map([
        ("kind", Json::string("image")),
        ("url", Json::string(url)),
      ])
      match media {
        Some(media) => fields["media"] = Json::string(media)
        None => ()
      }
      Json::object(fields)
    }
    Call(id~, name~, args~) =>
      Json::object(
        Map([
          ("kind", Json::string("call")),
          ("id", Json::string(id)),
          ("name", Json::string(name)),
          ("args", args),
        ]),
      )
    Result(id~, content~, error~) =>
      Json::object(
        Map([
          ("kind", Json::string("result")),
          ("id", Json::string(id)),
          ("content", Json::string(content)),
          ("error", Json::boolean(error)),
        ]),
      )
  }
}

///|
/// A message from its JSON form; the error names the field that did not read.
pub fn message_from_json(
  json : Json,
  path : @json.JsonPath,
) -> @moonmuse.Message raise @json.JsonDecodeError {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "want an object"))
  }
  let role = match fields.get("role") {
    Some(String(code)) =>
      match role_of(code) {
        Some(role) => role
        None =>
          raise @json.JsonDecodeError(
            (path.add_key("role"), "want a known role"),
          )
      }
    Some(_) =>
      raise @json.JsonDecodeError((path.add_key("role"), "want a string"))
    None => raise @json.JsonDecodeError((path.add_key("role"), "want a role"))
  }
  let parts = match fields.get("parts") {
    Some(Array(items)) => {
      let out : Array[@moonmuse.Part] = []
      for index, item in items {
        out.push(part_from_json(item, path.add_key("parts").add_index(index)))
      }
      out
    }
    Some(_) =>
      raise @json.JsonDecodeError((path.add_key("parts"), "want an array"))
    None =>
      raise @json.JsonDecodeError((path.add_key("parts"), "want an array"))
  }
  { role, parts, }
}

///|
/// One part from its JSON form.
pub fn part_from_json(
  part : Json,
  path : @json.JsonPath,
) -> @moonmuse.Part raise @json.JsonDecodeError {
  guard part is Object(fields) else {
    raise @json.JsonDecodeError((path, "want an object"))
  }
  let kind = match fields.get("kind") {
    Some(String(kind)) => kind
    Some(_) =>
      raise @json.JsonDecodeError((path.add_key("kind"), "want a string"))
    None => raise @json.JsonDecodeError((path.add_key("kind"), "want a kind"))
  }
  match kind {
    "text" => Text(read_string(fields, "text", path))
    "image" =>
      Image(
        url=read_string(fields, "url", path),
        media=read_optional_string(fields, "media", path),
      )
    "call" =>
      Call(
        id=read_string(fields, "id", path),
        name=read_string(fields, "name", path),
        args=match fields.get("args") {
          Some(args) => args
          None =>
            raise @json.JsonDecodeError(
              (path.add_key("args"), "want arguments"),
            )
        },
      )
    "result" =>
      Result(
        id=read_string(fields, "id", path),
        content=read_string(fields, "content", path),
        error=match fields.get("error") {
          Some(True) => true
          Some(False) => false
          Some(_) =>
            raise @json.JsonDecodeError((path.add_key("error"), "want a bool"))
          None => false
        },
      )
    _ =>
      raise @json.JsonDecodeError(
        (path.add_key("kind"), "want a known part kind"),
      )
  }
}

///|
fn read_string(
  fields : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> String raise @json.JsonDecodeError {
  match fields.get(key) {
    Some(String(value)) => value
    Some(_) => raise @json.JsonDecodeError((path.add_key(key), "want a string"))
    None => raise @json.JsonDecodeError((path.add_key(key), "want a string"))
  }
}

///|
fn read_optional_string(
  fields : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> String? raise @json.JsonDecodeError {
  match fields.get(key) {
    Some(String(value)) => Some(value)
    Some(Null) | None => None
    Some(_) => raise @json.JsonDecodeError((path.add_key(key), "want a string"))
  }
}
