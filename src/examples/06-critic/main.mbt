///|
/// The LLM critic (Koog's verification step): a judge model reviews an answer to a
/// task and returns a `CriticVerdict` — `CORRECT` passes with no feedback; anything
/// else fails and the critic extracts the reason. The scripted judges below stand in
/// for the two outcomes.
///
///     moon run examples/15-critic --target native
#coverage.skip
async fn main {
  @async.with_task_group(_g => {
    let approve = @agent.LLMCritic::new(
      @agent.MockClient::new([@moonmuse.Message::assistant("CORRECT")]),
      @models.deepseek_v4_flash,
    )
    let good = approve.judge("what is 2+2?", "4")
    println(
      "answer '4': successful=\{good.successful} feedback='\{good.feedback}'",
    )
    let reject = @agent.LLMCritic::new(
      @agent.MockClient::new([
        @moonmuse.Message::assistant("INCORRECT: off by one"),
      ]),
      @models.deepseek_v4_flash,
    )
    let bad = reject.judge("what is 2+2?", "5")
    println(
      "answer '5': successful=\{bad.successful} feedback='\{bad.feedback}'",
    )
  })
}
