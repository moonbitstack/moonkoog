///|
/// Give the model a todo list it can write to.
///
/// A long task goes better when the model states its plan and updates it: the list is in the
/// conversation, so the next step sees it, and in the state, so a resumed run sees it too. The
/// middleware contributes both the tool and the note that tells the model to use it.
pub struct TodoList {}

///|
/// The todo middleware.
pub fn TodoList::new() -> TodoList {
  TodoList::{ }
}

///|
/// The tool the middleware installs.
pub let todo_tool : String = "write_todos"

///|
/// The storage key the list lives under.
pub let todo_key : String = "moonkoog.todos"

///|
/// What the model is told about the list, once, at the start of the run.
pub let todo_note : String = "Keep the work in a todo list. Call " +
  todo_tool +
  " with the whole list whenever the plan changes: every item has a `content` and a `status` of " +
  "`pending`, `in_progress` or `completed`. Keep exactly one item in progress."

///|
pub extend TodoList with @agent.Middleware::{
  name,
  install,
  before_agent,
  wrap_model,
  wrap_tool,
  after_agent,
}

///|
pub impl @agent.Middleware for TodoList with fn name(_self) {
  "todo"
}

///|
pub impl @agent.Middleware for TodoList with fn install(_self, tools) {
  tools.add(
    @agent.ToolSpec::new(
      name=todo_tool,
      description="Replace the todo list. Send the whole list every time it changes.",
      schema=Json::object(
        Map([
          ("type", Json::string("object")),
          (
            "properties",
            Json::object(
              Map([
                (
                  "todos",
                  Json::object(
                    Map([
                      ("type", Json::string("array")),
                      (
                        "items",
                        Json::object(
                          Map([
                            ("type", Json::string("object")),
                            (
                              "properties",
                              Json::object(
                                Map([
                                  (
                                    "content",
                                    Json::object(
                                      Map([("type", Json::string("string"))]),
                                    ),
                                  ),
                                  (
                                    "status",
                                    Json::object(
                                      Map([
                                        ("type", Json::string("string")),
                                        (
                                          "enum",
                                          Json::array([
                                            Json::string("pending"),
                                            Json::string("in_progress"),
                                            Json::string("completed"),
                                          ]),
                                        ),
                                      ]),
                                    ),
                                  ),
                                ]),
                              ),
                            ),
                            ("required", Json::array([Json::string("content")])),
                          ]),
                        ),
                      ),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
          ("required", Json::array([Json::string("todos")])),
        ]),
      ),
      run=fn(args, context) {
        let items = arg_array(args, "todos")
        let json = Json::array(items)
        context.pending.push(@agent.Store(key=todo_key, value=json))
        format_todos(items)
      },
    ),
  )
}

///|
pub impl @agent.Middleware for TodoList with fn before_agent(_self, _context) {
  [@agent.Append([@moonmuse.Message::system(todo_note)])]
}

///|
pub impl @agent.Middleware for TodoList with fn wrap_model(
  _self,
  _context,
  call,
  next,
) {
  next(call)
}

///|
pub impl @agent.Middleware for TodoList with fn wrap_tool(
  _self,
  _context,
  call,
  next,
) {
  next(call)
}

///|
pub impl @agent.Middleware for TodoList with fn after_agent(
  _self,
  _context,
  _state,
) {
  []
}

///|
/// The list as the model reads it back: one line per item, with its status.
pub fn format_todos(items : Array[Json]) -> String {
  guard items.length() > 0 else { return "the todo list is empty" }
  let out = StringBuilder()
  for item in items {
    let content = match item {
      Object(fields) =>
        match fields.get("content") {
          Some(String(content)) => content
          _ => ""
        }
      _ => ""
    }
    let status = match item {
      Object(fields) =>
        match fields.get("status") {
          Some(String(status)) => status
          _ => "pending"
        }
      _ => "pending"
    }
    let mark = match status {
      "completed" => "[x]"
      "in_progress" => "[~]"
      _ => "[ ]"
    }
    out.write_string(mark + " " + content + "\n")
  }
  out.to_string()
}

///|
/// The list a run recorded, when it has one.
pub fn todos(state : @agent.AgentState) -> Array[Json] {
  match state.storage.get(todo_key) {
    Some(Array(items)) => items
    _ => []
  }
}

///|
/// Ask the host whether a tool may run, by stopping the run on a question.
///
/// The run stops at the tool call; the host answers with `true` or `false` when it resumes. An
/// approval is remembered for the rest of the thread, so a tool called five times asks once. A
/// denial comes back to the model as a failed call, which lets it choose another way instead of
/// ending the run.
pub struct HumanInTheLoop {
  tools : Array[String]
  reason : String
}

///|
/// Ask before running any of `tools`.
pub fn HumanInTheLoop::new(
  tools : Array[String],
  reason~ : String = "this tool changes something outside the run",
) -> HumanInTheLoop {
  { tools, reason, }
}

///|
/// The question's storage marker: an approval is kept per thread and per tool.
fn approval_key(tool : String) -> String {
  "moonkoog.approved." + tool
}

///|
pub extend HumanInTheLoop with @agent.Middleware::{
  name,
  install,
  before_agent,
  wrap_model,
  wrap_tool,
  after_agent,
}

///|
pub impl @agent.Middleware for HumanInTheLoop with fn name(_self) {
  "human_in_the_loop"
}

///|
pub impl @agent.Middleware for HumanInTheLoop with fn install(_self, _tools) {
  ()
}

///|
pub impl @agent.Middleware for HumanInTheLoop with fn before_agent(
  _self,
  _context,
) {
  []
}

///|
pub impl @agent.Middleware for HumanInTheLoop with fn wrap_model(
  _self,
  _context,
  call,
  next,
) {
  next(call)
}

///|
pub impl @agent.Middleware for HumanInTheLoop with fn wrap_tool(
  self,
  context,
  call,
  next,
) {
  let name = describe_call(call)
  guard self.tools.contains(name) else { return next(call) }
  match context.state.storage.get(approval_key(name)) {
    Some(True) => return next(call)
    _ => ()
  }
  match context.answer {
    Some(True) => {
      context.pending.push(
        @agent.Store(key=approval_key(name), value=Json::boolean(true)),
      )
      next(call)
    }
    Some(False) =>
      @agent.ToolOutcome::Failed("the user denied the call to " + name)
    _ => {
      let question = Json::object(
        Map([
          ("kind", Json::string("approval")),
          ("tool", Json::string(name)),
          ("reason", Json::string(self.reason)),
          ("args", args_of(call)),
        ]),
      )
      @agent.ToolOutcome::Suspend(question)
    }
  }
}

///|
pub impl @agent.Middleware for HumanInTheLoop with fn after_agent(
  _self,
  _context,
  _state,
) {
  []
}

///|
/// The arguments of a call, for the question a host shows.
fn args_of(call : @agent.ToolCall) -> Json {
  match call.part {
    @moonmuse.Part::Call(args~, ..) => args
    _ => Json::null()
  }
}
