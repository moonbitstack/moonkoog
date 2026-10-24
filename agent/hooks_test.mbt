// The hooks that fire when something goes wrong, the ones that bracket a strategy and its
// subgraphs, and the interceptors that can rewrite what is in flight.

///|
/// A tool that always raises — the failure path a registry entry can take.
struct BoomTool {}

///|
impl @tools.Tool for BoomTool with fn descriptor(_self) {
  {
    name: "boom",
    description: "always fails",
    required_parameters: [],
    optional_parameters: [],
  }
}

///|
impl @tools.Tool for BoomTool with fn execute_raw(_self, _args) {
  raise Failure("qwq")
}

///|
/// A reply asking for `tool` with `args`, then whatever the scripted client hands back next.
fn call_of(tool : String, args : Json) -> @prompt.Message {
  {
    role: @prompt.Assistant,
    parts: [@prompt.ToolCall(id=Some("c1"), tool~, args~)],
    finish_reason: None,
    meta: None,
  }
}

///|
async test "a tool that raises fires the tool-failure hook and the model is told" {
  @async.with_task_group(_g => {
    let failures : Array[String] = []
    let results : Array[String] = []
    let events = @agent.EventHandler::new()
      .on_tool_call_failed((tool, error) => failures.push(tool + "/" + error))
      .on_tool_call_completed((tool, result) => {
        results.push(tool + "=" + result)
      })
    let mock = @agent.MockClient::new([
      call_of("boom", Json::object(Map([]))),
      @prompt.Message::assistant("gave up"),
    ])
    let agent = @agent.AIAgent::new(
      mock,
      model=@llm.deepseek_v4_flash,
      tool_registry=@tools.ToolRegistry::new().add(BoomTool::{ }),
      events~,
    )
    let out = agent.run("try it") catch { e => fail(e.to_string()) }
    assert_eq(out, "gave up")
    assert_eq(failures, ["boom/tool error: Failure(qwq)"])
    // The run carries on: what the tool raised is what the model is shown.
    assert_eq(results, ["boom=tool error: Failure(qwq)"])
  })
}

///|
async test "a tool the registry does not have fires the tool-failure hook" {
  @async.with_task_group(_g => {
    let failures : Array[String] = []
    let events = @agent.EventHandler::new().on_tool_call_failed((tool, error) => {
      failures.push(tool + "/" + error)
    })
    let mock = @agent.MockClient::new([
      call_of("nope", Json::object(Map([]))),
      @prompt.Message::assistant("done"),
    ])
    let agent = @agent.AIAgent::new(mock, model=@llm.deepseek_v4_flash, events~)
    let out = agent.run("go") catch { e => fail(e.to_string()) }
    assert_eq(out, "done")
    assert_eq(failures, ["nope/unknown tool: nope"])
  })
}

///|
async test "arguments missing a required parameter fail validation and the tool never runs" {
  @async.with_task_group(_g => {
    let rejected : Array[String] = []
    let ran : Array[String] = []
    let events = @agent.EventHandler::new()
      .on_tool_validation_failed((tool, args, reason) => {
        rejected.push(tool + " " + args.stringify() + " " + reason)
      })
      .on_tool_call_starting((tool, _args) => ran.push(tool))
      .on_tool_call_failed((tool, _error) => ran.push("failed:" + tool))
    let mock = @agent.MockClient::new([
      call_of("add", { "a": 2 }),
      @prompt.Message::assistant("cannot"),
    ])
    let agent = @agent.AIAgent::new(
      mock,
      model=@llm.deepseek_v4_flash,
      tool_registry=@tools.ToolRegistry::new().add(AddTool::{ }),
      events~,
    )
    let out = agent.run("2+?") catch { e => fail(e.to_string()) }
    assert_eq(out, "cannot")
    assert_eq(rejected, [
      "add {\"a\":2} missing required parameter 'b' for 'add'",
    ])
    // The call was not dispatched, so nothing reported it as a *call* failure either.
    assert_eq(ran, ["add"])
  })
}

