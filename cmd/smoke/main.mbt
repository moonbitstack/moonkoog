///|
/// A tool the smoke gives the agent: add two integers from the JSON args.
struct Add {}

///|
impl @tools.Tool for Add with fn descriptor(_self) {
  {
    name: "add",
    description: "add two integers a and b",
    required_parameters: [
      { name: "a", description: "first addend", ptype: @tools.TInteger, },
      { name: "b", description: "second addend", ptype: @tools.TInteger, },
    ],
    optional_parameters: [],
  }
}

///|
impl @tools.Tool for Add with fn execute_raw(_self, args) {
  (json_int(args, "a") + json_int(args, "b")).to_string()
}

///|
fn json_int(j : Json, key : String) -> Int {
  match j {
    Object(m) =>
      match m.get(key) {
        Some(Number(n, ..)) => n.to_int()
        _ => 0
      }
    _ => 0
  }
}

///|
/// Point moonkoog's OpenAI-compatible client at a live endpoint and let an agent
/// answer with a tool. Configured entirely from the environment:
///   MOONKOOG_API_KEY    required — bearer token; without it this is a no-op
///   MOONKOOG_BASE_URL   default https://api.deepseek.com
///   MOONKOOG_MODEL      default deepseek-chat
async fn main {
  let key = @env.get_env_var("MOONKOOG_API_KEY").unwrap_or("")
  if key == "" {
    println(
      "moonkoog smoke: set MOONKOOG_API_KEY to run against a live endpoint",
    )
    return
  }
  let base = @env.get_env_var("MOONKOOG_BASE_URL").unwrap_or(
    "https://api.deepseek.com",
  )
  let model_id = @env.get_env_var("MOONKOOG_MODEL").unwrap_or("deepseek-chat")
  @async.with_task_group(_g => {
    let client = @client.OpenAiCompatibleClient::new(
      api_key=key,
      base_url=base,
      provider=@llm.deepseek,
    )
    let model : @llm.LLModel = {
      provider: @llm.deepseek,
      id: model_id,
      capabilities: [@llm.Completion, @llm.Tools, @llm.ToolChoice],
      context_length: None,
      max_output_tokens: None,
    }
    let registry = @tools.ToolRegistry::new().add(Add::{ })
    let agent = @agent.AIAgent::new(
      client,
      model~,
      tool_registry=registry,
      system_prompt="Use the add tool to compute sums. Answer concisely.",
    )
    let answer = agent.run("What is 21 + 21? Use the add tool.") catch {
      e => "error: " + e.to_string()
    }
    println("moonkoog smoke answer: " + answer)
  })
}
