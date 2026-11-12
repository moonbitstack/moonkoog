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
  timeout_ms : Int32,
) -> String {
  guard prefix.length() > 0 else { return "error: no shell is configured" }
  let program = prefix[0]
  let args : Array[String] = []
  for index in 1..<prefix.length() {
    args.push(prefix[index])
  }
  args.push(command)
  let run = Ok(
    (match cwd {
      Some(dir) => @shell.Cmd::Cmd(program, args, cwd=dir)
      None => @shell.Cmd::Cmd(program, args)
    }).output(timeout_ms~, max_output_bytes=65536),
  ) catch {
    error => Err(error)
  }
  match run {
    Ok(output) => {
      let out = output.stdout()
      let err = output.stderr()
      let code = output.exit_code()
      let text = StringBuilder()
      text.write_string("exit " + code.to_string() + "\n")
      if out != "" {
        text.write_string(out)
      }
      if err != "" {
        text.write_string("\n[stderr]\n" + err)
      }
      text.to_string()
    }
    Err(error) => "error: " + error.to_string()
  }
}

///|
/// Expand a glob under `cwd`.
async fn os_glob(pattern : String, cwd : String) -> Array[String] {
  @shell.glob(pattern, cwd~) catch {
    _ => []
  }
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