///|
async test "a tool with every required argument still runs" {
  @async.with_task_group(_g => {
    let rejected : Array[String] = []
    let events = @agent.EventHandler::new().on_tool_validation_failed((
      tool,
      _args,
      _reason,
    ) => rejected.push(tool))
    let agent = @agent.AIAgent::new(
      LoopClient::{ },
      model=@llm.deepseek_v4_flash,
      tool_registry=@tools.ToolRegistry::new().add(AddTool::{ }),
      events~,
    )
    let out = agent.run("what is 2+3?") catch { e => fail(e.to_string()) }
    assert_eq(out, "The answer is 5")
    assert_eq(rejected, [])
  })
}

///|
/// A tool that requires nothing has nothing the descriptor can rule out, so its arguments are
/// taken as they come — even a bare string, which some models send for a no-argument tool.
async test "a tool that requires no parameters accepts arguments of any shape" {
  @async.with_task_group(_g => {
    let rejected : Array[String] = []
    let events = @agent.EventHandler::new()
      .on_tool_validation_failed((tool, _args, _reason) => rejected.push(tool))
      .on_tool_call_completed((tool, result) => {
        rejected.push(tool + "=" + result)
      })
    let mock = @agent.MockClient::new([
      call_of("greet", Json::string("hhh")),
      @prompt.Message::assistant("said hello"),
    ])
    let agent = @agent.AIAgent::new(
      mock,
      model=@llm.deepseek_v4_flash,
      tool_registry=@tools.ToolRegistry::new().add(GreetTool::{ }),
      events~,
    )
    let out = agent.run("say hi") catch { e => fail(e.to_string()) }
    assert_eq(out, "said hello")
    assert_eq(rejected, ["greet=greetings"])
  })
}

///|
/// A node that raises ends the run, and both the node and the agent say so — in that order,
/// innermost first.
async test "a node that raises fires the node-failure and agent-failure hooks" {
  @async.with_task_group(_g => {
    let log : Array[String] = []
    let events = @agent.EventHandler::new()
      .on_node_execution_starting(node => log.push("start:" + node))
      .on_node_execution_completed(node => log.push("done:" + node))
      .on_node_execution_failed((node, error) => {
        log.push("node-failed:" + node + "/" + error)
      })
      .on_agent_execution_failed(error => log.push("agent-failed:" + error))
      .on_agent_completed(_r => log.push("agent-done"))
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([
        @prompt.Message::assistant("one"),
        @prompt.Message::assistant("two"),
      ]),
      model=@llm.deepseek_v4_flash,
      max_iterations=1,
      events~,
    )
    let strategy = @agent.AIAgentStrategy::new("two_calls")
      .node("first", @agent.NodeLLMRequest)
      .node("second", @agent.NodeLLMRequest)
      .edge(@agent.start_node, "first")
      .edge("first", "second")
      .edge("second", @agent.finish_node)
    let raised = try {
      agent.run_strategy(strategy, "hi") |> ignore
      "NO RAISE"
    } catch {
      @agent.AgentError(m) => m
      e => "unexpected: " + e.to_string()
    }
    assert_eq(raised, "max iterations (1) exceeded")
    assert_eq(log, [
      "start:__start__", "done:__start__", "start:first", "done:first", "start:second",
      "node-failed:second/max iterations (1) exceeded", "agent-failed:max iterations (1) exceeded",
    ])
  })
}

///|
async test "the strategy hooks bracket the run, by strategy name" {
  @async.with_task_group(_g => {
    let log : Array[String] = []
    let events = @agent.EventHandler::new()
      .on_agent_starting(input => log.push("agent:" + input))
      .on_strategy_starting(name => log.push("strategy:" + name))
      .on_strategy_completed((name, result) => {
        log.push("strategy-done:" + name + "=" + result)
      })
      .on_agent_completed(result => log.push("agent-done:" + result))
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([@prompt.Message::assistant("hhh")]),
      model=@llm.deepseek_v4_flash,
      events~,
    )
    let out = agent.run("emm") catch { e => fail(e.to_string()) }
    assert_eq(out, "hhh")
    assert_eq(log, [
      "agent:emm", "strategy:single_run", "strategy-done:single_run=hhh", "agent-done:hhh",
    ])
  })
}

