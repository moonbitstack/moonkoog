///|
/// Count occurrences of `v` in `xs`.
fn count_of(xs : Array[String], v : String) -> Int32 {
  let mut n = 0
  for x in xs {
    if x == v {
      n = n + 1
    }
  }
  n
}

///|
async test "event hooks observe the agent lifecycle across a tool loop" {
  @async.with_task_group(_g => {
    let log : Array[String] = []
    let events = @agent.EventHandler::new()
      .on_agent_starting(input => log.push("agent-start:" + input))
      .on_llm_call_starting(_p => log.push("llm-start"))
      .on_llm_call_completed(_r => log.push("llm-done"))
      .on_tool_call_starting((tool, _args) => log.push("tool-start:" + tool))
      .on_tool_call_completed((tool, result) => {
        log.push("tool-done:" + tool + "=" + result)
      })
      .on_agent_completed(result => log.push("agent-done:" + result))
    let registry = @tools.ToolRegistry::new().add(AddTool::{ })
    let agent = @agent.AIAgent::new(
      LoopClient::{ },
      model=@llm.deepseek_v4_flash,
      tool_registry=registry,
      events~,
    )
    let out = agent.run("what is 2+3?") catch { e => fail(e.to_string()) }
    assert_eq(out, "The answer is 5")
    // The run starts and finishes exactly once, at the ends of the log.
    assert_eq(log[0], "agent-start:what is 2+3?")
    assert_eq(log[log.length() - 1], "agent-done:The answer is 5")
    // Two LLM calls (request + send-tool-result) bracket one tool call.
    assert_eq(count_of(log, "llm-start"), 2)
    assert_eq(count_of(log, "llm-done"), 2)
    assert_eq(count_of(log, "tool-start:add"), 1)
    assert_eq(count_of(log, "tool-done:add=5"), 1)
  })
}

///|
async test "event handlers chain: both observers on a hook fire, in order" {
  @async.with_task_group(_g => {
    let hits : Array[String] = []
    let events = @agent.EventHandler::new()
      .on_agent_completed(r => hits.push("a:" + r))
      .on_agent_completed(r => hits.push("b:" + r))
    let mock = @agent.MockClient::new([@prompt.Message::assistant("done")])
    let agent = @agent.AIAgent::new(mock, model=@llm.deepseek_v4_flash, events~)
    let _ = agent.run("hi") catch { e => fail(e.to_string()) }
    assert_eq(hits, ["a:done", "b:done"])
  })
}

///|
async test "an agent with no event handler runs unchanged" {
  @async.with_task_group(_g => {
    let mock = @agent.MockClient::new([@prompt.Message::assistant("plain")])
    let agent = @agent.AIAgent::new(mock, model=@llm.deepseek_v4_flash)
    let out = agent.run("hi") catch { e => fail(e.to_string()) }
    assert_eq(out, "plain")
  })
}
