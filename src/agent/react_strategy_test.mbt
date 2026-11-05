// Koog's reActStrategy over custom nodes: a reasoning step (tools-off request) precedes the
// action step (request with tools); a plain-text action finishes. The scripted client hands
// back a reasoning reply then the answer, so the answer only surfaces if the reasoning step
// consumed its own LLM call.

///|
async test "react strategy: reasons then acts, finishing on a plain-text answer" {
  @async.with_task_group(_g => {
    let reasoning = @moonmuse.Message::assistant("let me reason about this")
    let answer = @moonmuse.Message::assistant("the answer is 42")
    let mock = @agent.MockClient::new([reasoning, answer])
    let agent = @agent.AIAgent::new(mock, model=@models.deepseek_v4_flash)
    let out = agent.run_strategy(@agent.react_strategy(), "solve x") catch {
      e => fail(e.to_string())
    }
    assert_eq(out, "the answer is 42")
  })
}
