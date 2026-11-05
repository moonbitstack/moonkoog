///|
/// Lifecycle hooks over an agent run (← Koog's agents-features-event-handler
/// `EventHandlerConfig`): the agent starting, failing and completing, the strategy and
/// each of its subgraphs, every node, every LLM call — streamed or not — and every tool
/// call, including the ones that fail validation or raise.
///
/// Two kinds of hook, as Koog's `AIAgentPipeline` has: most are observers, but the LLM and
/// tool hooks are *interceptors* — they take the value in flight and return the one that
/// carries on, so a handler can rewrite a prompt before it is sent, a reply before the graph
/// routes on it, a tool's arguments before it runs, or its output before the model reads it.
/// Registering an observer on an interceptor hook (`on_llm_call_starting`) is the same call
/// it always was and changes nothing in flight; `intercept_llm_call_starting` is the one that
/// rewrites.
///
/// Every registration *chains* after what is already registered for that hook, so several
/// handlers all fire and several interceptors compose left to right in registration order.
/// Hooks are synchronous; an async observer is a later refinement, as Koog's `suspend` hooks
/// are. Koog has three more we do not: a streaming call that fails, a subgraph that fails,
/// and the agent-closing pair.
pub struct EventHandler {
  mut on_agent_starting : (String) -> Unit
  mut on_agent_completed : (String) -> Unit
  mut on_agent_execution_failed : (String) -> Unit
  mut on_strategy_starting : (String) -> Unit
  mut on_strategy_completed : (String, String) -> Unit
  mut on_llm_call_starting : (@moonmuse.Prompt) -> @moonmuse.Prompt
  mut on_llm_call_completed : (@moonmuse.Message) -> @moonmuse.Message
  mut on_llm_streaming_starting : (@moonmuse.Prompt) -> Unit
  mut on_llm_streaming_frame : (String) -> Unit
  mut on_llm_streaming_completed : (@moonmuse.Message) -> Unit
  mut on_tool_call_starting : (String, Json) -> Json
  mut on_tool_call_completed : (String, String) -> String
  mut on_tool_call_failed : (String, String) -> Unit
  mut on_tool_validation_failed : (String, Json, String) -> Unit
  mut on_node_execution_starting : (String) -> Unit
  mut on_node_execution_completed : (String) -> Unit
  mut on_node_execution_failed : (String, String) -> Unit
  mut on_subgraph_execution_starting : (String) -> Unit
  mut on_subgraph_execution_completed : (String, String) -> Unit
}

///|
/// An event handler with every observer a no-op and every interceptor the identity — the
/// default an agent carries when nothing is installed.
pub fn EventHandler::new() -> EventHandler {
  {
    on_agent_starting: _input => (),
    on_agent_completed: _result => (),
    on_agent_execution_failed: _error => (),
    on_strategy_starting: _strategy => (),
    on_strategy_completed: (_strategy, _result) => (),
    on_llm_call_starting: prompt => prompt,
    on_llm_call_completed: reply => reply,
    on_llm_streaming_starting: _prompt => (),
    on_llm_streaming_frame: _chunk => (),
    on_llm_streaming_completed: _reply => (),
    on_tool_call_starting: (_tool, args) => args,
    on_tool_call_completed: (_tool, result) => result,
    on_tool_call_failed: (_tool, _error) => (),
    on_tool_validation_failed: (_tool, _args, _reason) => (),
    on_node_execution_starting: _node => (),
    on_node_execution_completed: _node => (),
    on_node_execution_failed: (_node, _error) => (),
    on_subgraph_execution_starting: _node => (),
    on_subgraph_execution_completed: (_node, _result) => (),
  }
}

///|
/// Observe the agent starting, on its `input`. Chains after any prior handler.
pub fn EventHandler::on_agent_starting(
  self : EventHandler,
  handler : (String) -> Unit,
) -> EventHandler {
  let prev = self.on_agent_starting
  self.on_agent_starting = input => {
    prev(input)
    handler(input)
  }
  self
}

///|
/// Observe the agent completing, with its final text. Chains.
pub fn EventHandler::on_agent_completed(
  self : EventHandler,
  handler : (String) -> Unit,
) -> EventHandler {
  let prev = self.on_agent_completed
  self.on_agent_completed = result => {
    prev(result)
    handler(result)
  }
  self
}

