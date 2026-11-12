///|
/// The shell a command line is handed to. Windows has no `sh`, so a `cmd.exe` install is used
/// there; everywhere else the POSIX shell is the one a caller expects.
pub let os_shell : Array[String] = match @env.get_env_var("OS") {
  Some(_) => ["cmd.exe", "/c"]
  None => ["sh", "-c"]
}

///|
/// Run one command line and return what it printed, exit code first.
async fn os_run(
  prefix : Array[String],
  command : String,
  cwd : String?,
  _timeout_ms : Int32,
) -> String {
  guard prefix.length() > 0 else { return "error: no shell is configured" }
  let program = prefix[0]
  let args : Array[String] = []
  for index in 1..<prefix.length() {
    args.push(prefix[index])
  }
  args.push(command)
  let ran = Ok(
    match cwd {
      Some(dir) => @process.collect_output(program, args, cwd=dir)
      None => @process.collect_output(program, args)
    },
  ) catch {
    error => Err(error)
  }
  match ran {
    Ok(result) => {
      let (code, out, err) = result
      let stdout = out.text() catch { _ => "" }
      let stderr = err.text() catch { _ => "" }
      let text = StringBuilder()
      text.write_string("exit " + code.to_string() + "\n")
      if stdout != "" {
        text.write_string(stdout)
      }
      if stderr != "" {
        text.write_string("\n[stderr]\n" + stderr)
      }
      text.to_string()
    }
    Err(error) => "error: " + error.to_string()
  }
}

///|
/// Expand a glob under `cwd`.
///
/// `**` walks the tree and the rest of the pattern is matched against the relative path; without
/// it only the directory's own entries are looked at, which is what `*.mbt` means.
async fn os_glob(pattern : String, cwd : String) -> Array[String] {
  let out : Array[String] = []
  if pattern.contains("**") {
    let tail = match pattern.find("**/") {
      Some(at) => pattern[at + 3:].to_owned()
      None => "*"
    }
    walk(cwd, "", tail, out, 0)
  } else {
    let entries = Ok(@fs.readdir(cwd)) catch { _ => Err(()) }
    match entries {
      Ok(names) =>
        for name in names {
          if matches(pattern, name) {
            out.push(cwd + "/" + name)
          }
        }
      Err(_) => ()
    }
  }
  out.sort()
  out
}

///|
/// Collect the paths under `root` whose relative path matches `pattern`, up to four levels deep —
/// enough for a source tree, bounded so a search cannot walk a whole disk.
async fn walk(
  root : String,
  relative : String,
  pattern : String,
  out : Array[String],
  depth : Int32,
) -> Unit {
  guard depth < 4 else { return }
  let here = if relative == "" { root } else { root + "/" + relative }
  let entries = Ok(@fs.readdir(here)) catch { _ => Err(()) }
  let names = match entries {
    Ok(names) => names
    Err(_) => return
  }
  for name in names {
    let path = if relative == "" { name } else { relative + "/" + name }
    let kind = Ok(@fs.kind(here + "/" + name)) catch { _ => Err(()) }
    match kind {
      Ok(@fs.FileKind::Directory) => walk(root, path, pattern, out, depth + 1)
      _ => if matches(pattern, path) { out.push(root + "/" + path) }
    }
  }
}

///|
/// Whether `path` matches a glob with `*` (any run of characters) and `?` (one character).
fn matches(pattern : String, path : String) -> Bool {
  match_pattern(pattern, 0, path, 0)
}

///|
fn match_pattern(
  pattern : String,
  at : Int32,
  path : String,
  from : Int32,
) -> Bool {
  if at >= pattern.length() {
    return from >= path.length()
  }
  let character = pattern[at]
  if character == '*' {
    let mut index = from
    while index <= path.length() {
      if match_pattern(pattern, at + 1, path, index) {
        return true
      }
      index = index + 1
    }
    return false
  }
  guard from < path.length() else { return false }
  if character == '?' || character == path[from] {
    return match_pattern(pattern, at + 1, path, from + 1)
  }
  false
}

///|
/// Read a file, cut at `limit` characters so a large file cannot flood the conversation.
async fn os_read(path : String, limit : Int32) -> String {
  let read = Ok(@fs.read_file(path)) catch { error => Err(error) }
  match read {
    Ok(data) => {
      let text = data.text() catch {
        _ => return "error: the file is not valid UTF-8"
      }
      if text.length() > limit {
        text[:limit].to_owned() +
        "\n[truncated at " +
        limit.to_string() +
        " characters]"
      } else {
        text
      }
    }
    Err(error) => "error: " + error.to_string()
  }
}
