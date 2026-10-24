// The agent's `LLMParams` reaching the wire, and structured requests asking through the
// provider's own response format rather than only through a system message.

///|
/// A client that keeps every prompt it was handed, so a test can read what the agent sent.
struct RecordingClient {
  seen : Array[@prompt.Prompt]
  scripted : Array[@prompt.Message]
  mut next : Int32
}

///|
fn RecordingClient::new(scripted : Array[@prompt.Message]) -> RecordingClient {
  { seen: [], scripted, next: 0, }
}

///|
fn RecordingClient::last(self : RecordingClient) -> @prompt.Prompt {
  self.seen[self.seen.length() - 1]
}

///|
impl @agent.LLMClient for RecordingClient with fn execute(
  self,
  prompt~,
  model~,
  tools~,
) {
  let _ = model
  let _ = tools
  self.seen.push(prompt)
  let i = self.next
  self.next = self.next + 1
  self.scripted[i]
}

///|
impl @agent.LLMClient for RecordingClient with fn provider(self) {
  let _ = self
  @llm.openai
}

///|
impl @agent.LLMClient for RecordingClient with fn moderate(
  self,
  prompt~,
  model~,
) {
  let _ = self
  let _ = prompt
  let _ = model
  @agent.ModerationResult::safe()
}

///|
impl @agent.LLMClient for RecordingClient with fn execute_multiple(
  self,
  prompt~,
  model~,
  tools~,
) {
  [@agent.LLMClient::execute(self, prompt~, model~, tools~)]
}

///|
/// A model with no JSON-schema capability at all, to see the structured request fall back to
/// the prompt-only mechanism.
fn schemaless_model() -> @llm.LLModel {
  {
    provider: @llm.openai,
    id: "schemaless",
    capabilities: [Completion, Tools],
    context_length: None,
    max_output_tokens: None,
  }
}

///|
async test "agent params: a temperature set on the agent reaches the request" {
  @async.with_task_group(_g => {
    let client = RecordingClient::new([@prompt.Message::assistant("done")])
    let agent = @agent.AIAgent::new(client, model=@llm.deepseek_v4_flash, params={
      ..@prompt.LLMParams::default(),
      temperature: Some(0.233),
      max_tokens: Some(23333),
      tool_choice: Some(Required),
    })
    let out = agent.run("hi") catch { e => fail(e.to_string()) }
    assert_eq(out, "done")
    let sent = client.last()
    assert_eq(sent.params.temperature, Some(0.233))
    assert_eq(sent.params.max_tokens, Some(23333))
    assert_eq(sent.params.tool_choice, Some(Required))
  })
}

///|
async test "agent params: the default agent overrides nothing" {
  @async.with_task_group(_g => {
    let client = RecordingClient::new([@prompt.Message::assistant("done")])
    let agent = @agent.AIAgent::new(client, model=@llm.deepseek_v4_flash)
    let _ = agent.run("hi") catch { e => fail(e.to_string()) }
    assert_eq(client.last().params, @prompt.LLMParams::default())
  })
}

///|
async test "agent params: a strategy run carries them too" {
  @async.with_task_group(_g => {
    let client = RecordingClient::new([
      @prompt.Message::assistant("a"),
      @prompt.Message::assistant("b"),
    ])
    let agent = @agent.AIAgent::new(client, model=@llm.deepseek_v4_flash, params={
      ..@prompt.LLMParams::default(),
      temperature: Some(0.5),
    })
    let strategy = @agent.AIAgentStrategy::new("two")
      .node("first", @agent.NodeLLMRequest)
      .node("second", @agent.NodeLLMRequest)
      .edge(@agent.start_node, "first")
      .edge("first", "second")
      .edge("second", @agent.finish_node)
    let _ = agent.run_strategy(strategy, "hi") catch {
      e => fail(e.to_string())
    }
    assert_eq(client.seen.length(), 2)
    // Every request the walk makes, not only the first.
    for sent in client.seen {
      assert_eq(sent.params.temperature, Some(0.5))
    }
  })
}

///|
async test "structured request: sets the provider's response format, not only a system message" {
  @async.with_task_group(_g => {
    let client = RecordingClient::new([
      @prompt.Message::assistant("{\"name\":\"Ann\",\"age\":30}"),
    ])
    let agent = @agent.AIAgent::new(client, model=@llm.deepseek_v4_flash)
    let out = agent.request_structured("who?", person_schema()) catch {
      e => fail(e.to_string())
    }
    assert_eq(out.value, { name: "Ann", age: 30, })
    // The model declares the JSON-Schema-standard dialect, so that is what is asked for.
    let schema = client.last().params.schema
    guard schema is Some(JsonStandard(name~, schema=body)) else {
      fail("expected the request to carry a JsonStandard schema")
    }
    assert_eq(name, "Person")
    guard body is Object(fields) else { fail("schema body is not an object") }
    assert_eq(fields.get("type"), Some(Json::string("object")))
  })
}

///|
async test "structured request: a model without the capability falls back to the prompt" {
  @async.with_task_group(_g => {
    let client = RecordingClient::new([
      @prompt.Message::assistant("{\"name\":\"Bob\",\"age\":25}"),
    ])
    let agent = @agent.AIAgent::new(client, model=schemaless_model())
    let out = agent.request_structured("who?", person_schema()) catch {
      e => fail(e.to_string())
    }
    assert_eq(out.value, { name: "Bob", age: 25, })
    assert_eq(client.last().params.schema, None)
    // The instruction is still there — it is the whole mechanism for such a model.
    let texts = client.last().messages.map(m => m.text_content())
    assert_eq(texts.iter().any(t => t.contains("JSON schema".view())), true)
  })
}

///|
async test "structured node: the graph's structured request sets the format too" {
  @async.with_task_group(_g => {
    let client = RecordingClient::new([
      @prompt.Message::assistant("{\"name\":\"Cid\",\"age\":40}"),
    ])
    let agent = @agent.AIAgent::new(client, model=@llm.gpt_4o)
    let json_schema : @agent.StructuredSchema[Json] = {
      name: "Person",
      description: "a person with a name and age",
      schema: @tools.TObject(
        properties=[
          { name: "name", description: "full name", ptype: @tools.TString, },
          { name: "age", description: "age in years", ptype: @tools.TInteger, },
        ],
        required=["name", "age"],
      ),
      parse: j => Some(j),
    }
    let strategy = @agent.AIAgentStrategy::new("structured")
      .node("ask", @agent.NodeLLMRequestStructured(json_schema, fixes=1))
      .edge(@agent.start_node, "ask")
      .edge("ask", @agent.finish_node)
    let _ = agent.run_strategy(strategy, "who?") catch {
      e => fail(e.to_string())
    }
    guard client.last().params.schema is Some(JsonStandard(name~, ..)) else {
      fail("expected the node to set a JsonStandard schema")
    }
    assert_eq(name, "Person")
  })
}