///|
/// Observe a run ending without a result, with the error's message. A run stopped through its
/// `RunHandle` ends this way too — the stop is raised, and either way the run produced no
/// answer. Chains.
pub fn EventHandler::on_agent_execution_failed(
  self : EventHandler,
  handler : (String) -> Unit,
) -> EventHandler {
  let prev = self.on_agent_execution_failed
  self.on_agent_execution_failed = error => {
    prev(error)
    handler(error)
  }
  self
}

///|
/// Observe the run's strategy starting, by name. A nested subgraph reports through the
/// subgraph hooks, not this one. Chains.
pub fn EventHandler::on_strategy_starting(
  self : EventHandler,
  handler : (String) -> Unit,
) -> EventHandler {
  let prev = self.on_strategy_starting
  self.on_strategy_starting = strategy => {
    prev(strategy)
    handler(strategy)
  }
  self
}

///|
/// Observe the run's strategy completing, with its name and the finish node's text. Chains.
pub fn EventHandler::on_strategy_completed(
  self : EventHandler,
  handler : (String, String) -> Unit,
) -> EventHandler {
  let prev = self.on_strategy_completed
  self.on_strategy_completed = (strategy, result) => {
    prev(strategy, result)
    handler(strategy, result)
  }
  self
}

///|
/// Rewrite each LLM request just before it is sent: the prompt returned is what the client
/// receives, while the conversation the run keeps is untouched. Chains — each interceptor sees
/// what the one before it returned.
pub fn EventHandler::intercept_llm_call_starting(
  self : EventHandler,
  handler : (@moonmuse.Prompt) -> @moonmuse.Prompt,
) -> EventHandler {
  let prev = self.on_llm_call_starting
  self.on_llm_call_starting = prompt => handler(prev(prompt))
  self
}

///|
/// Observe each LLM request just before it is sent, with the prompt as the interceptors left
/// it. Chains, and changes nothing in flight.
pub fn EventHandler::on_llm_call_starting(
  self : EventHandler,
  handler : (@moonmuse.Prompt) -> Unit,
) -> EventHandler {
  self.intercept_llm_call_starting(prompt => {
    handler(prompt)
    prompt
  })
}

///|
/// Rewrite each LLM reply: the message returned is what the graph routes on and what the
/// conversation records. Chains.
pub fn EventHandler::intercept_llm_call_completed(
  self : EventHandler,
  handler : (@moonmuse.Message) -> @moonmuse.Message,
) -> EventHandler {
  let prev = self.on_llm_call_completed
  self.on_llm_call_completed = reply => handler(prev(reply))
  self
}

///|
/// Observe each LLM reply, with the assistant message. Chains, and changes nothing in flight.
pub fn EventHandler::on_llm_call_completed(
  self : EventHandler,
  handler : (@moonmuse.Message) -> Unit,
) -> EventHandler {
  self.intercept_llm_call_completed(reply => {
    handler(reply)
    reply
  })
}

///|
/// Observe a streamed request starting, with the prompt. A streamed call fires the plain LLM
/// hooks as well, so an interceptor installed once applies to both kinds. Chains.
pub fn EventHandler::on_llm_streaming_starting(
  self : EventHandler,
  handler : (@moonmuse.Prompt) -> Unit,
) -> EventHandler {
  let prev = self.on_llm_streaming_starting
  self.on_llm_streaming_starting = prompt => {
    prev(prompt)
    handler(prompt)
  }
  self
}

///|
/// Observe each incremental text delta off a streamed reply, as it arrives. Chains.
pub fn EventHandler::on_llm_streaming_frame(
  self : EventHandler,
  handler : (String) -> Unit,
) -> EventHandler {
  let prev = self.on_llm_streaming_frame
  self.on_llm_streaming_frame = chunk => {
    prev(chunk)
    handler(chunk)
  }
  self
}

///|
/// Observe a streamed reply once the stream has ended, with the assembled message. Chains.
pub fn EventHandler::on_llm_streaming_completed(
  self : EventHandler,
  handler : (@moonmuse.Message) -> Unit,
) -> EventHandler {
  let prev = self.on_llm_streaming_completed
  self.on_llm_streaming_completed = reply => {
    prev(reply)
    handler(reply)
  }
  self
}

///|
/// Rewrite a tool call's arguments before it runs: the JSON returned is what the tool is given.
/// Chains.
pub fn EventHandler::intercept_tool_call_starting(
  self : EventHandler,
  handler : (String, Json) -> Json,
) -> EventHandler {
  let prev = self.on_tool_call_starting
  self.on_tool_call_starting = (tool, args) => handler(tool, prev(tool, args))
  self
}

