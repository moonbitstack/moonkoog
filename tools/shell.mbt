// The shell tool (Koog agents-ext `ExecuteShellCommandTool`): run a shell command and return
// its output. Execution goes through a `ShellExecutor` seam (Koog's `ShellCommandExecutor`),
// so the tool runs against a real shell or a scripted one in tests — the same injection Koog
// uses so a run can be sandboxed or confirmed before it touches the machine.

///|
/// Runs a shell command line and returns its output (Koog `ShellCommandExecutor`).
pub(open) trait ShellExecutor {
  fn run(Self, command : String) -> String raise
}

///|
/// Run a shell command through the configured executor (Koog `ExecuteShellCommandTool`).
pub struct ExecuteShellCommandTool {
  executor : &ShellExecutor
}

///|
/// A shell-command tool over `executor`.
pub fn ExecuteShellCommandTool::new(
  executor : &ShellExecutor,
) -> ExecuteShellCommandTool {
  { executor, }
}

///|
pub impl Tool for ExecuteShellCommandTool with fn descriptor(_self) {
  {
    name: "execute_shell_command",
    description: "Run a shell command and return its output.",
    required_parameters: [
      {
        name: "command",
        description: "the command line to run",
        ptype: TString,
      },
    ],
    optional_parameters: [],
  }
}

///|
pub impl Tool for ExecuteShellCommandTool with fn execute_raw(self, args) {
  self.executor.run(arg_string(args, "command"))
}

///|
pub extend ExecuteShellCommandTool with Tool::{descriptor, execute_raw}
