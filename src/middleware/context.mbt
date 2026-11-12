///|
/// Fold a conversation that has grown past a limit into a summary before sending it.
///
/// The budget is counted in messages rather than tokens: a message count is exact on every
/// provider, needs no tokenizer, and is what a caller can reason about. The newest messages are
/// kept word for word, because that is what the next step depends on.
pub struct Summarization {
  max_messages : Int32
  keep : Int32
}

///|
/// Summarise once a conversation holds more than `max_messages` messages, keeping the last
/// `keep` of them.
pub fn Summarization::new(
  max_messages~ : Int32 = 40,
  keep~ : Int32 = 8,
) -> Summarization {
  { max_messages, keep, }
}

///|
pub extend Summarization with @agent.Middleware::{
  name,
  install,
  before_agent,
  wrap_model,
  wrap_tool,
  after_agent,
}

///|
pub impl @agent.Middleware for Summarization with fn name(_self) {
  "summarization"
}

///|
pub impl @agent.Middleware for Summarization with fn install(_self, _tools) {
  ()
}

///|
pub impl @agent.Middleware for Summarization with fn before_agent(
  _self,
  _context,
) {
  []
}

///|
pub impl @agent.Middleware for Summarization with fn wrap_model(
  self,
  context,
  call,
  next,
) {
  if call.request.messages.length() <= self.max_messages {
    return next(call)
  }
  let policy = @agent.HistoryPolicy::FromLast(self.keep)
  match
    @agent.compress(context.runtime, context, call.request.messages, policy) {
    @agent.Compressed::Done(messages) =>
      next({ request: call.request.with_messages(messages), })
    @agent.Compressed::Refused(_) => next(call)
  }
}

///|
pub impl @agent.Middleware for Summarization with fn wrap_tool(
  _self,
  _context,
  call,
  next,
) {
  next(call)
}

///|
pub impl @agent.Middleware for Summarization with fn after_agent(
  _self,
  _context,
  _state,
) {
  []
}

///|
/// How a conversation is trimmed when it is too long.
pub(all) enum EditingStrategy {
  /// Replace the content of every tool result but the newest `keep` with a placeholder. The
  /// call that produced it stays, so the model still knows the tool ran.
  ClearToolResults(keep~ : Int32)
  /// Drop the oldest messages, keeping the system message and the newest `keep`.
  KeepLast(keep~ : Int32)
}

///|
/// Trim a conversation without asking the model to summarise it.
///
/// Cheap and lossless in structure: nothing is invented, so nothing can be wrong. It is the right
/// policy when the older turns are scaffolding — tool results the model has already used — rather
/// than decisions worth keeping.
pub struct ContextEditing {
  strategy : EditingStrategy
}

///|
/// Trim per `strategy`.
pub fn ContextEditing::new(strategy : EditingStrategy) -> ContextEditing {
  { strategy, }
}

///|
pub extend ContextEditing with @agent.Middleware::{
  name,
  install,
  before_agent,
  wrap_model,
  wrap_tool,
  after_agent,
}

///|
pub impl @agent.Middleware for ContextEditing with fn name(_self) {
  "context_editing"
}

///|
pub impl @agent.Middleware for ContextEditing with fn install(_self, _tools) {
  ()
}

///|
pub impl @agent.Middleware for ContextEditing with fn before_agent(
  _self,
  _context,
) {
  []
}

///|
pub impl @agent.Middleware for ContextEditing with fn wrap_model(
  self,
  _context,
  call,
  next,
) {
  let messages = match self.strategy {
    ClearToolResults(keep~) => clear_results(call.request.messages, keep)
    KeepLast(keep~) => keep_last(call.request.messages, keep)
  }
  next({ request: call.request.with_messages(messages), })
}

///|
pub impl @agent.Middleware for ContextEditing with fn wrap_tool(
  _self,
  _context,
  call,
  next,
) {
  next(call)
}

///|
pub impl @agent.Middleware for ContextEditing with fn after_agent(
  _self,
  _context,
  _state,
) {
  []
}

///|
/// What stands in for a cleared tool result.
pub let cleared : String = "[the result of this call was cleared to save context]"

