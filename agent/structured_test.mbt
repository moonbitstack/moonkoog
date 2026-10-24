///|
/// A value the model is asked to produce as structured JSON.
struct Person {
  name : String
  age : Int32
} derive(Eq, Debug)

///|
/// The explicit deserializer (Koog gets this from the Kotlin type; here it is
/// stated): read `name` and `age` off the model's JSON object, or `None`.
fn parse_person(j : Json) -> Person? {
  guard j is Object(m) else { return None }
  guard m.get("name") is Some(String(name)) else { return None }
  guard m.get("age") is Some(Number(age, ..)) else { return None }
  Some({ name, age: age.to_int(), })
}

///|
/// The `Person` schema: a JSON object with a string `name` and integer `age`.
fn person_schema() -> @agent.StructuredSchema[Person] {
  {
    name: "Person",
    description: "a person with a name and age",
    schema: @tools.TObject(
      properties=[
        { name: "name", description: "full name", ptype: @tools.TString, },
        { name: "age", description: "age in years", ptype: @tools.TInteger, },
      ],
      required=["name", "age"],
    ),
    parse: parse_person,
  }
}

///|
async test "request_structured parses a valid JSON reply" {
  @async.with_task_group(_g => {
    let mock = @agent.MockClient::new([
      @prompt.Message::assistant("{\"name\":\"Ann\",\"age\":30}"),
    ])
    let agent = @agent.AIAgent::new(mock, model=@llm.deepseek_v4_flash)
    let out = agent.request_structured("who?", person_schema()) catch {
      e => fail(e.to_string())
    }
    assert_eq(out.value, { name: "Ann", age: 30, })
  })
}

///|
async test "request_structured retries with a fixing prompt on malformed output" {
  @async.with_task_group(_g => {
    let mock = @agent.MockClient::new([
      @prompt.Message::assistant("sorry, I cannot do that"),
      @prompt.Message::assistant("{\"name\":\"Bob\",\"age\":25}"),
    ])
    let agent = @agent.AIAgent::new(mock, model=@llm.deepseek_v4_flash)
    let out = agent.request_structured("who?", person_schema()) catch {
      e => fail(e.to_string())
    }
    assert_eq(out.value, { name: "Bob", age: 25, })
  })
}

///|
async test "request_structured extracts JSON from prose and code fences" {
  @async.with_task_group(_g => {
    let mock = @agent.MockClient::new([
      @prompt.Message::assistant(
        "Sure! Here you go:\n```json\n{\"name\":\"Cid\",\"age\":40}\n```",
      ),
    ])
    let agent = @agent.AIAgent::new(mock, model=@llm.deepseek_v4_flash)
    let out = agent.request_structured("who?", person_schema()) catch {
      e => fail(e.to_string())
    }
    assert_eq(out.value, { name: "Cid", age: 40, })
  })
}

///|
async test "request_structured raises after exhausting the fix attempts" {
  @async.with_task_group(_g => {
    let mock = @agent.MockClient::new([
      @prompt.Message::assistant("nope"),
      @prompt.Message::assistant("still nope"),
      @prompt.Message::assistant("really nope"),
    ])
    let agent = @agent.AIAgent::new(mock, model=@llm.deepseek_v4_flash)
    let msg = try {
      agent.request_structured("who?", person_schema(), max_fixes=2) |> ignore
      "NO RAISE"
    } catch {
      @agent.AgentError(m) => m
      _ => "unexpected error kind"
    }
    assert_eq(msg.contains("no valid structured response"), true)
  })
}