///|
async test "the subgraph hooks bracket a nested strategy, by its own name" {
  @async.with_task_group(_g => {
    let log : Array[String] = []
    let events = @agent.EventHandler::new()
      .on_subgraph_execution_starting(name => log.push("sub:" + name))
      .on_subgraph_execution_completed((name, result) => {
        log.push("sub-done:" + name + "=" + result)
      })
    let inner = @agent.AIAgentStrategy::new("inner_strategy")
      .custom_node("shout", (_s, v) => @agent.VText(v.text() + "!"))
      .edge(@agent.start_node, "shout")
      .edge("shout", @agent.finish_node)
    let outer = @agent.AIAgentStrategy::new("outer")
      .subgraph("nested_node", inner)
      .edge(@agent.start_node, "nested_node")
      .edge("nested_node", @agent.finish_node)
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
      events~,
    )
    let out = agent.run_strategy(outer, "qwq") catch {
      e => fail(e.to_string())
    }
    assert_eq(out, "qwq!")
    assert_eq(log, ["sub:inner_strategy", "sub-done:inner_strategy=qwq!"])
  })
}

///|
async test "a retrying subgraph reports once, on the attempt that was kept" {
  @async.with_task_group(_g => {
    let log : Array[String] = []
    let events = @agent.EventHandler::new()
      .on_subgraph_execution_starting(name => log.push("sub:" + name))
      .on_subgraph_execution_completed((name, result) => {
        log.push("sub-done:" + name + "=" + result)
      })
    let tries : Array[Int32] = []
    let inner = @agent.AIAgentStrategy::new("attempt")
      .custom_node("try", (_s, _v) => {
        tries.push(tries.length() + 1)
        @agent.VText(tries.length().to_string())
      })
      .edge(@agent.start_node, "try")
      .edge("try", @agent.finish_node)
    let outer = @agent.AIAgentStrategy::new("until_third")
      .subgraph_retry(
        "attempt",
        inner,
        until=v => v.text() == "3",
        max_retries=5,
      )
      .edge(@agent.start_node, "attempt")
      .edge("attempt", @agent.finish_node)
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
      events~,
    )
    let out = agent.run_strategy(outer, "go") catch { e => fail(e.to_string()) }
    assert_eq(out, "3")
    assert_eq(tries, [1, 2, 3])
    assert_eq(log, ["sub:attempt", "sub-done:attempt=3"])
  })
}

///|
async test "the streaming hooks report the request, each frame, and the assembled reply" {
  @async.with_task_group(_g => {
    let log : Array[String] = []
    let events = @agent.EventHandler::new()
      .on_llm_streaming_starting(p => {
        log.push("stream-start:" + p.messages.length().to_string())
      })
      .on_llm_streaming_frame(chunk => log.push("frame:" + chunk))
      .on_llm_streaming_completed(reply => {
        log.push("stream-done:" + reply.text_content())
      })
    let node_chunks : Array[String] = []
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([@prompt.Message::assistant("hello world")]),
      model=@llm.deepseek_v4_flash,
      events~,
    )
    let strategy = @agent.AIAgentStrategy::new("stream")
      .node("say", @agent.NodeLLMRequestStreaming(c => node_chunks.push(c)))
      .edge(@agent.start_node, "say")
      .edge("say", @agent.finish_node)
    let out = agent.run_strategy(strategy, "hi") catch {
      e => fail(e.to_string())
    }
    assert_eq(out, "hello world")
    // The node's own chunk handler still runs: the hook watches the stream, it does not
    // replace what the node asked for.
    assert_eq(node_chunks, ["hello world"])
    assert_eq(log, [
      "stream-start:1", "frame:hello world", "stream-done:hello world",
    ])
  })
}

