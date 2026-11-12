///|
/// Give the model a way to look around a directory tree.
///
/// Two tools, both read-only: `search_files` expands a glob under the root, and `read_file` opens
/// one file. The root is the whole of the permission model — a path that leaves it is refused
/// before anything is opened, which is what keeps a prompt-injected instruction from reading the
/// host's files.
pub struct FileSearch {
  root : String
  limit : Int32
  read_limit : Int32
}

///|
/// A search rooted at `root`, returning at most `limit` paths and at most `read_limit` characters
/// of any one file.
pub fn FileSearch::new(
  root : String,
  limit~ : Int32 = 100,
  read_limit~ : Int32 = 20_000,
) -> FileSearch {
  { root, limit, read_limit, }
}

///|
/// The tools the middleware installs.
pub let search_tool : String = "search_files"

///|
pub let read_tool : String = "read_file"

///|
pub extend FileSearch with @agent.Middleware::{
  name,
  install,
  before_agent,
  wrap_model,
  wrap_tool,
  after_agent,
}

///|
pub impl @agent.Middleware for FileSearch with fn name(_self) {
  "file_search"
}

///|
pub impl @agent.Middleware for FileSearch with fn install(self, tools) {
  tools.add(
    @agent.ToolSpec::new(
      name=search_tool,
      description="List files under the working directory that match a glob, such as **/*.mbt.",
      schema=Json::object(
        Map([
          ("type", Json::string("object")),
          (
            "properties",
            Json::object(
              Map([
                (
                  "pattern",
                  Json::object(Map([("type", Json::string("string"))])),
                ),
              ]),
            ),
          ),
          ("required", Json::array([Json::string("pattern")])),
        ]),
      ),
      run=async fn(args, _context) {
        let pattern = arg_string(args, "pattern").unwrap_or("")
        guard pattern != "" else { return "error: no pattern was given" }
        guard !escapes(pattern) else {
          return "error: the pattern must stay inside the working directory"
        }
        let hits = os_glob(pattern, self.root)
        guard hits.length() > 0 else { return "no file matches " + pattern }
        let listed = StringBuilder()
        let mut shown = 0
        for hit in hits {
          if shown >= self.limit {
            listed.write_string("[more matches were not listed]\n")
            break
          }
          listed.write_string(hit + "\n")
          shown = shown + 1
        }
        listed.to_string()
      },
    ),
  )
  tools.add(
    @agent.ToolSpec::new(
      name=read_tool,
      description="Read a file under the working directory.",
      schema=Json::object(
        Map([
          ("type", Json::string("object")),
          (
            "properties",
            Json::object(
              Map([
                ("path", Json::object(Map([("type", Json::string("string"))]))),
              ]),
            ),
          ),
          ("required", Json::array([Json::string("path")])),
        ]),
      ),
      run=async fn(args, _context) {
        let path = arg_string(args, "path").unwrap_or("")
        guard path != "" else { return "error: no path was given" }
        guard !escapes(path) else {
          return "error: the path must stay inside the working directory"
        }
        os_read(self.root + "/" + path, self.read_limit)
      },
    ),
  )
}

///|
pub impl @agent.Middleware for FileSearch with fn before_agent(_self, _context) {
  []
}

///|
pub impl @agent.Middleware for FileSearch with fn wrap_model(
  _self,
  _context,
  call,
  next,
) {
  next(call)
}

///|
pub impl @agent.Middleware for FileSearch with fn wrap_tool(
  _self,
  _context,
  call,
  next,
) {
  next(call)
}

///|
pub impl @agent.Middleware for FileSearch with fn after_agent(
  _self,
  _context,
  _state,
) {
  []
}

///|
/// Whether a path climbs out of the directory it is resolved against.
fn escapes(path : String) -> Bool {
  path.has_prefix("/") || path.contains("..") || path.contains(":\\")
}
