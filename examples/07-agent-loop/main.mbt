///|
/// A tool the agent may call: add two integers read from the tool-call JSON.
struct Add {}

///|
impl @tools.Tool for Add with fn descriptor(_self) {
  {
    name: "add",
    description: "add two integers a and b",
    required_parameters: [
      { name: "a", description: "first addend", ptype: @tools.TInteger, },
      { name: "b", description: "second addend", ptype: @tools.TInteger, },
    ],
    optional_parameters: [],
  }
}

///|
impl @tools.Tool for Add with fn execute_raw(_self, args) {
  fn field(k : String) -> Int {
    match args {
      Object(m) =>
        match m.get(k) {
          Some(Number(n, ..)) => n.to_int()
          _ => 0
        }
      _ => 0
    }
  }

  (field("a") + field("b")).to_string()
}

///|
/// The last tool result carried in the prompt, if any.
fn last_tool_result(p : @prompt.Prompt) -> String? {
  let mut found : String? = None
  for msg in p.messages {
    for part in msg.parts {
      if part is @prompt.ToolResult(output~, ..) {
        found = Some(output)
      }
    }
  }
  found
}

///|
/// A client that closes the loop by reading the conversation: with a tool result
/// present it answers from it, otherwise it asks for the `add` tool. The final
/// text is therefore derived from the tool's real output, not a canned string.
struct LoopClient {}

///|
impl @agent.LLMClient for LoopClient with fn execute(
  _self,
  prompt~,
  model~,
  tools~,
) {
  let _ = model
  let _ = tools
  match last_tool_result(prompt) {
    Some(output) => @prompt.Message::assistant("the answer is " + output)
    None =>
      {
        role: @prompt.Assistant,
        parts: [
          @prompt.ToolCall(id=Some("call_233"), tool="add", args={
            "a": 2,
            "b": 3,
          }),
        ],
        finish_reason: None,
        meta: None,
      }
  }
}

///|
impl @agent.LLMClient for LoopClient with fn provider(_self) {
  @llm.deepseek
}

///|
impl @agent.LLMClient for LoopClient with fn moderate(_self, prompt~, model~) {
  let _ = prompt
  let _ = model
  @agent.ModerationResult::safe()
}

///|
impl @agent.LLMClient for LoopClient with fn execute_multiple(
  self,
  prompt~,
  model~,
  tools~,
) {
  [@agent.LLMClient::execute(self, prompt~, model~, tools~)]
}

///|
/// The AIAgent tool-calling loop end to end (Koog's singleRunStrategy): the agent
/// sends the prompt with the tools it may call, runs whatever tool the model asks
/// for, feeds the result back, and repeats until the model answers in plain text.
/// An EventHandler traces every step so the run's shape is visible.
///
///     moon run examples/07-agent-loop --target native
#coverage.skip
async fn main {
  @async.with_task_group(_g => {
    let trace : Array[String] = []
    let events = @agent.EventHandler::new()
      .on_llm_call_starting(_p => trace.push("llm-request"))
      .on_tool_call_starting((tool, args) => {
        trace.push("tool-call " + tool + " " + args.stringify())
      })
      .on_tool_call_completed((tool, result) => {
        trace.push("tool-result " + tool + " => " + result)
      })
    let agent = @agent.AIAgent::new(
      LoopClient::{ },
      model=@llm.deepseek_v4_flash,
      tool_registry=@tools.ToolRegistry::new().add(Add::{ }),
      system_prompt="you can add integers",
      events~,
    )
    let answer = agent.run("what is 2 + 3?") catch {
      e => "error: " + e.to_string()
    }
    for line in trace {
      println(line)
    }
    println("final: " + answer)
  })
}
