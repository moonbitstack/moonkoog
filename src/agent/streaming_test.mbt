// The streaming client contract: the default `execute_streaming` runs the non-streaming
// reply and emits it as a single chunk, so every client supports the streaming API even
// without native SSE. Providers that stream (OpenAI-compatible) override it to emit deltas.

///|
async test "llm client streaming: the default emits the reply as one chunk and returns it" {
  @async.with_task_group(_g => {
    let mock = @agent.MockClient::new([
      @moonmuse.Message::assistant("hello world"),
    ])
    let prompt = @moonmuse.PromptBuilder::new().user("hi").build()
    let chunks : Array[String] = []
    let got = @agent.LLMClient::execute_streaming(
      mock,
      prompt~,
      model=@models.deepseek_v4_flash,
      tools=[],
      on_chunk=c => chunks.push(c),
    )
    assert_eq(chunks.length(), 1)
    assert_eq(chunks[0], "hello world")
    assert_eq(got.text_content(), "hello world")
  })
}
