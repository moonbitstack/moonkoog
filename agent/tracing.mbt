// Run tracing (← Koog's agents-features-trace `Tracing`). Koog's feature renders each pipeline
// event to a `FeatureMessageProcessor` — its file, log and remote writers are three
// implementations of that one contract. Here the contract is `TraceWriter` and the feature is
// `EventHandler::tracing`, which registers an observer on every hook. Everything it installs
// observes: a trace must not be able to change the run it is watching.

///|
/// One thing that happened during a run, as a `TraceWriter` is shown it. `kind` names the hook
/// that fired — dotted and stable, so a filter can select on it; `name` is what it was about (a
/// node, a tool, a strategy) and is empty where the hook has no subject; `detail` is the payload
/// as text.
pub(all) struct TraceEvent {
  kind : String
  name : String
  detail : String
} derive(Eq, Debug)

///|
/// The event on one line — `kind name: detail`, with whichever parts are empty left out.
pub fn TraceEvent::render(self : TraceEvent) -> String {
  let head = if self.name == "" {
    self.kind
  } else {
    self.kind + " " + self.name
  }
  if self.detail == "" {
    head
  } else {
    head + ": " + self.detail
  }
}

///|
/// Where a run's trace goes (Koog's `FeatureMessageProcessor`). Synchronous, as the hooks that
/// feed it are; a writer that has to do I/O buffers it itself.
pub(open) trait TraceWriter {
  fn write(Self, event : TraceEvent) -> Unit
}

///|
/// A trace kept in memory: what a test asserts against, and what a caller reads back once the
/// run is over.
pub struct TraceCollector {
  events : Array[TraceEvent]
}

///|
/// An empty collector.
pub fn TraceCollector::new() -> TraceCollector {
  { events: [], }
}

///|
/// Everything written so far, in the order it happened.
pub fn TraceCollector::events(self : TraceCollector) -> Array[TraceEvent] {
  [..self.events]
}

///|
/// Everything written so far, rendered one line each.
pub fn TraceCollector::lines(self : TraceCollector) -> Array[String] {
  self.events.map(e => e.render())
}

///|
/// The `name`s of the events of one `kind`, in order — the run's node sequence is
/// `of_kind("node.starting")`.
pub fn TraceCollector::of_kind(
  self : TraceCollector,
  kind : String,
) -> Array[String] {
  let out = []
  for e in self.events {
    if e.kind == kind {
      out.push(e.name)
    }
  }
  out
}

///|
pub impl TraceWriter for TraceCollector with fn write(self, event) {
  self.events.push(event)
}

///|
/// A writer that hands each event's rendered line to `sink` — the whole of a log writer, a file
/// writer or a socket writer, given something to write a line to.
pub struct LineTrace {
  sink : (String) -> Unit
}

///|
/// A writer that calls `sink` with one rendered line per event.
pub fn LineTrace::new(sink : (String) -> Unit) -> LineTrace {
  { sink, }
}

///|
pub impl TraceWriter for LineTrace with fn write(self, event) {
  (self.sink)(event.render())
}

///|
/// Render every hook of this handler to `writer` (Koog's `Tracing` feature installed on an
/// agent), returning the handler so registration chains. `filter` decides which events are
/// written — Koog's `messageFilter`, the way a caller traces the node sequence without the whole
/// conversation going by. Only observers are installed, so tracing a run cannot change it.
pub fn EventHandler::tracing(
  self : EventHandler,
  writer : &TraceWriter,
  filter? : (TraceEvent) -> Bool = _ => true,
) -> EventHandler {
  let emit = (kind, name, detail) => {
    let event : TraceEvent = { kind, name, detail, }
    if filter(event) {
      writer.write(event)
    }
  }
  self
  .on_agent_starting(input => emit("agent.starting", "", input))
  .on_agent_completed(result => emit("agent.completed", "", result))
  .on_agent_execution_failed(error => emit("agent.failed", "", error))
  .on_strategy_starting(name => emit("strategy.starting", name, ""))
  .on_strategy_completed((name, result) => {
    emit("strategy.completed", name, result)
  })
  .on_node_execution_starting(node => emit("node.starting", node, ""))
  .on_node_execution_completed(node => emit("node.completed", node, ""))
  .on_node_execution_failed((node, error) => emit("node.failed", node, error))
  .on_subgraph_execution_starting(name => emit("subgraph.starting", name, ""))
  .on_subgraph_execution_completed((name, result) => {
    emit("subgraph.completed", name, result)
  })
  .on_llm_call_starting(prompt => {
    emit("llm.starting", "", prompt_digest(prompt))
  })
  .on_llm_call_completed(reply => {
    emit("llm.completed", "", reply.text_content())
  })
  .on_llm_streaming_starting(prompt => {
    emit("llm.streaming.starting", "", prompt_digest(prompt))
  })
  .on_llm_streaming_frame(chunk => emit("llm.streaming.frame", "", chunk))
  .on_llm_streaming_completed(reply => {
    emit("llm.streaming.completed", "", reply.text_content())
  })
  .on_tool_call_starting((tool, args) => {
    emit("tool.starting", tool, args.stringify())
  })
  .on_tool_call_completed((tool, result) => emit("tool.completed", tool, result))
  .on_tool_call_failed((tool, error) => emit("tool.failed", tool, error))
  .on_tool_validation_failed((tool, _args, reason) => {
    emit("tool.validation_failed", tool, reason)
  })
}

///|
/// What a traced request says about its prompt: the last message's text. The whole conversation
/// is in the trace already, one `llm.starting` at a time, and repeating all of it on every call
/// makes a trace that costs more to read than the run did to make.
fn prompt_digest(prompt : @prompt.Prompt) -> String {
  let text = match prompt.messages.last() {
    Some(m) => m.text_content()
    None => ""
  }
  // A tool call and a tool result have no text of their own, and an empty line in a trace reads
  // as a dropped event; how long the conversation had grown is the useful thing to say instead.
  if text == "" {
    prompt.messages.length().to_string() + " messages"
  } else {
    text
  }
}

///|
pub extend LineTrace with TraceWriter::{write}

///|
pub extend TraceCollector with TraceWriter::{write}

///|
pub extend TraceEvent with Debug::{to_repr}

///|
pub extend TraceEvent with Eq::{not_equal, equal}
