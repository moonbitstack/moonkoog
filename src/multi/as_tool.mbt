// Another agent, handed to this one as a tool: the shape every framework in this family calls
// agent-as-tool, and the smallest way to compose agents — no new engine, no second loop.

///|
/// An agent as a tool another agent can call.
///
/// The model sees one tool whose argument is a message and whose result is the other agent's
/// answer, so a lead agent delegates a sub-task by asking for it. The called agent keeps its own
/// strategy, its own tools and its own model; only the question and the answer cross the line.
/// A run that fails comes back to the caller as text it can act on rather than as an exception,
/// because a tool that raises leaves the model with nothing to recover from.
pub fn as_tool(
  agent : @agent.Agent,
  name? : String,
  description? : String,
) -> @agent.ToolSpec {
  let tool_name = name.unwrap_or(agent.name())
  let tool_description = description.unwrap_or(
    "Ask the " +
    agent.name() +
    " agent. Send it one message; it answers with its own reply.",
  )
  @agent.ToolSpec::new(
    name=tool_name,
    description=tool_description,
    schema=Json::object(
      Map([
        ("type", Json::string("object")),
        (
          "properties",
          Json::object(
            Map([
              (
                "message",
                Json::object(
                  Map([
                    ("type", Json::string("string")),
                    ("description", Json::string("What to ask the agent.")),
                  ]),
                ),
              ),
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
      agent.run(message) catch {
        error => return "error: the agent failed: " + @agent.describe(error)
      }
    },
  )
}
