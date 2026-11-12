// Middleware is a chain around the model call: a cap on how many calls a run may spend, a retry
// for the failures worth retrying, and a scrub of what leaves the process.

///|
async fn main {
  let provider = @fake.Fake::flaky(
    1,
    @moonmuse.Reply::new(
      @moonmuse.Message::assistant("answered on the second try"),
    ),
    code=503,
  )
  let agent = @moonkoog.create_agent(
    provider,
    @moonkoog.AgentConfig::new("scripted")
    .with_middleware(@middleware.ModelRetry::new(attempts=2, base_ms=1))
    .with_middleware(@middleware.ModelCallLimit::new(limit=3))
    .with_middleware(@middleware.Pii::standard()),
  )
  println("answer: " + agent.run("write to leo@example.com"))
  let sent = provider.seen()[provider.seen().length() - 1]
  println("calls made: " + provider.hits().to_string())
  println("first message: " + sent.messages[0].text_content())
}
