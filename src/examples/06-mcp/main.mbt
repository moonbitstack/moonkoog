// An agent on the wire: the server exposes one tool, the client lists it, and a second agent calls
// it — all over the in-memory transport, so the example runs anywhere.

///|
async fn main {
  let served = @moonkoog.create_agent(
    @fake.Fake::text("answered by the served agent"),
    @moonkoog.AgentConfig::new("scripted", name="helper"),
  )
  let server = @mcp.serve(served)
  let client = @client.Client::connect(@client.Memory::new(server))
  let specs = @mcp.tools(client)
  println("tools offered: " + specs.length().to_string())
  println("tool name: " + specs[0].tool.name)
}
