///|
/// No process and no file system on this target: the tools that need one say so instead of
/// pretending to run. The functions stay asynchronous so their callers are written once, and the
/// yield keeps the signature honest rather than nominal.
pub let os_shell : Array[String] = []

///|
async fn os_run(
  _prefix : Array[String],
  _command : String,
  _cwd : String?,
  _timeout_ms : Int32,
) -> String {
  @async.sleep(0)
  "error: running commands needs a native target"
}

///|
async fn os_glob(_pattern : String, _cwd : String) -> Array[String] {
  @async.sleep(0)
  []
}

///|
async fn os_read(_path : String, _limit : Int32) -> String {
  @async.sleep(0)
  "error: reading files needs a native target"
}
