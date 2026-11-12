///|
/// Ask the agent to call the calculator and return what the tool told the model.
async fn run_calculator(op : String, a : Double, b : Double) -> String {
  let provider = @fake.Fake::new([
    @moonmuse.Reply::new(
      @moonmuse.Message::new(@moonmuse.Assistant, [
        @moonmuse.Part::call(
          "call_1",
          "calculator",
          Json::object(
            Map([
              ("op", Json::string(op)),
              ("a", Json::number(a)),
              ("b", Json::number(b)),
            ]),
          ),
        ),
      ]),
      finish=@moonmuse.Finish::Calls,
    ),
    @moonmuse.Reply::new(@moonmuse.Message::assistant("done")),
  ])
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model").with_tools(@tools.all()),
  )
  let _ = agent.run("compute")
  let seen = provider.seen()
  let last = seen[seen.length() - 1]
  let mut reported = ""
  for message in last.messages {
    for part in message.results() {
      match part {
        @moonmuse.Part::Result(content~, ..) => reported = content
        _ => ()
      }
    }
  }
  reported
}

///|
async test "calculator: the four operations" {
  assert_eq(run_calculator("add", 2.0, 40.0), "42")
  assert_eq(run_calculator("multiply", 6.0, 7.0), "42")
  assert_eq(run_calculator("subtract", 50.0, 8.0), "42")
  assert_eq(run_calculator("divide", 84.0, 2.0), "42")
}

///|
async test "calculator: division by zero is refused, not answered" {
  assert_eq(
    run_calculator("divide", 1.0, 0.0).contains("division by zero"),
    true,
  )
}

///|
async test "calculator: an unknown operation is reported" {
  assert_eq(
    run_calculator("power", 2.0, 2.0).contains("unknown operation"),
    true,
  )
}
