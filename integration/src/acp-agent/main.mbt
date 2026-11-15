// The agent on ACP over stdin and stdout: the process an editor launches. Nothing but protocol
// frames goes to stdout, so the peer reads answers and the run reports nothing of its own.
//
//     integration/src/acp-agent  (spawned by peers/acp_client.py)

///|
async fn main {
  let agent = @moonkoog.create_agent(
    @fake.Fake::text("answered over ACP"),
    @moonkoog.AgentConfig::new("scripted", name="editor-agent"),
  )
  @stdio.serve_stdio(@acp.Acp::new(agent))
}
