///|
/// Pick the tools worth advertising for the next call.
///
/// A large toolbox costs tokens on every request and confuses a small model. This middleware asks
/// the model, once per call, which of the named tools it needs for what the user just asked, and
/// advertises only those — always keeping the ones a policy pins.
pub struct ToolSelection {
  max_tools : Int32
  always : Array[String]
}

///|
/// Advertise at most `max_tools` tools, chosen per call, plus every tool in `always`.
pub fn ToolSelection::new(
  max_tools~ : Int32 = 5,
  always~ : Array[String] = [],
) -> ToolSelection {
  { max_tools, always, }
}

///|
pub extend ToolSelection with @agent.Middleware::{
  name,
  install,
  before_agent,
  wrap_model,
  wrap_tool,
  after_agent,
}

///|
pub impl @agent.Middleware for ToolSelection with fn name(_self) {
  "tool_selection"
}

///|
pub impl @agent.Middleware for ToolSelection with fn install(_self, _tools) {
  ()
}

///|
pub impl @agent.Middleware for ToolSelection with fn before_agent(
  _self,
  _context,
) {
  []
}

///|
pub impl @agent.Middleware for ToolSelection with fn wrap_model(
  self,
  context,
  call,
  next,
) {
  if call.request.tools.length() <= self.max_tools {
    return next(call)
  }
  let chosen = self.choose(context, call.request)
  let tools = call.request.tools.filter(tool => chosen.contains(tool.name))
  next({ request: { ..call.request, tools, }, })
}

///|
pub impl @agent.Middleware for ToolSelection with fn wrap_tool(
  _self,
  _context,
  call,
  next,
) {
  next(call)
}

///|
pub impl @agent.Middleware for ToolSelection with fn after_agent(
  _self,
  _context,
  _state,
) {
  []
}

///|
/// Ask the model which tools to keep, and read the names back out of its answer. A failure of the
/// selection call is not a failure of the run: the full toolbox is advertised instead.
async fn ToolSelection::choose(
  self : ToolSelection,
  context : @agent.RunContext,
  request : @moonmuse.Request,
) -> Array[String] {
  let listing = StringBuilder()
  for tool in request.tools {
    listing.write_string("- " + tool.name + ": " + tool.description + "\n")
  }
  let question = @moonmuse.Request::new(context.model, [
    @moonmuse.Message::user(
      "Which of these tools are needed to answer the request below? Reply with the tool names separated by commas, nothing else.\n\nTools:\n" +
      listing.to_string() +
      "\nRequest:\n" +
      last_user_text(request.messages),
    ),
  ])
  let asked = Ok(context.runtime.provider.chat(question)) catch {
    error => Err(error)
  }
  let answer = match asked {
    Ok(reply) => reply.text()
    Err(_) => return request.tools.map(tool => tool.name)
  }
  let kept : Array[String] = []
  for tool in self.always {
    kept.push(tool)
  }
  for tool in request.tools {
    if kept.length() >= self.max_tools {
      break
    }
    if kept.contains(tool.name) {
      continue
    }
    if mentions(answer, tool.name) {
      kept.push(tool.name)
    }
  }
  if kept.length() >= self.max_tools || kept.length() == 0 {
    return kept
  }
  // The model named fewer tools than fits; fill up in declaration order so the request keeps a
  // useful toolbox instead of one entry.
  for tool in request.tools {
    if kept.length() >= self.max_tools {
      break
    }
    if !kept.contains(tool.name) {
      kept.push(tool.name)
    }
  }
  kept
}

///|
/// Whether the model's answer names the tool. Tool names are distinctive enough that a
/// case-insensitive substring is the right test, and it survives a model that writes
/// `search_files, read_file` or a sentence around the names.
fn mentions(text : String, tool : String) -> Bool {
  text.to_lower().contains(tool.to_lower())
}
