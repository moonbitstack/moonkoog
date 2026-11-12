///|
/// The tool a skill-enabled agent uses to read a skill's body.
pub let load_tool : String = "load_skill"

///|
/// The listing an agent carries: one line per skill, name then description, which is what the
/// model needs to decide whether a skill is worth loading.
pub fn catalog(skills : Array[@moonskill.Skill]) -> String {
  guard skills.length() > 0 else { return "No skills are installed." }
  let out = StringBuilder()
  out.write_string(
    "Skills available. Call " +
    load_tool +
    " with a skill's name to read it before using it.\n",
  )
  for skill in skills {
    out.write_string("- " + skill.name + ": " + skill.description + "\n")
  }
  out.to_string()
}

///|
/// The skill of that name, if one is installed.
fn find(skills : Array[@moonskill.Skill], name : String) -> @moonskill.Skill? {
  for skill in skills {
    if skill.name == name {
      return Some(skill)
    }
  }
  None
}

///|
/// The tool that reads one skill's body.
///
/// Progressive loading is the whole point: the listing costs a line per skill, the body costs
/// what it costs, and only the skills the run actually reaches are paid for.
pub fn load_tool_spec(skills : Array[@moonskill.Skill]) -> @agent.ToolSpec {
  let names : Array[Json] = []
  for skill in skills {
    names.push(Json::string(skill.name))
  }
  @agent.ToolSpec::new(
    name=load_tool,
    description="Read an installed skill by name. The instructions it returns apply to the task at hand.",
    schema=Json::object(
      Map([
        ("type", Json::string("object")),
        (
          "properties",
          Json::object(
            Map([
              (
                "name",
                Json::object(
                  Map([
                    ("type", Json::string("string")),
                    ("enum", Json::array(names)),
                  ]),
                ),
              ),
            ]),
          ),
        ),
        ("required", Json::array([Json::string("name")])),
      ]),
    ),
    run=fn(args, _context) {
      let name = match args {
        Object(fields) =>
          match fields.get("name") {
            Some(String(name)) => name
            _ => ""
          }
        _ => ""
      }
      guard name != "" else { return "error: no skill was named" }
      match find(skills, name) {
        Some(skill) => skill.body
        None => "error: there is no skill named " + name
      }
    },
  )
}

///|
/// Turn the config into a skill-enabled agent: the listing goes in the instructions, the loading
/// tool goes in the toolbox.
pub fn enable(
  config : @agent.AgentConfig,
  skills : Array[@moonskill.Skill],
) -> @agent.AgentConfig {
  guard skills.length() > 0 else { return config }
  let instructions = match config.instructions {
    Some(instructions) => instructions + "\n\n" + catalog(skills)
    None => catalog(skills)
  }
  config.with_instructions(instructions).with_tools([load_tool_spec(skills)])
}
