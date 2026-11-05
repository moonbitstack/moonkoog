// Serving an agent over HTTP: a valid request runs the agent and returns its output as JSON, an SSE
// request frames that output as a data event, and a malformed body is a 400.

///|
async test "agent endpoint: runs the agent and returns its output as JSON" {
  @async.with_task_group(_g => {
    let mock = @agent.MockClient::new([
      @moonmuse.Message::assistant("hello, world"),
    ])
    let endpoint = @agent.AgentEndpoint::new(
      @agent.AIAgent::new(mock, model=@models.deepseek_v4_flash),
    )
    let resp = endpoint.handle("{\"message\":\"hi\"}")
    assert_eq(resp.status, 200)
    assert_eq(
      @json.parse(resp.body),
      @json.parse("{\"output\":\"hello, world\"}"),
    )
  })
}

///|
async test "agent endpoint: streams the output as a Server-Sent Event" {
  @async.with_task_group(_g => {
    let mock = @agent.MockClient::new([@moonmuse.Message::assistant("streamed")])
    let endpoint = @agent.AgentEndpoint::new(
      @agent.AIAgent::new(mock, model=@models.deepseek_v4_flash),
    )
    let frame = endpoint.handle_sse("{\"message\":\"hi\"}")
    assert_eq(frame, "data: {\"output\":\"streamed\"}\n\n")
  })
}

///|
async test "agent endpoint: a malformed body is a 400" {
  @async.with_task_group(_g => {
    let mock = @agent.MockClient::new([@moonmuse.Message::assistant("x")])
    let endpoint = @agent.AgentEndpoint::new(
      @agent.AIAgent::new(mock, model=@models.deepseek_v4_flash),
    )
    let resp = endpoint.handle("not json")
    assert_eq(resp.status, 400)
  })
}
