///|
struct Add {}

///|
impl @tools.Tool for Add with fn descriptor(_self) {
  {
    name: "add",
    description: "add two integers a and b",
    required_parameters: [
      { name: "a", description: "first", ptype: @tools.TInteger, },
      { name: "b", description: "second", ptype: @tools.TInteger, },
    ],
    optional_parameters: [],
  }
}

///|
impl @tools.Tool for Add with fn execute_raw(_self, args) {
  fn field(k : String) -> Int32 {
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
/// A client that asks for `add` once, then answers from the tool result.
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
  let mut result : String? = None
  for msg in prompt.messages {
    for part in msg.parts {
      if part is @prompt.ToolResult(output~, ..) {
        result = Some(output)
      }
    }
  }
  match result {
    Some(output) => @prompt.Message::assistant("the answer is " + output)
    None =>
      {
        role: @prompt.Assistant,
        parts: [
          @prompt.ToolCall(id=Some("c1"), tool="add", args={ "a": 2, "b": 3 }),
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
/// The event hooks (Koog's `EventHandler`): every callback on the lifecycle is
/// wired to a log, so one tool-loop run prints its whole shape — agent start, each
/// node visit, the two LLM calls that bracket the tool call, and agent completion.
/// Handlers chain, so more than one observer can watch the same hook.
///
///     moon run examples/10-agent-events --target native
#coverage.skip
async fn main {
  @async.with_task_group(_g => {
    let log : Array[String] = []
    let events = @agent.EventHandler::new()
      .on_agent_starting(input => log.push("agent-start: " + input))
      .on_node_execution_starting(n => log.push("  node-enter: " + n))
      .on_node_execution_completed(n => log.push("  node-exit:  " + n))
      .on_llm_call_starting(_p => log.push("  llm-start"))
      .on_llm_call_completed(_r => log.push("  llm-done"))
      .on_tool_call_starting((tool, args) => {
        log.push("  tool-start: " + tool + " " + args.stringify())
      })
      .on_tool_call_completed((tool, result) => {
        log.push("  tool-done:  " + tool + " => " + result)
      })
      .on_agent_completed(result => log.push("agent-done: " + result))
    let agent = @agent.AIAgent::new(
      LoopClient::{ },
      model=@llm.deepseek_v4_flash,
      tool_registry=@tools.ToolRegistry::new().add(Add::{ }),
      events~,
    )
    let _ = agent.run("what is 2 + 3?") catch { e => e.to_string() }
    for line in log {
      println(line)
    }
  })
}
