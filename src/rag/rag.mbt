///|
/// The tool a retrieval provider exposes to the model.
pub let search_tool : String = "search_documents"

///|
/// How a retrieved passage is written into the conversation.
pub fn passage(index : Int32, hit : @moonrag.Scored) -> String {
  "[" + index.to_string() + "] " + hit.document.text
}

///|
/// The passages from `hits`, numbered, for a prompt or a tool result.
pub fn passages(hits : Array[@moonrag.Scored]) -> String {
  guard hits.length() > 0 else { return "nothing relevant was found" }
  let out = StringBuilder()
  for index, hit in hits {
    out.write_string(passage(index + 1, hit) + "\n\n")
  }
  out.to_string()
}

///|
/// Retrieval as a tool: the model decides when to look, and reads what came back.
///
/// The alternative — retrieving before every call — buys recall at the cost of tokens and can
/// drown a question that did not need a document. Handing retrieval to the model keeps the
/// decision where the question is.
pub fn retrieval_tool(
  retriever : &@moonrag.Retriever,
  limit~ : Int32 = 4,
  name~ : String = search_tool,
) -> @agent.ToolSpec {
  @agent.ToolSpec::new(
    name~,
    description="Search the documents this agent was given and return the passages that match.",
    schema=Json::object(
      Map([
        ("type", Json::string("object")),
        (
          "properties",
          Json::object(
            Map([
              ("query", Json::object(Map([("type", Json::string("string"))]))),
            ]),
          ),
        ),
        ("required", Json::array([Json::string("query")])),
      ]),
    ),
    run=async fn(args, _context) {
      let query = match args {
        Object(fields) =>
          match fields.get("query") {
            Some(String(query)) => query
            _ => ""
          }
        _ => ""
      }
      guard query != "" else { return "error: no query was given" }
      let hits = retriever.retrieve(query, limit~) catch {
        error => return "error: the search failed: " + error.to_string()
      }
      passages(hits)
    },
  )
}

///|
/// Retrieval as middleware: look up what the user just asked, and put the passages in front of
/// the model.
///
/// One retrieval per model call, on the last user message. That is the shape a knowledge
/// assistant wants — the answer is grounded whether or not the model thought to search — and it
/// is why the two forms both exist rather than one replacing the other.
pub struct Rag {
  retriever : &@moonrag.Retriever
  limit : Int32
  label : String
}

///|
/// Retrieve `limit` passages per call and label them with `label`.
pub fn Rag::new(
  retriever : &@moonrag.Retriever,
  limit~ : Int32 = 4,
  label~ : String = "Knowledge",
) -> Rag {
  { retriever, limit, label, }
}

///|
pub extend Rag with @agent.Middleware::{
  name,
  install,
  before_agent,
  wrap_model,
  wrap_tool,
  after_agent,
}

///|
pub impl @agent.Middleware for Rag with fn name(_self) {
  "rag"
}

///|
pub impl @agent.Middleware for Rag with fn install(_self, _tools) {
  ()
}

///|
pub impl @agent.Middleware for Rag with fn before_agent(_self, _context) {
  []
}

///|
pub impl @agent.Middleware for Rag with fn wrap_model(
  self,
  _context,
  call,
  next,
) {
  let query = last_user_text(call.request.messages)
  guard query != "" else { return next(call) }
  let hits = self.retriever.retrieve(query, limit=self.limit) catch {
    _ => return next(call)
  }
  guard hits.length() > 0 else { return next(call) }
  let messages : Array[@moonmuse.Message] = []
  messages.push(
    @moonmuse.Message::system(
      self.label + " passages that may be relevant:\n\n" + passages(hits),
    ),
  )
  for message in call.request.messages {
    messages.push(message)
  }
  next({ request: call.request.with_messages(messages), })
}

///|
pub impl @agent.Middleware for Rag with fn wrap_tool(
  _self,
  _context,
  call,
  next,
) {
  next(call)
}

///|
pub impl @agent.Middleware for Rag with fn after_agent(_self, _context, _state) {
  []
}

///|
/// The last user message of a conversation, which is the query a retrieval runs on.
fn last_user_text(messages : Array[@moonmuse.Message]) -> String {
  let mut index = messages.length() - 1
  while index >= 0 {
    if messages[index].role is @moonmuse.User {
      return messages[index].text_content()
    }
    index = index - 1
  }
  ""
}
