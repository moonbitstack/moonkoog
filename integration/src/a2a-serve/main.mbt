// The agent as an A2A server, on a real socket: the peer is the official Python SDK's client,
// which reads the card from the well-known address and then sends a message.
//
//     moon run --target native integration/src/a2a-serve -- <port>

///|
/// The port an argument names; zero when it is not a number, which asks the system for one.
fn port_of(text : String) -> Int32 {
  let mut port = 0
  for index in 0..<text.length() {
    let character = text[index]
    guard character >= '0' && character <= '9' else { return 0 }
    port = port * 10 + (character.to_int() - '0'.to_int())
  }
  port
}

///|
/// The card this agent publishes, at `url`.
fn card(url : String) -> @moona2a.AgentCard {
  @moona2a.AgentCard::new(
    "interop",
    "an agent that answers questions for the interop checks",
    "1.0.0",
    url,
    [
      @moona2a.AgentSkill::new(
        "answer",
        "Answer",
        "Answer anything, briefly",
        ["interop"],
      ),
    ],
  ).capable(@moona2a.AgentCapabilities::streaming_and_push())
}

///|
async fn main {
  let args = @env.args()
  let port = if args.length() > 1 { port_of(args[1]) } else { 0 }
  let agent = @moonkoog.create_agent(
    @fake.Fake::text("answered over the wire"),
    @moonkoog.AgentConfig::new("scripted", name="peer"),
  )
  let url = "http://127.0.0.1:" + port.to_string()
  let server = @moona2a.Server::new(@a2a.executor(agent), card(url))
  let app = @asgi.to_asgi(server)
  println("a2a-serve: the agent listens on " + url)
  @mooncat.serve(app, port~)
}
