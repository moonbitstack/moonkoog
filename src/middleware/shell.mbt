///|
/// Give the model a shell.
///
/// A shell is the broadest capability a run can have, so the tool is explicit about where it
/// runs: the middleware carries the working directory it is allowed in, the shell it hands the
/// line to, and the wall-clock limit after which the process is stopped. Output is cut so one
/// command cannot flood the conversation.
pub struct ShellTool {
  prefix : Array[String]
  cwd : String?
  timeout_ms : Int32
}

///|
/// A shell tool using `prefix` (program and its arguments, e.g. `["sh", "-c"]`), rooted at `cwd`.
pub fn ShellTool::new(
  prefix~ : Array[String] = os_shell,
  cwd? : String,
  timeout_ms~ : Int32 = 30_000,
) -> ShellTool {
  { prefix, cwd, timeout_ms, }
}

///|
/// The tool the middleware installs.
pub let shell_tool : String = "run_shell"

///|
pub extend ShellTool with @agent.Middleware::{
  name,
  install,
  before_agent,
  wrap_model,
  wrap_tool,
  after_agent,
}

///|
pub impl @agent.Middleware for ShellTool with fn name(_self) {
  "shell_tool"
}

///|
pub impl @agent.Middleware for ShellTool with fn install(self, tools) {
  tools.add(
    @agent.ToolSpec::new(
      name=shell_tool,
      description="Run a shell command and return its output and exit code.",
      schema=Json::object(
        Map([
          ("type", Json::string("object")),
          (
            "properties",
            Json::object(
              Map([
                (
                  "command",
                  Json::object(Map([("type", Json::string("string"))])),
                ),
              ]),
            ),
          ),
          ("required", Json::array([Json::string("command")])),
        ]),
      ),
      run=async fn(args, _context) {
        let command = arg_string(args, "command").unwrap_or("")
        guard command != "" else { return "error: no command was given" }
        os_run(self.prefix, command, self.cwd, self.timeout_ms)
      },
    ),
  )
}

///|
pub impl @agent.Middleware for ShellTool with fn before_agent(_self, _context) {
  []
}

///|
pub impl @agent.Middleware for ShellTool with fn wrap_model(
  _self,
  _context,
  call,
  next,
) {
  next(call)
}

///|
pub impl @agent.Middleware for ShellTool with fn wrap_tool(
  _self,
  _context,
  call,
  next,
) {
  next(call)
}

///|
pub impl @agent.Middleware for ShellTool with fn after_agent(
  _self,
  _context,
  _state,
) {
  []
}
