///|
/// A skill document, in the form a `SKILL.md` file has: frontmatter, then the body.
let skill_text : String = "---\nname: chart-maker\ndescription: Draw a chart from a table of numbers.\n---\n\nUse the chart tool with the numbers from the table.\n"

///|
/// The skill the tests enable.
fn chart_skill() -> @moonskill.Skill raise @moonskill.Refused {
  @moonskill.parse(skill_text)
}

///|
test "catalog: one line per skill, with the loading instruction" {
  let catalog = @skills.catalog([chart_skill()])
  assert_eq(catalog.contains("chart-maker: Draw a chart"), true)
  assert_eq(catalog.contains("load_skill"), true)
}

///|
test "catalog: an empty install says so" {
  assert_eq(@skills.catalog([]), "No skills are installed.")
}

///|
async test "skills: the listing is in the instructions and the body is one call away" {
  let provider = @fake.Fake::new([
    @moonmuse.Reply::new(
      @moonmuse.Message::new(@moonmuse.Assistant, [
        @moonmuse.Part::call(
          "call_1",
          @skills.load_tool,
          Json::object(Map([("name", Json::string("chart-maker"))])),
        ),
      ]),
      finish=@moonmuse.Finish::Calls,
    ),
    @moonmuse.Reply::new(@moonmuse.Message::assistant("drawn")),
  ])
  let config = @skills.enable(@agent.AgentConfig::new("test-model"), [
    chart_skill(),
  ])
  let agent = @agent.create_agent(provider, config)
  assert_eq(agent.run("chart this"), "drawn")
  let seen = provider.seen()
  let system = seen[0].messages[0].text_content()
  assert_eq(system.contains("chart-maker"), true)
  assert_eq(system.contains("Use the chart tool"), false)
  let last = seen[seen.length() - 1]
  let mut body = ""
  for message in last.messages {
    for part in message.results() {
      match part {
        @moonmuse.Part::Result(content~, ..) => body = content
        _ => ()
      }
    }
  }
  assert_eq(body.contains("Use the chart tool"), true)
}