///|
/// An interceptor rewrites what is sent, not the conversation the run keeps: the injected line
/// appears once in each request, never accumulating into the next.
async test "an interceptor rewrites the prompt the client receives" {
  @async.with_task_group(_g => {
    let client = RecordingClient::new([
      @prompt.Message::assistant("first"),
      @prompt.Message::assistant("second"),
    ])
    let events = @agent.EventHandler::new().intercept_llm_call_starting(p => {
      p.append(@prompt.Message::user("injected"))
    })
    let agent = @agent.AIAgent::new(
      client,
      model=@llm.deepseek_v4_flash,
      max_iterations=2,
      events~,
    )
    let strategy = @agent.AIAgentStrategy::new("two_calls")
      .node("first", @agent.NodeLLMRequest)
      .node("second", @agent.NodeLLMRequest)
      .edge(@agent.start_node, "first")
      .edge("first", "second")
      .edge("second", @agent.finish_node)
    let out = agent.run_strategy(strategy, "hi") catch {
      e => fail(e.to_string())
    }
    assert_eq(out, "second")
    assert_eq(client.seen.length(), 2)
    assert_eq(client.seen[0].messages.map(m => m.text_content()), [
      "hi", "injected",
    ])
    assert_eq(client.seen[1].messages.map(m => m.text_content()), [
      "hi", "first", "injected",
    ])
  })
}

///|
async test "an interceptor rewrites the reply the graph routes on" {
  @async.with_task_group(_g => {
    let events = @agent.EventHandler::new().intercept_llm_call_completed(reply => {
      @prompt.Message::assistant(reply.text_content().to_upper())
    })
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([@prompt.Message::assistant("hhh")]),
      model=@llm.deepseek_v4_flash,
      events~,
    )
    let out = agent.run("emm") catch { e => fail(e.to_string()) }
    assert_eq(out, "HHH")
  })
}

///|
async test "an interceptor rewrites a tool's arguments before it runs" {
  @async.with_task_group(_g => {
    let events = @agent.EventHandler::new().intercept_tool_call_starting((
      _tool,
      _args,
    ) => { "a": 230, "b": 3 })
    let agent = @agent.AIAgent::new(
      LoopClient::{ },
      model=@llm.deepseek_v4_flash,
      tool_registry=@tools.ToolRegistry::new().add(AddTool::{ }),
      events~,
    )
    let out = agent.run("what is 2+3?") catch { e => fail(e.to_string()) }
    assert_eq(out, "The answer is 233")
  })
}

///|
async test "an interceptor rewrites a tool's result before the model reads it" {
  @async.with_task_group(_g => {
    let events = @agent.EventHandler::new().intercept_tool_call_completed((
      _tool,
      result,
    ) => "<" + result + ">")
    let agent = @agent.AIAgent::new(
      LoopClient::{ },
      model=@llm.deepseek_v4_flash,
      tool_registry=@tools.ToolRegistry::new().add(AddTool::{ }),
      events~,
    )
    let out = agent.run("what is 2+3?") catch { e => fail(e.to_string()) }
    assert_eq(out, "The answer is <5>")
  })
}

///|
/// Interceptors compose in registration order, and an observer registered between them sees
/// what the ones before it produced without changing anything for the ones after.
async test "interceptors chain in registration order, observers in between change nothing" {
  @async.with_task_group(_g => {
    let seen : Array[String] = []
    let events = @agent.EventHandler::new()
      .intercept_llm_call_completed(r => {
        @prompt.Message::assistant(r.text_content() + "-a")
      })
      .on_llm_call_completed(r => seen.push(r.text_content()))
      .intercept_llm_call_completed(r => {
        @prompt.Message::assistant(r.text_content() + "-b")
      })
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([@prompt.Message::assistant("x")]),
      model=@llm.deepseek_v4_flash,
      events~,
    )
    let out = agent.run("go") catch { e => fail(e.to_string()) }
    assert_eq(out, "x-a-b")
    assert_eq(seen, ["x-a"])
  })
}
