///|
/// Serving an agent over HTTP (the moonbitstack integration seam): `AgentEndpoint`
/// wraps an `AIAgent` as a request handler. A well-formed body runs the agent and
/// returns its output as JSON; `handle_sse` frames the same output as a Server-Sent
/// Event; a malformed body is a 400. The scripted client keeps the response fixed.
///
///     moon run examples/18-agent-serving --target native
#coverage.skip
async fn main {
  @async.with_task_group(_g => {
    let endpoint = @agent.AgentEndpoint::new(
      @agent.AIAgent::new(
        @agent.MockClient::new([@prompt.Message::assistant("hello, world")]),
        model=@llm.deepseek_v4_flash,
      ),
    )
    let ok = endpoint.handle("{\"message\":\"hi\"}")
    println("POST /  -> \{ok.status} " + ok.body)
    let sse = @agent.AgentEndpoint::new(
      @agent.AIAgent::new(
        @agent.MockClient::new([@prompt.Message::assistant("streamed")]),
        model=@llm.deepseek_v4_flash,
      ),
    ).handle_sse("{\"message\":\"hi\"}")
    println("SSE frame (\{sse.length()} chars):")
    println(sse)
    let bad = endpoint.handle("not json")
    println("POST / (bad body) -> \{bad.status} " + bad.body)
  })
}
