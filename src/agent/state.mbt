///|
/// What a run carries between nodes: the conversation, the run's own scratch space, how
/// many model and tool calls it has spent, and the answer once one is set.
///
/// The whole value is the graph's state, so it round-trips through JSON for the saver — a
/// checkpoint restores the conversation and the counters, which is what lets a run resume
/// with the budgets it had already spent.
pub(all) struct AgentState {
  messages : Array[@moonmuse.Message]
  storage : Map[String, Json]
  model_calls : Int32
  tool_calls : Int32
  answer : String?
}

///|
/// The state a run starts from.
pub fn AgentState::new() -> AgentState {
  {
    messages: [],
    storage: Map([]),
    model_calls: 0,
    tool_calls: 0,
    answer: None,
  }
}

///|
/// The conversation so far.
pub fn AgentState::messages(self : AgentState) -> Array[@moonmuse.Message] {
  self.messages
}

///|
/// The text of the last assistant message, or the empty string when the model has not
/// spoken yet.
pub fn AgentState::text(self : AgentState) -> String {
  match self.answer {
    Some(answer) => answer
    None => {
      let mut index = self.messages.length() - 1
      while index >= 0 {
        let message = self.messages[index]
        if message.role is Assistant {
          return message.text_content()
        }
        index = index - 1
      }
      ""
    }
  }
}

///|
/// A copy with `messages` replacing the conversation.
pub fn AgentState::with_messages(
  self : AgentState,
  messages : Array[@moonmuse.Message],
) -> AgentState {
  {
    messages,
    storage: self.storage,
    model_calls: self.model_calls,
    tool_calls: self.tool_calls,
    answer: self.answer,
  }
}

///|
/// One change a node makes to the state. A node returns these as `Step::Write`, and the
/// graph applies them in order through [`merge`]; they are also what a checkpoint's pending
/// writes replay.
pub(all) enum Update {
  Append(Array[@moonmuse.Message])
  Replace(Array[@moonmuse.Message])
  Store(key~ : String, value~ : Json)
  Forget(key~ : String)
  Spend(model_calls~ : Int32, tool_calls~ : Int32)
  Answer(String)
}

///|
/// Apply one update.
pub fn merge(state : AgentState, update : Update) -> AgentState {
  match update {
    Append(messages) => {
      let all = state.messages.copy()
      for message in messages {
        all.push(message)
      }
      { ..state, messages: all, }
    }
    Replace(messages) => { ..state, messages, }
    Store(key~, value~) => {
      let storage = state.storage.copy()
      storage[key] = value
      { ..state, storage, }
    }
    Forget(key~) => {
      let storage = state.storage.copy()
      storage.remove(key)
      { ..state, storage, }
    }
    Spend(model_calls~, tool_calls~) =>
      {
        ..state,
        model_calls: state.model_calls + model_calls,
        tool_calls: state.tool_calls + tool_calls,
      }
    Answer(answer) => { ..state, answer: Some(answer), }
  }
}

///|
/// A value this run put in its storage, at the type the call site asks for. `None` when the
/// key is unset or holds something that does not decode to that type.
pub fn[T : FromJson] AgentState::get(self : AgentState, key : String) -> T? {
  match self.storage.get(key) {
    Some(json) => {
      let decoded : Result[T, Unit] = Ok(@json.from_json(json)) catch {
        _ => Err(())
      }
      match decoded {
        Ok(value) => Some(value)
        Err(_) => None
      }
    }
    None => None
  }
}

///|
/// The raw JSON stored under `key`.
pub fn AgentState::raw(self : AgentState, key : String) -> Json? {
  self.storage.get(key)
}

///|
/// Store `value` under `key` — the update a node writes to remember something across nodes.
pub fn[T : ToJson] store(key : String, value : T) -> Update {
  Store(key~, value=ToJson::to_json(value))
}

///|
pub extend Update with ToJson::{to_json}

///|
pub impl ToJson for Update with fn to_json(self) {
  match self {
    Append(messages) => update_json("append", messages, None)
    Replace(messages) => update_json("replace", messages, None)
    Store(key~, value~) =>
      Json::object(
        Map([
          ("kind", Json::string("store")),
          ("key", Json::string(key)),
          ("value", value),
        ]),
      )
    Forget(key~) =>
      Json::object(
        Map([("kind", Json::string("forget")), ("key", Json::string(key))]),
      )
    Spend(model_calls~, tool_calls~) =>
      Json::object(
        Map([
          ("kind", Json::string("spend")),
          ("model_calls", Json::number(model_calls.to_double())),
          ("tool_calls", Json::number(tool_calls.to_double())),
        ]),
      )
    Answer(answer) =>
      Json::object(
        Map([("kind", Json::string("answer")), ("answer", Json::string(answer))]),
      )
  }
}

