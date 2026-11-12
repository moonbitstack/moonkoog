// The smallest useful agent: a provider, a model, and one question. The provider is scripted, so
// the example runs without a key and prints the same three lines every time.

///|
async fn main {
  let provider = @fake.Fake::new([
    @moonmuse.Reply::new(
      @moonmuse.Message::assistant("A state graph is a program made of nodes."),
    ),
  ])
  let agent = @moonkoog.create_agent(
    provider,
    @moonkoog.AgentConfig::new("scripted").with_instructions(
      "Answer in one sentence.",
    ),
  )
  let answer = agent.run("What is a state graph?")
  println("answer: " + answer)
  println("model calls: " + provider.hits().to_string())
  println("messages: " + provider.seen()[0].messages.length().to_string())
}
