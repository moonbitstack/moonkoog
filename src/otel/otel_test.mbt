///|
/// A tracer whose ids are all the same byte: a trace in a test only has to be well formed, not
/// unique.
fn test_tracer(sink : &@trace.Sink) -> @trace.Tracer {
  @trace.Tracer::new(
    rand=n => Bytes::make(n, b'\x07'),
    sink~,
    sampler=@trace.always,
  )
}

///|
/// A clock that advances a microsecond per reading, so spans have a duration.
fn test_clock() -> () -> Int64 {
  let ticks = Ref(0)
  fn() {
    ticks.val = ticks.val + 1000
    ticks.val.to_int64()
  }
}

///|
/// A tool that echoes.
fn echo() -> @agent.ToolSpec {
  @agent.ToolSpec::new(name="echo", description="Echo.", run=fn(
    _args,
    _context,
  ) {
    "hi"
  })
}

///|
async test "otel: a run becomes an invoke_agent span with a tool span under it" {
  let sink = @trace.Recorder::new()
  let otel = @otel.Otel::new(tracer=test_tracer(sink), now=test_clock())
  let provider = @fake.Fake::new([
    @moonmuse.Reply::new(
      @moonmuse.Message::new(@moonmuse.Assistant, [
        @moonmuse.Part::call("call_1", "echo", Json::object(Map([]))),
      ]),
      finish=@moonmuse.Finish::Calls,
    ),
    @moonmuse.Reply::new(
      @moonmuse.Message::assistant("done"),
      usage=@moonmuse.Usage::new(11, 5),
    ),
  ])
  let events = otel.install(@agent.EventHandler::new())
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model")
    .with_events(events)
    .with_tools([echo()]),
  )
  assert_eq(agent.run("say hi"), "done")
  let spans = sink.spans()
  assert_eq(spans.length(), 2)
  assert_eq(spans[0].name, "execute_tool echo")
  assert_eq(spans[1].name, "invoke_agent agent")
  let mut tokens = 0
  for attribute in spans[1].attributes {
    if attribute.0 == @semconv.gen_ai_usage_output_tokens {
      tokens = match attribute.1 {
        @trace.Value::Int(value) => value.to_int()
        _ => 0
      }
    }
  }
  assert_eq(tokens, 5)
}

///|
async test "otel: a failed tool call marks its span as an error" {
  let sink = @trace.Recorder::new()
  let otel = @otel.Otel::new(tracer=test_tracer(sink), now=test_clock())
  let provider = @fake.Fake::new([
    @moonmuse.Reply::new(
      @moonmuse.Message::new(@moonmuse.Assistant, [
        @moonmuse.Part::call("call_1", "missing", Json::object(Map([]))),
      ]),
      finish=@moonmuse.Finish::Calls,
    ),
    @moonmuse.Reply::new(@moonmuse.Message::assistant("sorry")),
  ])
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model").with_events(
      otel.install(@agent.EventHandler::new()),
    ),
  )
  let _ = agent.run("go")
  let spans = sink.spans()
  assert_eq(spans.length(), 2)
  assert_eq(spans[0].name, "execute_tool missing")
  assert_eq(spans[0].status is @trace.Status::Error(_), true)
}
