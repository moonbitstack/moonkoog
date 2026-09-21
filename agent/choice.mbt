// Choice selection (Koog `ChoiceSelectionStrategy`): pick one reply among the several a
// multi-choice request (`execute_multiple`) returns. `FirstChoice` is Koog's deterministic
// `Default` (take the first); `LLMChoiceSelector` asks a model to judge which candidate is
// best and returns it (Koog's LLM-backed selector).

///|
/// A strategy for choosing one reply among several candidates for a prompt.
pub(open) trait ChoiceSelectionStrategy {
  async fn choose(
    Self,
    prompt : @prompt.Prompt,
    choices : Array[@prompt.Message],
  ) -> @prompt.Message
}

///|
/// Take the first candidate (Koog `ChoiceSelectionStrategy.Default`).
pub struct FirstChoice {}

///|
/// The first-choice selector.
pub fn FirstChoice::new() -> FirstChoice {
  FirstChoice::{ }
}

///|
pub impl ChoiceSelectionStrategy for FirstChoice with fn choose(
  _self,
  _prompt,
  choices,
) {
  if choices.length() > 0 {
    choices[0]
  } else {
    @prompt.Message::assistant("")
  }
}

///|
/// Ask a model to judge which candidate is best and return it (Koog's LLM-backed choice
/// selection).
pub struct LLMChoiceSelector {
  client : &LLMClient
  model : @llm.LLModel
}

///|
/// A selector that judges with `client` / `model`.
pub fn LLMChoiceSelector::new(
  client : &LLMClient,
  model : @llm.LLModel,
) -> LLMChoiceSelector {
  { client, model, }
}

///|
pub impl ChoiceSelectionStrategy for LLMChoiceSelector with fn choose(
  self,
  _prompt,
  choices,
) {
  guard choices.length() > 0 else { @prompt.Message::assistant("") }
  let sb = StringBuilder()
  sb.write_string(
    "Select the best of these candidate answers. Reply with only its number.\n",
  )
  for i, c in choices {
    sb.write_string("[" + i.to_string() + "] " + c.text_content() + "\n")
  }
  let judge = @prompt.PromptBuilder::new().user(sb.to_string()).build()
  let reply = LLMClient::execute(self.client, prompt=judge, model=self.model, tools=[])
  choices[choice_index(reply.text_content(), choices.length())]
}

///|
/// The candidate index a judge's reply names: the first integer in the text, clamped into
/// range (0 if none is found).
fn choice_index(text : String, count : Int) -> Int {
  let mut num = 0
  let mut found = false
  for c in text {
    if c >= '0' && c <= '9' {
      num = num * 10 + (c.to_int() - '0'.to_int())
      found = true
    } else if found {
      break
    }
  }
  if !found {
    0
  } else if num >= count {
    count - 1
  } else {
    num
  }
}

///|
pub extend FirstChoice with ChoiceSelectionStrategy::{choose}

///|
pub extend LLMChoiceSelector with ChoiceSelectionStrategy::{choose}