///|
/// Observe each tool call before it runs, with the tool name and JSON arguments. Chains, and
/// changes nothing in flight.
pub fn EventHandler::on_tool_call_starting(
  self : EventHandler,
  handler : (String, Json) -> Unit,
) -> EventHandler {
  self.intercept_tool_call_starting((tool, args) => {
    handler(tool, args)
    args
  })
}

///|
/// Rewrite a tool's result: the string returned is what goes into the conversation, so this is
/// where a long output is truncated or a secret redacted before the model reads it. A call that
/// failed comes through here too, carrying the reason the model will be shown. Chains.
pub fn EventHandler::intercept_tool_call_completed(
  self : EventHandler,
  handler : (String, String) -> String,
) -> EventHandler {
  let prev = self.on_tool_call_completed
  self.on_tool_call_completed = (tool, result) => {
    handler(tool, prev(tool, result))
  }
  self
}

///|
/// Observe each tool call after it runs, with the tool name and the string the model will be
/// shown — a failed call's reason included. Chains, and changes nothing in flight.
pub fn EventHandler::on_tool_call_completed(
  self : EventHandler,
  handler : (String, String) -> Unit,
) -> EventHandler {
  self.intercept_tool_call_completed((tool, result) => {
    handler(tool, result)
    result
  })
}

///|
/// Observe a tool call that produced no result — the tool raised, or the model named a tool no
/// registry entry answers to — with the tool name and the reason. The run carries on: the
/// reason goes back to the model as a failed tool result. Chains.
pub fn EventHandler::on_tool_call_failed(
  self : EventHandler,
  handler : (String, String) -> Unit,
) -> EventHandler {
  let prev = self.on_tool_call_failed
  self.on_tool_call_failed = (tool, error) => {
    prev(tool, error)
    handler(tool, error)
  }
  self
}

///|
/// Observe arguments rejected before the tool ran, with the tool name, the arguments as the
/// model sent them, and what was wrong. Chains.
pub fn EventHandler::on_tool_validation_failed(
  self : EventHandler,
  handler : (String, Json, String) -> Unit,
) -> EventHandler {
  let prev = self.on_tool_validation_failed
  self.on_tool_validation_failed = (tool, args, reason) => {
    prev(tool, args, reason)
    handler(tool, args, reason)
  }
  self
}

///|
/// Observe each strategy node before it runs, by name. Chains.
pub fn EventHandler::on_node_execution_starting(
  self : EventHandler,
  handler : (String) -> Unit,
) -> EventHandler {
  let prev = self.on_node_execution_starting
  self.on_node_execution_starting = node => {
    prev(node)
    handler(node)
  }
  self
}

///|
/// Observe each strategy node after it runs, by name. Chains.
pub fn EventHandler::on_node_execution_completed(
  self : EventHandler,
  handler : (String) -> Unit,
) -> EventHandler {
  let prev = self.on_node_execution_completed
  self.on_node_execution_completed = node => {
    prev(node)
    handler(node)
  }
  self
}

///|
/// Observe a node that raised, with its name and the error's message. The error goes on to end
/// the run — this hook watches, it does not recover. Chains.
pub fn EventHandler::on_node_execution_failed(
  self : EventHandler,
  handler : (String, String) -> Unit,
) -> EventHandler {
  let prev = self.on_node_execution_failed
  self.on_node_execution_failed = (node, error) => {
    prev(node, error)
    handler(node, error)
  }
  self
}

///|
/// Observe a subgraph before its nested graph is walked, by the nested strategy's name — the
/// node hooks already report the position in the parent graph. Chains.
pub fn EventHandler::on_subgraph_execution_starting(
  self : EventHandler,
  handler : (String) -> Unit,
) -> EventHandler {
  let prev = self.on_subgraph_execution_starting
  self.on_subgraph_execution_starting = node => {
    prev(node)
    handler(node)
  }
  self
}

///|
/// Observe a subgraph after its nested graph finished, with the nested strategy's name and the
/// text its finish node carried out. A retrying subgraph reports once, on the attempt that was
/// kept. Chains.
pub fn EventHandler::on_subgraph_execution_completed(
  self : EventHandler,
  handler : (String, String) -> Unit,
) -> EventHandler {
  let prev = self.on_subgraph_execution_completed
  self.on_subgraph_execution_completed = (node, result) => {
    prev(node, result)
    handler(node, result)
  }
  self
}
