///|
/// A conversation the protocol keeps: an identifier, when it started, and whatever the client
/// wants remembered about it.
pub(all) struct Thread {
  thread_id : String
  created_at : Int64
  metadata : Json
}

///|
/// One execution of an agent on a thread.
pub(all) struct Run {
  run_id : String
  thread_id : String
  status : String
  answer : String?
  reason : String?
}

///|
/// The Agent Protocol's two resources: threads and the runs that use them.
///
/// The store is in memory and per server; a deployment that needs runs to outlive the process
/// passes a saver to the agent instead, because the conversation is checkpointed there and the
/// protocol's records are a view of it.
pub struct Server {
  agent : @agent.Agent
  threads : Map[String, Thread]
  runs : Map[String, Run]
  mut counter : Int32
}

///|
/// A server over `agent`.
pub fn Server::new(agent : @agent.Agent) -> Server {
  { agent, threads: Map([]), runs: Map([]), counter: 0, }
}

///|
/// The next identifier of this server. No clock is involved, which is why two servers number
/// their threads from one and a client should not read meaning into the number.
fn Server::next_id(self : Server, prefix : String) -> String {
  self.counter = self.counter + 1
  prefix + "-" + self.counter.to_string()
}

///|
/// Start a thread.
pub fn Server::create_thread(self : Server, metadata : Json) -> Thread {
  let thread : Thread = {
    thread_id: self.next_id("thread"),
    created_at: @env.now().reinterpret_as_int64(),
    metadata,
  }
  self.threads[thread.thread_id] = thread
  thread
}

///|
/// A thread by identifier.
pub fn Server::thread(self : Server, id : String) -> Thread? {
  self.threads.get(id)
}

///|
/// A run by identifier.
pub fn Server::run(self : Server, id : String) -> Run? {
  self.runs.get(id)
}

///|
/// Run the agent on `input` and record the run under `thread_id`.
///
/// The run is executed before the call returns, so its status is `completed` or `failed` by the
/// time a client reads it. A protocol whose runs are long-lived would hand back `queued` and
/// poll; that step belongs to whatever schedules the work, not to this adapter.
pub async fn Server::create_run(
  self : Server,
  thread_id : String,
  input : String,
) -> Run raise @agent.AgentError {
  guard self.threads.get(thread_id) is Some(_) else {
    raise @agent.Refused(reason="there is no thread named " + thread_id)
  }
  let run_id = self.next_id("run")
  let answered = Ok(self.agent.run(input, thread=thread_id)) catch {
    error => Err(error)
  }
  let run : Run = match answered {
    Ok(answer) =>
      {
        run_id,
        thread_id,
        status: "completed",
        answer: Some(answer),
        reason: None,
      }
    Err(error) =>
      {
        run_id,
        thread_id,
        status: "failed",
        answer: None,
        reason: Some(@agent.describe(error)),
      }
  }
  self.runs[run_id] = run
  run
}

///|
/// The thread as a client reads it.
pub fn Thread::to_json(self : Thread) -> Json {
  Json::object(
    Map([
      ("id", Json::string(self.thread_id)),
      ("object", Json::string("thread")),
      ("created_at", Json::number(self.created_at.to_double())),
      ("metadata", self.metadata),
    ]),
  )
}

///|
/// The run as a client reads it.
pub fn Run::to_json(self : Run) -> Json {
  let fields : Map[String, Json] = Map([
    ("id", Json::string(self.run_id)),
    ("object", Json::string("thread.run")),
    ("thread_id", Json::string(self.thread_id)),
    ("status", Json::string(self.status)),
  ])
  match self.answer {
    Some(answer) => fields["answer"] = Json::string(answer)
    None => ()
  }
  match self.reason {
    Some(reason) => fields["reason"] = Json::string(reason)
    None => ()
  }
  Json::object(fields)
}

///|
/// The routes an Agent Protocol client expects: create a thread, read it, run on it, read the
/// run.
///
/// The handlers are the protocol; serving them is `moonapi`'s job, and which server it is —
/// moonapi's own, mooncat, a cloud runtime — is a deployment decision this package does not
/// make.
pub fn app(server : Server) -> @moonapi.App {
  let app = @moonapi.App::new()
  app.post("/threads", fn(context) {
    let metadata = context.body_json().unwrap_or(Json::null())
    @status.json(200, server.create_thread(metadata).to_json())
  })
  app.get("/threads/{thread_id}", fn(context) {
    let id = context.param("thread_id").unwrap_or("")
    match server.thread(id) {
      Some(thread) => @status.json(200, thread.to_json())
      None =>
        @status.json(
          404,
          Json::object(Map([("error", Json::string("no such thread"))])),
        )
    }
  })
  app.post("/threads/{thread_id}/runs", async fn(context) {
    let id = context.param("thread_id").unwrap_or("")
    let input = match context.body_json() {
      Some(body) =>
        match body {
          Object(fields) =>
            match fields.get("input") {
              Some(String(input)) => input
              _ => ""
            }
          _ => ""
        }
      None => ""
    }
    if input == "" {
      return @status.json(
        400,
        Json::object(Map([("error", Json::string("no input was given"))])),
      )
    }
    let ran = Ok(server.create_run(id, input)) catch { error => Err(error) }
    match ran {
      Ok(run) => @status.json(200, run.to_json())
      Err(@agent.Refused(reason~)) =>
        @status.json(404, Json::object(Map([("error", Json::string(reason))])))
      Err(error) =>
        @status.json(
          500,
          Json::object(Map([("error", Json::string(@agent.describe(error)))])),
        )
    }
  })
  app.get("/threads/{thread_id}/runs/{run_id}", fn(context) {
    let id = context.param("run_id").unwrap_or("")
    match server.run(id) {
      Some(run) => @status.json(200, run.to_json())
      None =>
        @status.json(
          404,
          Json::object(Map([("error", Json::string("no such run"))])),
        )
    }
  })
  app
}
