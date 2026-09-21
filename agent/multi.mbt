///|
/// One `LLMClient` over several providers (← Koog's `MultiLLMPromptExecutor`):
/// register a client per provider, and every request routes to the client whose
/// provider matches the request's `model.provider`. An optional fallback client
/// serves any provider that was not registered. Because MoonBit's `LLMClient.execute`
/// does not raise, a request for a provider with neither a client nor a fallback
/// gets a plain assistant message naming the miss, rather than a crash — an honest,
/// visible degradation of Koog's `IllegalArgumentException`.
pub struct MultiLLMClient {
  clients : Map[String, &LLMClient]
  mut fallback : &LLMClient?
  default_provider : @llm.LLMProvider
}

///|
/// An empty router. `default_provider` is what the router reports as its own
/// `provider()` (Koog executors are provider-agnostic; a value is still required).
pub fn MultiLLMClient::new(
  default_provider? : @llm.LLMProvider = @llm.openai,
) -> MultiLLMClient {
  { clients: Map([]), fallback: None, default_provider, }
}

///|
/// Register `client` for `provider`, returning the router so registrations chain.
pub fn MultiLLMClient::register(
  self : MultiLLMClient,
  provider : @llm.LLMProvider,
  client : &LLMClient,
) -> MultiLLMClient {
  self.clients[provider.id] = client
  self
}

///|
/// Set the fallback client used for any provider without its own registration.
pub fn MultiLLMClient::with_fallback(
  self : MultiLLMClient,
  client : &LLMClient,
) -> MultiLLMClient {
  self.fallback = Some(client)
  self
}

///|
pub impl LLMClient for MultiLLMClient with fn execute(
  self,
  prompt~,
  model~,
  tools~,
) {
  match self.clients.get(model.provider.id) {
    Some(client) => client.execute(prompt~, model~, tools~)
    None =>
      match self.fallback {
        Some(fb) => fb.execute(prompt~, model~, tools~)
        None =>
          @prompt.Message::assistant(
            "no LLM client registered for provider '" + model.provider.id + "'",
          )
      }
  }
}

///|
pub impl LLMClient for MultiLLMClient with fn provider(self) {
  self.default_provider
}

///|
pub impl LLMClient for MultiLLMClient with fn moderate(self, prompt~, model~) {
  match self.clients.get(model.provider.id) {
    Some(client) => client.moderate(prompt~, model~)
    None =>
      match self.fallback {
        Some(fb) => fb.moderate(prompt~, model~)
        None => ModerationResult::safe()
      }
  }
}

///|
pub impl LLMClient for MultiLLMClient with fn execute_multiple(
  self,
  prompt~,
  model~,
  tools~,
) {
  match self.clients.get(model.provider.id) {
    Some(client) => client.execute_multiple(prompt~, model~, tools~)
    None =>
      match self.fallback {
        Some(fb) => fb.execute_multiple(prompt~, model~, tools~)
        None =>
          [
            @prompt.Message::assistant(
              "no LLM client registered for provider '" +
              model.provider.id +
              "'",
            ),
          ]
      }
  }
}

///|
pub extend MultiLLMClient with LLMClient::{
  execute,
  provider,
  execute_streaming,
  moderate,
  execute_multiple,
}
