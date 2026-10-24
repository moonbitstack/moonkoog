///|
fn or0(x : Int32?) -> Int32 {
  match x {
    Some(n) => n
    None => 0
  }
}

///|
/// The model catalog: the `LLMProvider` list, the `LLModel` entries with their
/// context windows, and the `LLMCapability` set each model advertises. `supports`
/// answers the capability question a client asks before it sends a request — can
/// this model take tools, force a tool choice, see images, or think out loud.
///
///     moon run examples/03-model-catalog --target native
#coverage.skip
fn main {
  let providers = [
    @llm.openai, @llm.anthropic, @llm.google, @llm.deepseek, @llm.mistralai, @llm.ollama,
    @llm.openrouter,
  ]
  let names = providers.map(p => p.display)
  println("providers: " + names.join(", "))
  let sonnet = @llm.claude_sonnet_4_5
  println(
    "\{sonnet.provider.id}:\{sonnet.id} ctx=\{or0(sonnet.context_length)} max_out=\{or0(sonnet.max_output_tokens)}",
  )
  println(
    "  tools=\{sonnet.supports(@llm.Tools)} tool_choice=\{sonnet.supports(@llm.ToolChoice)} vision=\{sonnet.supports(@llm.Vision)} thinking=\{sonnet.supports(@llm.Thinking)}",
  )
  let flash = @llm.deepseek_v4_flash
  println(
    "\{flash.provider.id}:\{flash.id} tools=\{flash.supports(@llm.Tools)} caching=\{flash.supports(@llm.PromptCaching)}",
  )

  // The per-provider catalogs the client picks a model from.
  let catalogs : Array[(String, Array[@llm.LLModel])] = [
    ("openai", @llm.openai_models()),
    ("deepseek", @llm.deepseek_models()),
    ("google", @llm.google_models()),
    ("mistral", @llm.mistral_models()),
  ]
  for entry in catalogs {
    let (label, models) = entry
    let embedders = models.filter(m => m.supports(@llm.Embed)).length()
    println(
      "\{label}: \{models.length()} models, \{embedders} of them embedders",
    )
  }

  // Capability queries route a request to the right endpoint kind.
  println(
    "text-embedding-3-small embeds: \{@llm.text_embedding_3_small.supports(@llm.Embed)}",
  )
  println(
    "omni-moderation moderates: \{@llm.omni_moderation.supports(@llm.Moderation)}",
  )
}
