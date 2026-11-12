// Two agents, one conversation: the researcher hands it to the writer with a tool, and the team's
// router follows the handover.

///|
async fn main {
  let researcher_provider = @fake.Fake::new([
    @moonmuse.Reply::new(
      @moonmuse.Message::new(@moonmuse.Assistant, [
        @moonmuse.Part::call(
          "call_1",
          "handoff",
          Json::object(Map([("to", Json::string("writer"))])),
        ),
      ]),
      finish=@moonmuse.Finish::Calls,
    ),
  ])
  let writer_provider = @fake.Fake::new([
    @moonmuse.Reply::new(@moonmuse.Message::assistant("The writer wrote this.")),
  ])
  let researcher = @moonkoog.create_agent(
    researcher_provider,
    @moonkoog.AgentConfig::new("scripted", name="researcher").with_tools([
      @moonkoog.handoff_tool(["writer"]),
    ]),
  )
  let writer = @moonkoog.create_agent(
    writer_provider,
    @moonkoog.AgentConfig::new("scripted", name="writer"),
  )
  let team = @moonkoog.create_agent(
    researcher_provider,
    @moonkoog.swarm(@moonkoog.AgentConfig::new("scripted", name="team"), [
      researcher, writer,
    ]),
  )
  println("team answer: " + team.run("write a line about graphs"))
  println("writer calls: " + writer_provider.hits().to_string())
}
