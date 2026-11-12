///|
/// Translate an agent's run into OpenTelemetry spans.
///
/// Two signals are all a GenAI trace needs: an `invoke_agent` span around the run, with the
/// agent's name and the tokens it spent, and an `execute_tool` span around each tool call. Both
/// take their attribute names from the semantic conventions, so a collector that understands
/// GenAI — Langfuse, Phoenix, Grafana — reads the trace without a mapping table.
///
/// The library never reads a clock of its own: `now` supplies the nanosecond timestamps, so a
/// replay can be traced on a timeline the caller chose.
pub struct Otel {
  tracer : @trace.Tracer
  now : () -> Int64
  agents : Map[String, @trace.Span]
  tools : Map[String, @trace.Span]
}

///|
/// A translator writing to `tracer`, timestamped by `now`.
pub fn Otel::new(tracer~ : @trace.Tracer, now~ : () -> Int64) -> Otel {
  { tracer, now, agents: Map([]), tools: Map([]), }
}

///|
/// Subscribe to the run's events. The handler returned is the same one, with the translator
/// chained on, so installing it does not change what else observes the run.
pub fn Otel::install(
  self : Otel,
  events : @agent.EventHandler,
) -> @agent.EventHandler {
  events.observe(event => self.record(event))
}

///|
/// The span name for an agent run. The GenAI conventions put the operation first and the
/// subject after it.
pub fn agent_span_name(agent : String) -> String {
  "invoke_agent " + agent
}

///|
/// The span name for a tool call.
pub fn tool_span_name(tool : String) -> String {
  "execute_tool " + tool
}

///|
/// Record one event: start, annotate or end the span it belongs to.
fn Otel::record(self : Otel, event : @agent.Event) -> Unit {
  match event {
    AgentStarted(name~) => {
      let attributes : Array[(String, @trace.Value)] = [
        (@semconv.gen_ai_operation_name, @trace.Value::Str("invoke_agent")),
        (@semconv.gen_ai_agent_name, @trace.Value::Str(name)),
      ]
      match self.start(agent_span_name(name), None, attributes) {
        Some(span) => self.agents[name] = span
        None => ()
      }
    }
    ModelFinished(name~, usage~) =>
      match self.agents.get(name) {
        Some(span) => {
          match usage.input {
            Some(tokens) =>
              span.set_attribute(
                @semconv.gen_ai_usage_input_tokens,
                @trace.Value::Int(tokens.to_int64()),
              )
            None => ()
          }
          match usage.output {
            Some(tokens) =>
              span.set_attribute(
                @semconv.gen_ai_usage_output_tokens,
                @trace.Value::Int(tokens.to_int64()),
              )
            None => ()
          }
        }
        None => ()
      }
    ToolStarted(name~, call_id~) => {
      let parent = self.parent_of(name)
      let attributes : Array[(String, @trace.Value)] = [
        (@semconv.gen_ai_operation_name, @trace.Value::Str("execute_tool")),
        (@semconv.gen_ai_tool_name, @trace.Value::Str(name)),
        (@semconv.gen_ai_tool_call_id, @trace.Value::Str(call_id)),
      ]
      match self.start(tool_span_name(name), parent, attributes) {
        Some(span) => self.tools[call_id] = span
        None => ()
      }
    }
    ToolFinished(call_id~, failed~, ..) =>
      match self.tools.get(call_id) {
        Some(span) => {
          if failed {
            span.set_status(@trace.Status::Error("the tool call failed"))
          } else {
            span.set_status(@trace.Status::Ok)
          }
          self.end(span)
          self.tools.remove(call_id)
        }
        None => ()
      }
    AgentFinished(name~, ..) => self.finish_agent(name)
    AgentFailed(name~, reason~) =>
      match self.agents.get(name) {
        Some(span) => {
          span.set_status(@trace.Status::Error(reason))
          self.end(span)
          self.agents.remove(name)
        }
        None => ()
      }
    HandedOver(from~, to~) =>
      match self.agents.get(from) {
        Some(span) =>
          span.add_event(
            "handoff",
            attributes=[
              (@semconv.gen_ai_transfer_target_name, @trace.Value::Str(to)),
            ],
            at=(self.now)(),
          )
        None => ()
      }
    ModelStarted(..) | NodeStarted(_) | NodeFinished(_) => ()
  }
}

///|
/// End the agent's span, if it is still open.
fn Otel::finish_agent(self : Otel, name : String) -> Unit {
  match self.agents.get(name) {
    Some(span) => {
      span.set_status(@trace.Status::Ok)
      self.end(span)
      self.agents.remove(name)
    }
    None => ()
  }
}

///|
/// End a span. What it recorded reaches the tracer's sink.
fn Otel::end(self : Otel, span : @trace.Span) -> Unit {
  span.finish(at=(self.now)())
}

///|
/// The context of the agent's open span, which a tool span hangs under.
fn Otel::parent_of(self : Otel, name : String) -> @trace.TraceContext? {
  match self.agents.get(name) {
    Some(span) => Some(span.context())
    None => None
  }
}

///|
/// Start a span, treating a tracer that refuses its own ids as an absent tracer: telemetry that
/// breaks the work it measures is worse than telemetry that is missing.
fn Otel::start(
  self : Otel,
  name : String,
  parent : @trace.TraceContext?,
  attributes : Array[(String, @trace.Value)],
) -> @trace.Span? {
  let at = (self.now)()
  let started = Ok(
    match parent {
      Some(parent) =>
        self.tracer.start(
          name,
          parent~,
          kind=@trace.SpanKind::Internal,
          at~,
          attributes~,
        )
      None =>
        self.tracer.start(
          name,
          kind=@trace.SpanKind::Internal,
          at~,
          attributes~,
        )
    },
  ) catch {
    _ => Err(())
  }
  match started {
    Ok(span) => Some(span)
    Err(_) => None
  }
}