///|
/// Replace every tool result but the newest `keep` with [`cleared`].
fn clear_results(
  messages : Array[@moonmuse.Message],
  keep : Int32,
) -> Array[@moonmuse.Message] {
  let total = messages.length()
  let mut seen = 0
  let out : Array[@moonmuse.Message] = []
  let mut index = total - 1
  let cleared_positions : Array[Int32] = []
  while index >= 0 {
    let message = messages[index]
    if message.role is @moonmuse.Tool {
      seen = seen + 1
      if seen > keep {
        cleared_positions.push(index)
      }
    }
    index = index - 1
  }
  for position, message in messages {
    if cleared_positions.contains(position) {
      let parts : Array[@moonmuse.Part] = []
      for part in message.parts {
        match part {
          @moonmuse.Part::Result(id~, error~, ..) =>
            parts.push(@moonmuse.Part::Result(id~, content=cleared, error~))
          other => parts.push(other)
        }
      }
      out.push({ role: message.role, parts, })
    } else {
      out.push(message)
    }
  }
  out
}

///|
/// Keep the system message and the newest `keep` messages.
fn keep_last(
  messages : Array[@moonmuse.Message],
  keep : Int32,
) -> Array[@moonmuse.Message] {
  let total = messages.length()
  let start = if keep < total { total - keep } else { 0 }
  let out : Array[@moonmuse.Message] = []
  let mut index = 0
  while index < total {
    if index >= start || (index == 0 && messages[0].role is @moonmuse.System) {
      out.push(messages[index])
    }
    index = index + 1
  }
  out
}

///|
/// What to do with a value a policy recognises as personal data.
pub(all) enum PiiAction {
  /// Replace it with a label that says what it was: `[email]`.
  Redact
  /// Keep the last four characters, mask the rest.
  Mask
}

///|
/// One recogniser: a regular expression and the label that stands in for what it matches.
pub(all) struct PiiRule {
  pattern : String
  label : String
}

///|
/// A rule matching `pattern`, replaced with `label`.
pub fn PiiRule::new(pattern : String, label : String) -> PiiRule {
  { pattern, label, }
}

///|
/// Scrub personal data out of what the model is about to read.
///
/// The rules run over the request as it is being sent, so the conversation the run keeps is
/// untouched: a later step still has the real value if the host put it there, while the provider
/// never sees it. Rules are regular expressions, which is what makes them auditable — the policy
/// is data a reviewer can read.
pub struct Pii {
  rules : Array[PiiRule]
  action : PiiAction
}

///|
/// The recognisers a policy is usually made of: email addresses, phone numbers, card numbers and
/// national identifiers.
pub fn PiiRule::standard() -> Array[PiiRule] {
  [
    PiiRule::new("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "email"),
    PiiRule::new("\\b\\d{3}-\\d{3}-\\d{4}\\b", "phone"),
    PiiRule::new("\\b(?:\\d[ -]?){13,16}\\b", "card"),
    PiiRule::new("\\b\\d{3}-\\d{2}-\\d{4}\\b", "national-id"),
  ]
}

///|
/// Scrub with `rules`, redacting by default.
pub fn Pii::new(rules : Array[PiiRule], action~ : PiiAction = Redact) -> Pii {
  { rules, action, }
}

///|
/// Scrub with the standard recognisers.
pub fn Pii::standard() -> Pii {
  Pii::new(PiiRule::standard())
}

///|
pub extend Pii with @agent.Middleware::{
  name,
  install,
  before_agent,
  wrap_model,
  wrap_tool,
  after_agent,
}

///|
pub impl @agent.Middleware for Pii with fn name(_self) {
  "pii"
}

///|
pub impl @agent.Middleware for Pii with fn install(_self, _tools) {
  ()
}

///|
pub impl @agent.Middleware for Pii with fn before_agent(_self, _context) {
  []
}

///|
pub impl @agent.Middleware for Pii with fn wrap_model(
  self,
  _context,
  call,
  next,
) {
  let scrubbed = rewrite_request(call.request, messages => {
    let out : Array[@moonmuse.Message] = []
    for message in messages {
      out.push(rewrite_message(message, text => self.scrub(text)))
    }
    out
  })
  next({ request: scrubbed, })
}

///|
pub impl @agent.Middleware for Pii with fn wrap_tool(
  _self,
  _context,
  call,
  next,
) {
  next(call)
}

///|
pub impl @agent.Middleware for Pii with fn after_agent(_self, _context, _state) {
  []
}

///|
/// Apply every rule to one string.
fn Pii::scrub(self : Pii, text : String) -> String {
  let mut current = text
  for rule in self.rules {
    let replacement = match self.action {
      Redact => "[" + rule.label + "]"
      Mask => "***"
    }
    current = @moonregex.sub(rule.pattern, replacement, current) catch {
      _ => current
    }
  }
  current
}
