// History compression (Koog `HistoryCompressionStrategy` / `DefaultHistoryCompressionStrategies`):
// replace older conversation with an LLM-generated TLDR summary so a long run stays inside the
// model's context window. `WholeHistory` summarises everything into one message; `FromLastN`
// summarises all but the last N messages and keeps those verbatim.

///|
/// Which part of the history to compress (Koog's default strategies).
pub(all) enum HistoryCompression {
  WholeHistory
  FromLastN(Int)
} derive(Eq, Debug)

///|
/// Compresses a conversation with `client` / `model`.
pub struct HistoryCompressor {
  client : &LLMClient
  model : @llm.LLModel
}

///|
/// A compressor backed by `client` / `model`.
pub fn HistoryCompressor::new(
  client : &LLMClient,
  model : @llm.LLModel,
) -> HistoryCompressor {
  { client, model, }
}

///|
/// Compress `messages` per `strategy`, returning the new message list: the summary first, then
/// any kept messages. A list with nothing to summarise is returned unchanged.
pub async fn HistoryCompressor::compress(
  self : HistoryCompressor,
  messages : Array[@prompt.Message],
  strategy : HistoryCompression,
) -> Array[@prompt.Message] {
  let total = messages.length()
  let keep = match strategy {
    WholeHistory => 0
    FromLastN(n) => if n < total { n } else { total }
  }
  let cut = total - keep
  guard cut > 0 else { return messages }
  let to_summarize : Array[@prompt.Message] = []
  for i in 0..<cut {
    to_summarize.push(messages[i])
  }
  let out = [self.summarize(to_summarize)]
  for i in cut..<total {
    out.push(messages[i])
  }
  out
}

///|
/// Ask the model for a TLDR of `messages`, returned as an assistant message.
async fn HistoryCompressor::summarize(
  self : HistoryCompressor,
  messages : Array[@prompt.Message],
) -> @prompt.Message {
  let sb = StringBuilder()
  sb.write_string("Summarize this conversation into a brief TLDR:\n")
  for m in messages {
    sb.write_string(m.text_content())
    sb.write_string("\n")
  }
  let prompt = @prompt.PromptBuilder::new().user(sb.to_string()).build()
  let reply = LLMClient::execute(self.client, prompt~, model=self.model, tools=[])
  @prompt.Message::assistant("TLDR: " + reply.text_content())
}

///|
pub extend HistoryCompression with Debug::{to_repr}

///|
pub extend HistoryCompression with Eq::{not_equal, equal}
