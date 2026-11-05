// The tracing feature: an event handler that renders every hook to a `TraceWriter`.

///|
async test "a trace writer records the run's node sequence" {
  @async.with_task_group(_g => {
    let trace = @agent.TraceCollector::new()
    let events = @agent.EventHandler::new().tracing(trace)
    let agent = @agent.AIAgent::new(
      LoopClient::{ },
      model=@models.deepseek_v4_flash,
      tool_registry=@toolbox.ToolRegistry::new().add(AddTool::{ }),
      events~,
    )
    let out = agent.run("what is 2+3?") catch { e => fail(e.to_string()) }
    assert_eq(out, "The answer is 5")
    // The whole walk of `single_run_strategy`, in order.
    assert_eq(trace.of_kind("node.starting"), [
      "__start__", "llm_request", "execute_tools", "send_tool_result", "__finish__",
    ])
    assert_eq(trace.of_kind("node.completed"), [
      "__start__", "llm_request", "execute_tools", "send_tool_result", "__finish__",
    ])
    assert_eq(trace.of_kind("tool.starting"), ["add"])
    assert_eq(trace.of_kind("strategy.starting"), ["single_run"])
  })
}

///|
async test "the trace renders the agent, tools and LLM calls as lines" {
  @async.with_task_group(_g => {
    let lines : Array[String] = []
    let events = @agent.EventHandler::new().tracing(
      @agent.LineTrace::new(line => lines.push(line)),
    )
    let agent = @agent.AIAgent::new(
      LoopClient::{ },
      model=@models.deepseek_v4_flash,
      tool_registry=@toolbox.ToolRegistry::new().add(AddTool::{ }),
      events~,
    )
    let _ = agent.run("what is 2+3?") catch { e => fail(e.to_string()) }
    assert_eq(lines[0], "agent.starting: what is 2+3?")
    assert_eq(lines[lines.length() - 1], "agent.completed: The answer is 5")
    assert_true(lines.contains("tool.starting add: {\"a\":2,\"b\":3}"))
    assert_true(lines.contains("tool.completed add: 5"))
    assert_true(lines.contains("node.starting execute_tools"))
    // The request digest is the last message, not the whole conversation — and where that
    // message is a tool result with no text, how far the conversation had grown.
    assert_true(lines.contains("llm.starting: what is 2+3?"))
    assert_true(lines.contains("llm.starting: 3 messages"))
  })
}

///|
async test "a trace filter keeps only the events it accepts" {
  @async.with_task_group(_g => {
    let trace = @agent.TraceCollector::new()
    let events = @agent.EventHandler::new().tracing(trace, filter=e => {
      e.kind == "node.starting"
    })
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([@moonmuse.Message::assistant("hhh")]),
      model=@models.deepseek_v4_flash,
      events~,
    )
    let _ = agent.run("emm") catch { e => fail(e.to_string()) }
    assert_eq(trace.lines(), [
      "node.starting __start__", "node.starting llm_request", "node.starting __finish__",
    ])
  })
}

///|
async test "a trace records what failed, and tracing never changes the run" {
  @async.with_task_group(_g => {
    let trace = @agent.TraceCollector::new()
    let events = @agent.EventHandler::new().tracing(trace)
    let mock = @agent.MockClient::new([
      call_of("boom", Json::object(Map([]))),
      @moonmuse.Message::assistant("gave up"),
    ])
    let agent = @agent.AIAgent::new(
      mock,
      model=@models.deepseek_v4_flash,
      tool_registry=@toolbox.ToolRegistry::new().add(BoomTool::{ }),
      events~,
    )
    // Same answer as the untraced run: the handler `tracing` installs only observes.
    let out = agent.run("try it") catch { e => fail(e.to_string()) }
    assert_eq(out, "gave up")
    assert_eq(trace.of_kind("tool.failed"), ["boom"])
    assert_true(
      trace.lines().contains("tool.failed boom: tool error: Failure(qwq)"),
    )
  })
}

///|
/// What a caller reads out is a value, not the collector's own list still filling up behind it.
test "the events a collector hands back are a copy" {
  let trace = @agent.TraceCollector::new()
  let writer : &@agent.TraceWriter = trace
  writer.write({ kind: "node.starting", name: "one", detail: "", })
  let taken = trace.events()
  writer.write({ kind: "node.starting", name: "two", detail: "", })
  assert_eq(taken.map(e => e.name), ["one"])
  assert_eq(trace.of_kind("node.starting"), ["one", "two"])
}

///|
test "a trace event renders without its empty parts" {
  let full : @agent.TraceEvent = {
    kind: "tool.completed",
    name: "add",
    detail: "5",
  }
  assert_eq(full.render(), "tool.completed add: 5")
  assert_eq(
    @agent.TraceEvent::{
      kind: "node.starting",
      name: "llm_request",
      detail: "",
    }.render(),
    "node.starting llm_request",
  )
  assert_eq(
    @agent.TraceEvent::{ kind: "agent.completed", name: "", detail: "hhh", }.render(),
    "agent.completed: hhh",
  )
}
