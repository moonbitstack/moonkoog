///|
/// A stateless tool: add two integers from the JSON args.
struct AddTool {}

///|
impl @tools.Tool for AddTool with fn descriptor(_self) {
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
impl @tools.Tool for AddTool with fn execute_raw(_self, args) {
  (json_int(args, "a") + json_int(args, "b")).to_string()
}

///|
fn json_int(j : Json, key : String) -> Int {
  match j {
    Object(m) =>
      match m.get(key) {
        Some(Number(n, ..)) => n.to_int()
        _ => 0
      }
    _ => 0
  }
}

///|
/// The output of the last tool result carried in the prompt, if any.
fn find_tool_result(p : @prompt.Prompt) -> String? {
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
/// A stateless client that closes the loop by reading the conversation: when a
/// tool result is present it answers with it, otherwise it requests the `add`
/// tool. A passing assertion therefore proves the tool ran AND its result was fed
/// back into the next request — the whole singleRunStrategy wiring, not just that
/// a canned string came back.
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
  match find_tool_result(prompt) {
    Some(output) => @prompt.Message::assistant("The answer is " + output)
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
  @llm.openai
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
async test "agent runs the singleRunStrategy loop end to end: request, execute tool, feed back, finish" {
  @async.with_task_group(_g => {
    let registry = @tools.ToolRegistry::new().add(AddTool::{ })
    let agent = @agent.AIAgent::new(
      LoopClient::{ },
      model=@llm.deepseek_v4_flash,
      tool_registry=registry,
      system_prompt="you can add",
    )
    let out = agent.run("what is 2+3?") catch {
      e => fail("agent raised: " + e.to_string())
    }
    // Break any link — the tool step, the append, the loop-back — and this fails.
    assert_eq(out, "The answer is 5")
  })
}

///|
async test "agent finishes immediately when the first reply is plain text" {
  @async.with_task_group(_g => {
    let mock = @agent.MockClient::new([@prompt.Message::assistant("hi there")])
    let agent = @agent.AIAgent::new(mock, model=@llm.deepseek_v4_flash)
    let out = agent.run("hello") catch { e => fail(e.to_string()) }
    assert_eq(out, "hi there")
  })
}
