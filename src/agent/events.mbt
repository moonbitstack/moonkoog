///|
/// What a run broadcasts: one variant per boundary worth observing. The stream is data so it
/// can be rendered as log lines, counted in tests, or translated into OpenTelemetry spans
/// without the observer reaching into the graph.
pub(all) enum Event {
  AgentStarted(name~ : String)
  AgentFinished(name~ : String, text~ : String)
  AgentFailed(name~ : String, reason~ : String)
  ModelStarted(name~ : String, model~ : String)
  ModelFinished(name~ : String, usage~ : @moonmuse.Usage)
  ToolStarted(name~ : String, call_id~ : String)
  ToolFinished(name~ : String, call_id~ : String, failed~ : Bool)
  HandedOver(from~ : String, to~ : String)
  NodeStarted(name~ : String)
  NodeFinished(name~ : String)
}

///|
/// The subscriber a run reports to. Every run has one; the default drops what it is told.
pub type Listener = (Event) -> Unit

///|
/// Hooks over an agent run: observers that watch, and interceptors that rewrite the value in
/// flight. Every registration chains after what was registered before, so several handlers
/// fire and several interceptors compose left to right.
///
/// The interceptors are the only way to change what is sent, what comes back and what a tool
/// receives, which keeps a run's conversation and a hook's edits in one place. Hooks are
/// synchronous; anything that has to await belongs in middleware, whose hooks are async.
pub struct EventHandler {
  mut listener : Listener
  mut on_agent_starting : (String) -> Unit
  mut on_agent_completed : (String) -> Unit
  mut on_agent_execution_failed : (String) -> Unit
  mut on_strategy_starting : (String) -> Unit
  mut on_strategy_completed : (String, String) -> Unit
  mut on_llm_call_starting : (@moonmuse.Request) -> @moonmuse.Request
  mut on_llm_call_completed : (@moonmuse.Reply) -> @moonmuse.Reply
  mut on_llm_streaming_starting : (@moonmuse.Request) -> Unit
  mut on_llm_streaming_frame : (String) -> Unit
  mut on_llm_streaming_completed : (@moonmuse.Reply) -> Unit
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
/// A handler with every observer a no-op and every interceptor the identity.
pub fn EventHandler::new() -> EventHandler {
  {
    listener: _event => (),
    on_agent_starting: _name => (),
    on_agent_completed: _text => (),
    on_agent_execution_failed: _reason => (),
    on_strategy_starting: _strategy => (),
    on_strategy_completed: (_strategy, _text) => (),
    on_llm_call_starting: request => request,
    on_llm_call_completed: reply => reply,
    on_llm_streaming_starting: _request => (),
    on_llm_streaming_frame: _chunk => (),
    on_llm_streaming_completed: _reply => (),
    on_tool_call_starting: (_tool, args) => args,
    on_tool_call_completed: (_tool, content) => content,
    on_tool_call_failed: (_tool, _reason) => (),
    on_tool_validation_failed: (_tool, _args, _reason) => (),
    on_node_execution_starting: _node => (),
    on_node_execution_completed: _node => (),
    on_node_execution_failed: (_node, _reason) => (),
    on_subgraph_execution_starting: _name => (),
    on_subgraph_execution_completed: (_name, _text) => (),
  }
}

///|
/// Subscribe to the run's event stream. Chains.
pub fn EventHandler::observe(
  self : EventHandler,
  listener : (Event) -> Unit,
) -> EventHandler {
  let previous = self.listener
  self.listener = event => {
    previous(event)
    listener(event)
  }
  self
}

///|
/// Report one event to the subscriber.
pub fn EventHandler::report(self : EventHandler, event : Event) -> Unit {
  (self.listener)(event)
}

///|
/// Observe the agent starting, with the text it was given. Chains.
pub fn EventHandler::on_agent_starting(
  self : EventHandler,
  handler : (String) -> Unit,
) -> EventHandler {
  let previous = self.on_agent_starting
  self.on_agent_starting = name => {
    previous(name)
    handler(name)
  }
  self
}

///|
/// Observe the agent completing, with its answer. Chains.
pub fn EventHandler::on_agent_completed(
  self : EventHandler,
  handler : (String) -> Unit,
) -> EventHandler {
  let previous = self.on_agent_completed
  self.on_agent_completed = text => {
    previous(text)
    handler(text)
  }
  self
}

///|
/// Observe a run ending without an answer, with the reason. Chains.
pub fn EventHandler::on_agent_execution_failed(
  self : EventHandler,
  handler : (String) -> Unit,
) -> EventHandler {
  let previous = self.on_agent_execution_failed
  self.on_agent_execution_failed = reason => {
    previous(reason)
    handler(reason)
  }
  self
}

///|
/// Observe the strategy starting, by name. Chains.
pub fn EventHandler::on_strategy_starting(
  self : EventHandler,
  handler : (String) -> Unit,
) -> EventHandler {
  let previous = self.on_strategy_starting
  self.on_strategy_starting = strategy => {
    previous(strategy)
    handler(strategy)
  }
  self
}

///|
/// Observe the strategy completing, with its name and the answer. Chains.
pub fn EventHandler::on_strategy_completed(
  self : EventHandler,
  handler : (String, String) -> Unit,
) -> EventHandler {
  let previous = self.on_strategy_completed
  self.on_strategy_completed = (strategy, text) => {
    previous(strategy, text)
    handler(strategy, text)
  }
  self
}

///|
/// Rewrite a request just before it is sent: what comes back is what the provider receives,
/// while the conversation the run keeps is untouched. Chains.
pub fn EventHandler::intercept_llm_call_starting(
  self : EventHandler,
  handler : (@moonmuse.Request) -> @moonmuse.Request,
) -> EventHandler {
  let previous = self.on_llm_call_starting
  self.on_llm_call_starting = request => handler(previous(request))
  self
}

///|
/// Observe each request just before it is sent, as the interceptors left it. Chains, and
/// changes nothing in flight.
pub fn EventHandler::on_llm_call_starting(
  self : EventHandler,
  handler : (@moonmuse.Request) -> Unit,
) -> EventHandler {
  self.intercept_llm_call_starting(request => {
    handler(request)
    request
  })
}

///|
/// Rewrite a reply: what comes back is what the graph routes on and what the conversation
/// records. Chains.
pub fn EventHandler::intercept_llm_call_completed(
  self : EventHandler,
  handler : (@moonmuse.Reply) -> @moonmuse.Reply,
) -> EventHandler {
  let previous = self.on_llm_call_completed
  self.on_llm_call_completed = reply => handler(previous(reply))
  self
}

///|
/// Observe each reply. Chains, and changes nothing in flight.
pub fn EventHandler::on_llm_call_completed(
  self : EventHandler,
  handler : (@moonmuse.Reply) -> Unit,
) -> EventHandler {
  self.intercept_llm_call_completed(reply => {
    handler(reply)
    reply
  })
}

///|
/// Observe a streamed request starting. Chains.
pub fn EventHandler::on_llm_streaming_starting(
  self : EventHandler,
  handler : (@moonmuse.Request) -> Unit,
) -> EventHandler {
  let previous = self.on_llm_streaming_starting
  self.on_llm_streaming_starting = request => {
    previous(request)
    handler(request)
  }
  self
}

///|
/// Observe each text delta off a streamed reply. Chains.
pub fn EventHandler::on_llm_streaming_frame(
  self : EventHandler,
  handler : (String) -> Unit,
) -> EventHandler {
  let previous = self.on_llm_streaming_frame
  self.on_llm_streaming_frame = chunk => {
    previous(chunk)
    handler(chunk)
  }
  self
}

///|
/// Observe a streamed reply once the stream ended. Chains.
pub fn EventHandler::on_llm_streaming_completed(
  self : EventHandler,
  handler : (@moonmuse.Reply) -> Unit,
) -> EventHandler {
  let previous = self.on_llm_streaming_completed
  self.on_llm_streaming_completed = reply => {
    previous(reply)
    handler(reply)
  }
  self
}

///|
/// Rewrite a tool call's arguments before the tool runs. Chains.
pub fn EventHandler::intercept_tool_call_starting(
  self : EventHandler,
  handler : (String, Json) -> Json,
) -> EventHandler {
  let previous = self.on_tool_call_starting
  self.on_tool_call_starting = (tool, args) => {
    handler(tool, previous(tool, args))
  }
  self
}

///|
/// Observe each tool call before it runs. Chains, and changes nothing in flight.
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
/// Rewrite a tool's result — where a long output is truncated or a secret redacted before the
/// model reads it. Chains.
pub fn EventHandler::intercept_tool_call_completed(
  self : EventHandler,
  handler : (String, String) -> String,
) -> EventHandler {
  let previous = self.on_tool_call_completed
  self.on_tool_call_completed = (tool, content) => {
    handler(tool, previous(tool, content))
  }
  self
}

///|
/// Observe each tool result. Chains, and changes nothing in flight.
pub fn EventHandler::on_tool_call_completed(
  self : EventHandler,
  handler : (String, String) -> Unit,
) -> EventHandler {
  self.intercept_tool_call_completed((tool, content) => {
    handler(tool, content)
    content
  })
}

///|
/// Observe a call that produced no result — the tool raised, or the model named one that does
/// not exist — with the reason that goes back to the model. Chains.
pub fn EventHandler::on_tool_call_failed(
  self : EventHandler,
  handler : (String, String) -> Unit,
) -> EventHandler {
  let previous = self.on_tool_call_failed
  self.on_tool_call_failed = (tool, reason) => {
    previous(tool, reason)
    handler(tool, reason)
  }
  self
}

///|
/// Observe arguments rejected before the tool ran. Chains.
pub fn EventHandler::on_tool_validation_failed(
  self : EventHandler,
  handler : (String, Json, String) -> Unit,
) -> EventHandler {
  let previous = self.on_tool_validation_failed
  self.on_tool_validation_failed = (tool, args, reason) => {
    previous(tool, args, reason)
    handler(tool, args, reason)
  }
  self
}

///|
/// Observe each node before it runs. Chains.
pub fn EventHandler::on_node_execution_starting(
  self : EventHandler,
  handler : (String) -> Unit,
) -> EventHandler {
  let previous = self.on_node_execution_starting
  self.on_node_execution_starting = node => {
    previous(node)
    handler(node)
  }
  self
}

///|
/// Observe each node after it runs. Chains.
pub fn EventHandler::on_node_execution_completed(
  self : EventHandler,
  handler : (String) -> Unit,
) -> EventHandler {
  let previous = self.on_node_execution_completed
  self.on_node_execution_completed = node => {
    previous(node)
    handler(node)
  }
  self
}

///|
/// Observe a node that raised; the error still ends the run. Chains.
pub fn EventHandler::on_node_execution_failed(
  self : EventHandler,
  handler : (String, String) -> Unit,
) -> EventHandler {
  let previous = self.on_node_execution_failed
  self.on_node_execution_failed = (node, reason) => {
    previous(node, reason)
    handler(node, reason)
  }
  self
}

///|
/// Observe a nested strategy before it is walked. Chains.
pub fn EventHandler::on_subgraph_execution_starting(
  self : EventHandler,
  handler : (String) -> Unit,
) -> EventHandler {
  let previous = self.on_subgraph_execution_starting
  self.on_subgraph_execution_starting = name => {
    previous(name)
    handler(name)
  }
  self
}

///|
/// Observe a nested strategy after it finished, with its answer. Chains.
pub fn EventHandler::on_subgraph_execution_completed(
  self : EventHandler,
  handler : (String, String) -> Unit,
) -> EventHandler {
  let previous = self.on_subgraph_execution_completed
  self.on_subgraph_execution_completed = (name, text) => {
    previous(name, text)
    handler(name, text)
  }
  self
}
