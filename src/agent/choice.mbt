///|
/// Picks one reply out of several candidates for the same request.
///
/// Asking more than once and choosing is how a run buys diversity without asking the provider
/// for `n` completions it may not support: every candidate is a normal call, so middleware,
/// limits and retries apply to each of them.
pub(open) trait Chooser {
  async fn choose(Self, Array[@moonmuse.Reply]) -> @moonmuse.Reply
}

///|
/// Take the first candidate.
pub struct FirstChoice {}

///|
/// The first-candidate chooser.
pub fn FirstChoice::new() -> FirstChoice {
  FirstChoice::{ }
}

///|
pub extend FirstChoice with Chooser::{choose}

///|
pub impl Chooser for FirstChoice with fn choose(_self, candidates) {
  match candidates {
    [first, ..] => first
    [] =>
      @moonmuse.Reply::new(
        @moonmuse.Message::assistant(""),
        finish=@moonmuse.Finish::Stop,
      )
  }
}

///|
/// Ask a model which candidate answers best, and keep that one.
pub struct ModelChoice {
  provider : &@moonmuse.Provider
  model : String
}

///|
/// A chooser that judges with `provider` / `model`.
pub fn ModelChoice::new(
  provider : &@moonmuse.Provider,
  model : String,
) -> ModelChoice {
  { provider, model, }
}

///|
pub extend ModelChoice with Chooser::{choose}

///|
pub impl Chooser for ModelChoice with fn choose(self, candidates) {
  guard candidates.length() > 0 else {
    return @moonmuse.Reply::new(
      @moonmuse.Message::assistant(""),
      finish=@moonmuse.Finish::Stop,
    )
  }
  let listing = StringBuilder()
  listing.write_string(
    "Several answers were produced for the same request. Reply with the number of the best one and nothing else.\n",
  )
  for index, candidate in candidates {
    listing.write_string(
      "[" + index.to_string() + "] " + candidate.text() + "\n",
    )
  }
  let request = @moonmuse.Request::new(self.model, [
    @moonmuse.Message::user(listing.to_string()),
  ])
  let reply = self.provider.chat(request) catch { _ => candidates[0] }
  let picked = candidate_index(reply.text(), candidates.length())
  candidates[picked]
}

///|
/// The candidate a judge named: the first integer in its text, kept in range, falling back to
/// the first candidate when there is no number at all.
fn candidate_index(text : String, count : Int32) -> Int32 {
  let mut value = 0
  let mut found = false
  for character in text {
    if character >= '0' && character <= '9' {
      value = value * 10 + (character.to_int() - '0'.to_int())
      found = true
    } else if found {
      break
    }
  }
  if !found {
    0
  } else if value >= count {
    count - 1
  } else {
    value
  }
}
