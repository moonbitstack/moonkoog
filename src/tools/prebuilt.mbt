// Prebuilt tools (Koog agents-ext `ai.koog.agents.ext.tool`): ready-made tools an agent can
// be handed. `ExitTool` ends the run with a final answer; `SayToUser` shows a message; and
// `AskUser` puts a question to the user and returns the reply. The user-facing I/O of the
// latter two is injected as a callback — the faithful, testable equivalent of Koog's feature
// that wires them to the console.

///|
/// A string argument from a tool-call's JSON object (empty when absent).
fn arg_string(args : Json, key : String) -> String {
  match args {
    Object(m) =>
      match m.get(key) {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
/// End the agent run and return `result` as the final answer (Koog `ExitTool`).
pub struct ExitTool {}

///|
/// The exit tool.
pub fn ExitTool::new() -> ExitTool {
  ExitTool::{ }
}

///|
pub impl Tool for ExitTool with fn descriptor(_self) {
  {
    name: "__exit__",
    description: "End the task and return the final result to the caller.",
    required_parameters: [
      { name: "result", description: "the final answer", ptype: TString, },
    ],
    optional_parameters: [],
  }
}

///|
pub impl Tool for ExitTool with fn execute_raw(_self, args) {
  arg_string(args, "result")
}

///|
/// Show a message to the user through the configured sink (Koog `SayToUser`).
pub struct SayToUser {
  sink : (String) -> Unit
}

///|
/// A say-to-user tool that writes messages to `sink`.
pub fn SayToUser::new(sink : (String) -> Unit) -> SayToUser {
  { sink, }
}

///|
pub impl Tool for SayToUser with fn descriptor(_self) {
  {
    name: "say_to_user",
    description: "Show a message to the user.",
    required_parameters: [
      { name: "message", description: "the message to show", ptype: TString, },
    ],
    optional_parameters: [],
  }
}

///|
pub impl Tool for SayToUser with fn execute_raw(self, args) {
  (self.sink)(arg_string(args, "message"))
  "Message shown to the user."
}

///|
/// Ask the user a question and return their reply from the configured responder (Koog
/// `AskUser`).
pub struct AskUser {
  responder : (String) -> String
}

///|
/// An ask-user tool that reads replies from `responder`.
pub fn AskUser::new(responder : (String) -> String) -> AskUser {
  { responder, }
}

///|
pub impl Tool for AskUser with fn descriptor(_self) {
  {
    name: "ask_user",
    description: "Ask the user a question and receive their reply.",
    required_parameters: [
      { name: "question", description: "the question to ask", ptype: TString, },
    ],
    optional_parameters: [],
  }
}

///|
pub impl Tool for AskUser with fn execute_raw(self, args) {
  (self.responder)(arg_string(args, "question"))
}

///|
pub extend AskUser with Tool::{descriptor, execute_raw}

///|
pub extend ExitTool with Tool::{descriptor, execute_raw}

///|
pub extend SayToUser with Tool::{descriptor, execute_raw}
