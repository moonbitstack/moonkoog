///|
/// A tool that refuses everything, so the failure hooks have something to report.
struct Flaky {}

///|
impl @tools.Tool for Flaky with fn descriptor(_self) {
  {
    name: "lookup",
    description: "look a term up",
    required_parameters: [
      { name: "term", description: "what to look up", ptype: @tools.TString, },
    ],
    optional_parameters: [],
  }
}

///|
impl @tools.Tool for Flaky with fn execute_raw(_self, _args) {
  raise Failure("the index is offline")
}

///|
/// A client that asks for `lookup` once, then answers from whatever came back, and reports the
/// tokens a real provider would have charged.
struct LoopClient {}

///|
impl @agent.LLMClient for LoopClient with fn execute(
  _self,
  prompt~,
  model~,
  tools~,
) {
  let _ = model
  let _ = tools
  let mut result : String? = None
  for msg in prompt.messages {
    for part in msg.parts {
      if part is @prompt.ToolResult(output~, ..) {
        result = Some(output)
      }
    }
  }
  let meta : @prompt.ResponseMetaInfo = {
    total_tokens: Some(72),
    input_tokens: Some(66),
    output_tokens: Some(6),
    model: Some("deepseek-v4-flash-0801"),
  }
  match result {
    Some(output) =>
      @prompt.Message::assistant("I could not: " + output).with_meta(meta)
    None =>
      @prompt.Message::{
        role: Assistant,
        parts: [
          @prompt.ToolCall(id=Some("c1"), tool="lookup", args={ "term": "qwq" }),
        ],
        finish_reason: None,
        meta: None,
      }.with_meta(meta)
  }
}

///|
impl @agent.LLMClient for LoopClient with fn provider(_self) {
  @llm.deepseek
}

///|
impl @agent.LLMClient for LoopClient with fn moderate(_self, prompt~, model~) {
  let _ = prompt
  let _ = model
  @agent.ModerationResult::safe()
}

///|
impl @agent.LLMClient for LoopClient with fn execute_multiple(
  self,
  prompt~,
  model~,
  tools~,
) {
  [@agent.LLMClient::execute(self, prompt~, model~, tools~)]
}

///|
/// Tracing and the intercepting hooks: `EventHandler::tracing` renders every hook of a run to a
/// `TraceWriter` — here a `LineTrace` printing lines — while an interceptor rewrites the prompt
/// on its way to the client and a failing tool reports through `on_tool_call_failed`. The token
/// counts the provider reported ride back on the reply as `ResponseMetaInfo`.
///
///     moon run examples/27-agent-tracing --target native
#coverage.skip
async fn main {
  @async.with_task_group(_g => {
    let spent : Array[Int32] = []
    let events = @agent.EventHandler::new()
      .tracing(@agent.LineTrace::new(line => println(line)))
      .intercept_llm_call_starting(p => {
        p.append(@prompt.Message::user("Answer in one sentence."))
      })
      .on_llm_call_completed(reply => {
        match reply.total_tokens() {
          Some(n) => spent.push(n)
          None => ()
        }
      })
    let agent = @agent.AIAgent::new(
      LoopClient::{ },
      model=@llm.deepseek_v4_flash,
      tool_registry=@tools.ToolRegistry::new().add(Flaky::{ }),
      events~,
    )
    let out = agent.run("look up qwq") catch { e => e.to_string() }
    println("result: " + out)
    println(
      "tokens: " +
      spent.fold(init=0, (a, b) => a + b).to_string() +
      " over " +
      spent.length().to_string() +
      " calls",
    )
  })
}
