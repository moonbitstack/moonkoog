// The shell tool runs the command through the injected executor.

///|
struct EchoExecutor {}

///|
impl @tools.ShellExecutor for EchoExecutor with fn run(_self, command) {
  "ran: " + command
}

///|
test "shell tool: runs a command through the injected executor" {
  let tool = @tools.ExecuteShellCommandTool::new(EchoExecutor::{ })
  assert_eq(
    @tools.Tool::execute_raw(tool, { "command": "ls -la /tmp" }),
    "ran: ls -la /tmp",
  )
}
