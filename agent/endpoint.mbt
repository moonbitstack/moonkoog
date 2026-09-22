// Serving an agent over HTTP (Koog `koog-ktor` `aiAgent` route helper / `sse`): the portable core of
// the Ktor integration — take a request whose body is `{"message": "..."}`, run the agent on it, and
// answer with `{"output": "..."}`, or stream that answer as a Server-Sent Event. The Ktor plugin and
// its route DSL are framework glue over exactly this; a mooncat/moonapi route binds to it the same
// way, so this handler is the framework-agnostic piece that actually runs the agent for a request.

///|
/// An HTTP response: a status code and a JSON body.
pub(all) struct AgentResponse {
  status : Int
  body : String
} derive(Eq, Debug)

///|
/// An HTTP endpoint that runs `agent` for each request (Koog `RoutingContext.aiAgent`).
pub struct AgentEndpoint {
  agent : AIAgent
}

///|
/// An endpoint serving `agent`.
pub fn AgentEndpoint::new(agent : AIAgent) -> AgentEndpoint {
  { agent, }
}

///|
/// Handle a request body `{"message": "..."}`: run the agent and answer `{"output": "..."}` with
/// status 200, or 400 when the body is not a valid request.
pub async fn AgentEndpoint::handle(
  self : AgentEndpoint,
  body : String,
) -> AgentResponse {
  match parse_message(body) {
    Some(message) =>
      { status: 200, body: output_body(self.agent.run(message)), }
    None => { status: 400, body: error_body("invalid request body"), }
  }
}

///|
/// Handle a request and stream the answer as one Server-Sent Event `data:` frame (Koog's `sse`
/// helper), or an `error` event when the body is invalid.
pub async fn AgentEndpoint::handle_sse(
  self : AgentEndpoint,
  body : String,
) -> String {
  match parse_message(body) {
    Some(message) =>
      @sse.Event::of(output_body(self.agent.run(message))).encode()
    None => @sse.Event::new(data="invalid request body", kind="error").encode()
  }
}

///|
/// The `message` field of a request body, or `None` when the body is not a JSON object carrying one.
fn parse_message(body : String) -> String? {
  let json = @json.parse(body) catch { _ => return None }
  match json {
    Object(o) =>
      match o.get("message") {
        Some(String(s)) => Some(s)
        _ => None
      }
    _ => None
  }
}

///|
/// A `{"output": ...}` response body.
fn output_body(output : String) -> String {
  ({ "output": output } : Json).stringify()
}

///|
/// An `{"error": ...}` response body.
fn error_body(message : String) -> String {
  ({ "error": message } : Json).stringify()
}

///|
pub extend AgentResponse with Debug::{to_repr}

///|
pub extend AgentResponse with Eq::{not_equal, equal}
