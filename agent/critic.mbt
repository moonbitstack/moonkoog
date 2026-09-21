// The LLM-as-a-judge critic (Koog `LLMAsAJudge` / `CriticResult`): ask a model whether a
// solution to a task is correct and, if not, what feedback to give. `judge` returns a
// `CriticVerdict` carrying the pass/fail and the feedback the model offered.

///|
/// A critic's verdict on a solution: whether it passed, and any feedback (Koog
/// `CriticResult`).
pub struct CriticVerdict {
  successful : Bool
  feedback : String
} derive(Eq, Debug)

///|
/// An LLM critic that judges solutions with `client` / `model`.
pub struct LLMCritic {
  client : &LLMClient
  model : @llm.LLModel
}

///|
/// A critic backed by `client` / `model`.
pub fn LLMCritic::new(client : &LLMClient, model : @llm.LLModel) -> LLMCritic {
  { client, model, }
}

///|
/// Ask the model whether `solution` correctly solves `task`. A reply beginning `CORRECT`
/// passes; otherwise it fails, and the text after the first colon is the feedback.
pub async fn LLMCritic::judge(
  self : LLMCritic,
  task : String,
  solution : String,
) -> CriticVerdict {
  let prompt = @prompt.PromptBuilder::new()
    .user(
      "Task: " +
      task +
      "\nSolution: " +
      solution +
      "\nIs the solution correct? Reply 'CORRECT' if it is, otherwise 'INCORRECT: <feedback>'.",
    )
    .build()
  let reply = LLMClient::execute(self.client, prompt~, model=self.model, tools=[]).text_content()
  if reply.has_prefix("CORRECT") {
    { successful: true, feedback: "", }
  } else {
    { successful: false, feedback: feedback_after_colon(reply), }
  }
}

///|
/// The feedback text of a critic reply: everything after the first colon, without the
/// leading space (empty when there is no colon).
fn feedback_after_colon(reply : String) -> String {
  let sb = StringBuilder()
  let mut seen_colon = false
  let mut skipped_space = false
  for c in reply {
    if seen_colon {
      if !skipped_space && c == ' ' {
        skipped_space = true
      } else {
        sb.write_string(c.to_string())
        skipped_space = true
      }
    } else if c == ':' {
      seen_colon = true
    }
  }
  sb.to_string()
}

///|
pub extend CriticVerdict with Debug::{to_repr}

///|
pub extend CriticVerdict with Eq::{not_equal, equal}
