///|
/// The LLM client contract (Koog `LLMClientAPI`, collapsed for the MVP with the
/// single-LLM `PromptExecutor` — a single-provider executor is a one-line delegate
/// to its client). `execute` sends a prompt with the tool descriptors the model
/// may call and returns the assistant reply; any tool calls come back inside the
/// reply's `parts` as `ToolCall`s. `moderate` checks a prompt against the provider's safety
/// categories; its default reports nothing harmful, and a client that supports moderation
/// overrides it. `execute_multiple` returns one reply per requested choice (Koog
/// `executeMultipleChoices`, the count being `prompt.params.number_of_choices`); a provider
/// without multi-choice returns a single-element list. Streaming is deferred to the async-stream
/// layer.
/// Source: prompt/prompt-executor/prompt-executor-clients/.../LLMClientAPI.kt.
pub(open) trait LLMClient {
  async fn execute(
    Self,
    prompt~ : @prompt.Prompt,
    model~ : @llm.LLModel,
    tools~ : Array[@tools.ToolDescriptor],
  ) -> @prompt.Message
  fn provider(Self) -> @llm.LLMProvider
  async fn moderate(Self, prompt~ : @prompt.Prompt, model~ : @llm.LLModel) -> ModerationResult
  async fn execute_multiple(
    Self,
    prompt~ : @prompt.Prompt,
    model~ : @llm.LLModel,
    tools~ : Array[@tools.ToolDescriptor],
  ) -> Array[@prompt.Message]
  /// Stream the assistant reply, invoking `on_chunk` for each incremental text delta as it
  /// arrives, and returning the fully assembled reply (Koog `LLMClient.executeStreaming`). The
  /// default emits the whole reply as a single chunk — a faithful fallback for a client without
  /// native streaming; a provider that streams overrides it to emit real deltas.
  async fn execute_streaming(
    Self,
    prompt~ : @prompt.Prompt,
    model~ : @llm.LLModel,
    tools~ : Array[@tools.ToolDescriptor],
    on_chunk~ : (String) -> Unit,
  ) -> @prompt.Message = _
}

///|
/// The default streaming behaviour: run the non-streaming `execute` and emit its text as one
/// chunk. A client whose provider streams (OpenAI-compatible) overrides this.
impl LLMClient with fn execute_streaming(
  self,
  prompt~,
  model~,
  tools~,
  on_chunk~,
) {
  let reply = self.execute(prompt~, model~, tools~)
  let text = reply.text_content()
  if text != "" {
    on_chunk(text)
  }
  reply
}

///|
/// A deterministic in-memory client for tests: it replays a scripted list of
/// assistant replies, one per `execute` call, ignoring the prompt. This is what
/// lets the agent loop be tested without a network or a real model — the loop's
/// control flow is exercised by scripting "reply with a tool call", then "reply
/// with the final text".
pub struct MockClient {
  scripted : Array[@prompt.Message]
  mut next : Int
  provider_id : @llm.LLMProvider
}

///|
/// A mock that will hand back `scripted` replies in order.
pub fn MockClient::new(
  scripted : Array[@prompt.Message],
  provider? : @llm.LLMProvider = @llm.openai,
) -> MockClient {
  { scripted, next: 0, provider_id: provider, }
}

///|
pub impl LLMClient for MockClient with fn execute(self, prompt~, model~, tools~) {
  let _ = prompt
  let _ = model
  let _ = tools
  let i = self.next
  self.next = self.next + 1
  self.scripted[i]
}

///|
pub impl LLMClient for MockClient with fn provider(self) {
  self.provider_id
}

///|
pub impl LLMClient for MockClient with fn moderate(self, prompt~, model~) {
  let _ = self
  let _ = prompt
  let _ = model
  ModerationResult::safe()
}

///|
/// The scripted equivalent of a multi-choice request: hand back the next
/// `prompt.params.number_of_choices` scripted replies, one per candidate, the way a
/// provider returns one completion per requested choice.
pub impl LLMClient for MockClient with fn execute_multiple(
  self,
  prompt~,
  model~,
  tools~,
) {
  let wanted = match prompt.params.number_of_choices {
    Some(n) => if n > 1 { n } else { 1 }
    None => 1
  }
  let choices = []
  for _ in 0..<wanted {
    choices.push(LLMClient::execute(self, prompt~, model~, tools~))
  }
  choices
}

///|
pub extend MockClient with LLMClient::{
  execute,
  provider,
  execute_streaming,
  moderate,
  execute_multiple,
}
