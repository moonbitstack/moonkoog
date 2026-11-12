// Plan and execute: the model writes the steps, works through them with its tools, and the graph
// advances the plan instead of ending on the first paragraph.

///|
async fn main {
  let provider = @fake.Fake::new([
    @moonmuse.Reply::new(
      @moonmuse.Message::assistant("[\"look the number up\", \"report it\"]"),
    ),
    @moonmuse.Reply::new(
      @moonmuse.Message::assistant("six times seven is forty-two"),
    ),
    @moonmuse.Reply::new(@moonmuse.Message::assistant("Reported: forty-two.")),
  ])
  let agent = @moonkoog.create_agent(
    provider,
    @moonkoog.plan_and_execute(@moonkoog.AgentConfig::new("scripted")),
  )
  println("answer: " + agent.run("Work out six times seven and report it."))
  println("model calls: " + provider.hits().to_string())
}
