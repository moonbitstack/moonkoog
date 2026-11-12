// A tool the model may call, and the loop that runs it: the model asks for a calculation, the
// agent runs the tool, the result goes back, and the model answers with it in hand.

///|
async fn main {
  let provider = @fake.Fake::new([
    @moonmuse.Reply::new(
      @moonmuse.Message::new(@moonmuse.Assistant, [
        @moonmuse.Part::call(
          "call_1",
          "calculator",
          Json::object(
            Map([
              ("op", Json::string("multiply")),
              ("a", Json::number(6.0)),
              ("b", Json::number(7.0)),
            ]),
          ),
        ),
      ]),
      finish=@moonmuse.Finish::Calls,
    ),
    @moonmuse.Reply::new(@moonmuse.Message::assistant("The answer is 42.")),
  ])
  let agent = @moonkoog.create_agent(
    provider,
    @moonkoog.AgentConfig::new("scripted").with_tools([@moonkoog.calculator()]),
  )
  println("answer: " + agent.run("What is 6 times 7?"))
  let last = provider.seen()[provider.seen().length() - 1]
  for message in last.messages {
    for part in message.results() {
      match part {
        @moonmuse.Part::Result(content~, ..) => println("tool said: " + content)
        _ => ()
      }
    }
  }
}
