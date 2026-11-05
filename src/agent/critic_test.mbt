// The LLM critic: a CORRECT reply passes; an INCORRECT one fails and yields its feedback.

///|
async test "llm critic: passes CORRECT, fails INCORRECT and extracts the feedback" {
  @async.with_task_group(_g => {
    let pass = @agent.MockClient::new([@moonmuse.Message::assistant("CORRECT")])
    let v1 = @agent.LLMCritic::new(pass, @models.deepseek_v4_flash).judge(
      "2+2", "4",
    )
    assert_eq(v1.successful, true)
    assert_eq(v1.feedback, "")
    let fail = @agent.MockClient::new([
      @moonmuse.Message::assistant("INCORRECT: off by one"),
    ])
    let v2 = @agent.LLMCritic::new(fail, @models.deepseek_v4_flash).judge(
      "2+2", "5",
    )
    assert_eq(v2.successful, false)
    assert_eq(v2.feedback, "off by one")
  })
}
