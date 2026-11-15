///|
/// The sequence LangGraph produced for the same graph, written by
/// `scripts/gen_langgraph_events.py`. CI regenerates this file and fails when it differs.
///
/// It is a white-box fixture so that it stays out of the package's public interface: the
/// only reader is the test beside it.
let langgraph_steps : Array[String] = [
  "node:agent", "node:model", "node:tools", "tool:echo", "node:model", "node:finish",
  "answer:done",
]
