// The model asks for both tools in one turn; the agent runs them from the generated `tools()` and
// hands the results back.

///|
async fn main {
  let provider = @fake.Fake::new([
    @moonmuse.Reply::new(
      @moonmuse.Message::new(@moonmuse.Assistant, [
        @moonmuse.Part::call(
          "call_1",
          "multiply",
          Json::object({ "a": Json::number(6.0), "b": Json::number(7.0) }),
        ),
        @moonmuse.Part::call(
          "call_2",
          "greet",
          Json::object({
            "name": Json::string("moon"),
            "loud": Json::boolean(true),
          }),
        ),
      ]),
      finish=@moonmuse.Finish::Calls,
    ),
    @moonmuse.Reply::new(@moonmuse.Message::assistant("done")),
  ])
  let agent = @moonkoog.create_agent(
    provider,
    @moonkoog.AgentConfig::new("scripted").with_tools(tools()),
  )
  println("answer: " + agent.run("Multiply 6 by 7 and greet the moon."))
  let said = []
  let last = provider.seen()[provider.seen().length() - 1]
  for message in last.messages {
    for part in message.results() {
      if part is @moonmuse.Part::Result(content~, ..) {
        said.push(content)
        println("tool said: " + content)
      }
    }
  }
  if said != ["42", "HELLO, MOON"] {
    abort("the generated tools did not answer as their functions do")
  }
}
