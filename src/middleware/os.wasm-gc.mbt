///|
/// No process and no file system on this target: the tools that need one say so instead of
/// pretending to run.
pub let os_shell : Array[String] = []

///|
async fn os_run(
  _prefix : Array[String],
  _command : String,
  _cwd : String?,
  _timeout_ms : Int32,
) -> String {
  "error: running commands needs a native target"
}

///|
async fn os_glob(_pattern : String, _cwd : String) -> Array[String] {
  []
}

///|
async fn os_read(_path : String, _limit : Int32) -> String {
  "error: reading files needs a native target"
}
