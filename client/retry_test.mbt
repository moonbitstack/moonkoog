///|
/// A client that fails every call with a 503, to see what the `retrying` wrapper does with it.
struct AlwaysFailing {
  mut calls : Int
}

///|
impl @agent.LLMClient for AlwaysFailing with fn execute(
  self,
  prompt~,
  model~,
  tools~,
) {
  let _ = prompt
  let _ = model
  let _ = tools
  self.calls = self.calls + 1
  raise @moonllm.ApiError(code=503, message="unavailable")
}

///|
impl @agent.LLMClient for AlwaysFailing with fn provider(self) {
  let _ = self
  @llm.openai
}

///|
impl @agent.LLMClient for AlwaysFailing with fn moderate(self, prompt~, model~) {
  let _ = self
  let _ = prompt
  let _ = model
  @agent.ModerationResult::safe()
}

///|
impl @agent.LLMClient for AlwaysFailing with fn execute_multiple(
  self,
  prompt~,
  model~,
  tools~,
) {
  [@agent.LLMClient::execute(self, prompt~, model~, tools~)]
}

///|
async test "retrying() wires the describer, so a 503 is actually retried" {
  @async.with_task_group(_g => {
    let inner = AlwaysFailing::{ calls: 0, }
    let client = @client.retrying(inner, config={
      ..@agent.RetryConfig::default(),
      initial_delay_ms: 1,
      max_delay_ms: 2,
    })
    let prompt = @prompt.PromptBuilder::new().user("hi").build()
    (@agent.LLMClient::execute(client, prompt~, model=@llm.deepseek_v4_flash, tools=[])
    |> ignore) catch {
      _ => ()
    }
    // Three attempts, not one: the wrapper's describer let the pattern list see the 503.
    assert_eq(inner.calls, 3)
  })
}
