///|
/// A minimal model whose provider is `p`.
fn model_for(p : @models.LLMProvider) -> @models.LLModel {
  {
    provider: p,
    id: "test-model",
    capabilities: [],
    context_length: None,
    max_output_tokens: None,
  }
}

///|
/// A one-message prompt.
fn one_prompt() -> @moonmuse.Prompt {
  @moonmuse.PromptBuilder::new().user("hi").build()
}

///|
async test "MultiLLMClient routes each request to its provider's client" {
  @async.with_task_group(_g => {
    let from_openai = @agent.MockClient::new([
      @moonmuse.Message::assistant("from openai"),
    ])
    let from_anthropic = @agent.MockClient::new([
      @moonmuse.Message::assistant("from anthropic"),
    ])
    let multi = @agent.MultiLLMClient::new()
      .register(@models.openai, from_openai)
      .register(@models.anthropic, from_anthropic)
    let r1 = multi.execute(prompt=one_prompt(), model=model_for(@models.openai), tools=[])
    assert_eq(r1.text_content(), "from openai")
    let r2 = multi.execute(
      prompt=one_prompt(),
      model=model_for(@models.anthropic),
      tools=[],
    )
    assert_eq(r2.text_content(), "from anthropic")
  })
}

///|
async test "MultiLLMClient uses the fallback for an unregistered provider" {
  @async.with_task_group(_g => {
    let fallback = @agent.MockClient::new([
      @moonmuse.Message::assistant("from fallback"),
    ])
    let multi = @agent.MultiLLMClient::new().with_fallback(fallback)
    let r = multi.execute(prompt=one_prompt(), model=model_for(@models.google), tools=[])
    assert_eq(r.text_content(), "from fallback")
  })
}

///|
async test "MultiLLMClient reports a missing provider with no fallback" {
  @async.with_task_group(_g => {
    let multi = @agent.MultiLLMClient::new()
    let r = multi.execute(prompt=one_prompt(), model=model_for(@models.deepseek), tools=[])
    assert_eq(r.text_content().contains("no LLM client registered"), true)
    assert_eq(r.text_content().contains("deepseek"), true)
  })
}

///|
async test "an agent drives a MultiLLMClient end to end" {
  @async.with_task_group(_g => {
    let from_openai = @agent.MockClient::new([
      @moonmuse.Message::assistant("routed answer"),
    ])
    let multi = @agent.MultiLLMClient::new().register(@models.openai, from_openai)
    let agent = @agent.AIAgent::new(multi, model=model_for(@models.openai))
    let out = agent.run("hi") catch { e => fail(e.to_string()) }
    assert_eq(out, "routed answer")
  })
}