///|
fn update_json(
  kind : String,
  messages : Array[@moonmuse.Message],
  extra : Json?,
) -> Json {
  let parts : Array[Json] = []
  for message in messages {
    parts.push(message_to_json(message))
  }
  let fields : Map[String, Json] = Map([
    ("kind", Json::string(kind)),
    ("messages", Json::array(parts)),
  ])
  match extra {
    Some(value) => fields["extra"] = value
    None => ()
  }
  Json::object(fields)
}

///|
pub extend Update with FromJson::{from_json}

///|
pub impl FromJson for Update with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "want an object"))
  }
  let kind = match fields.get("kind") {
    Some(String(kind)) => kind
    Some(_) =>
      raise @json.JsonDecodeError((path.add_key("kind"), "want a string"))
    None => raise @json.JsonDecodeError((path.add_key("kind"), "want a kind"))
  }
  match kind {
    "append" => Append(read_messages(fields, path))
    "replace" => Replace(read_messages(fields, path))
    "store" => {
      let key = match fields.get("key") {
        Some(String(key)) => key
        _ => raise @json.JsonDecodeError((path.add_key("key"), "want a key"))
      }
      let value = match fields.get("value") {
        Some(value) => value
        None =>
          raise @json.JsonDecodeError((path.add_key("value"), "want a value"))
      }
      Store(key~, value~)
    }
    "forget" =>
      match fields.get("key") {
        Some(String(key)) => Forget(key~)
        _ => raise @json.JsonDecodeError((path.add_key("key"), "want a key"))
      }
    "spend" => {
      let model_calls = read_count(fields, "model_calls", path)
      let tool_calls = read_count(fields, "tool_calls", path)
      Spend(model_calls~, tool_calls~)
    }
    "answer" =>
      match fields.get("answer") {
        Some(String(answer)) => Answer(answer)
        _ => raise @json.JsonDecodeError((path.add_key("answer"), "want text"))
      }
    _ =>
      raise @json.JsonDecodeError((path.add_key("kind"), "want a known update"))
  }
}

///|
fn read_messages(
  fields : Map[String, Json],
  path : @json.JsonPath,
) -> Array[@moonmuse.Message] raise @json.JsonDecodeError {
  let items = match fields.get("messages") {
    Some(Array(items)) => items
    _ =>
      raise @json.JsonDecodeError((path.add_key("messages"), "want an array"))
  }
  let out : Array[@moonmuse.Message] = []
  for index, item in items {
    out.push(message_from_json(item, path.add_key("messages").add_index(index)))
  }
  out
}

///|
fn read_count(
  fields : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> Int32 raise @json.JsonDecodeError {
  match fields.get(key) {
    Some(Number(value, ..)) => value.to_int()
    _ => raise @json.JsonDecodeError((path.add_key(key), "want a number"))
  }
}

///|
pub extend AgentState with ToJson::{to_json}

///|
pub impl ToJson for AgentState with fn to_json(self) {
  let messages : Array[Json] = []
  for message in self.messages {
    messages.push(message_to_json(message))
  }
  let fields : Map[String, Json] = Map([
    ("messages", Json::array(messages)),
    ("storage", Json::object(self.storage.copy())),
    ("model_calls", Json::number(self.model_calls.to_double())),
    ("tool_calls", Json::number(self.tool_calls.to_double())),
  ])
  match self.answer {
    Some(answer) => fields["answer"] = Json::string(answer)
    None => ()
  }
  Json::object(fields)
}

///|
pub extend AgentState with FromJson::{from_json}

///|
pub impl FromJson for AgentState with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "want an object"))
  }
  let messages = read_messages(fields, path)
  let storage = match fields.get("storage") {
    Some(Object(storage)) => storage
    _ =>
      raise @json.JsonDecodeError((path.add_key("storage"), "want an object"))
  }
  let model_calls = read_count(fields, "model_calls", path)
  let tool_calls = read_count(fields, "tool_calls", path)
  let answer = match fields.get("answer") {
    Some(String(answer)) => Some(answer)
    _ => None
  }
  { messages, storage, model_calls, tool_calls, answer, }
}
