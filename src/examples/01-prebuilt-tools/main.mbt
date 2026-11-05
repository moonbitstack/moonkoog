///|
/// A scripted shell so the example runs without touching the machine.
struct FakeShell {}

///|
impl @tools.ShellExecutor for FakeShell with fn run(_self, command) {
  "$ " + command + "\nok"
}

///|
/// The ready-made tools an agent is handed (Koog `agents-ext`): file tools over an
/// injected `FileSystem`, the regex search tool, the shell tool over an injected
/// `ShellExecutor`, and the user-facing exit / say / ask tools whose I/O is a
/// callback. Each is driven directly through `execute_raw` on JSON arguments.
///
///     moon run examples/05-prebuilt-tools --target native
#coverage.skip
fn main {
  let fs : &@tools.FileSystem = @tools.MemFileSystem::new()
  let write : &@tools.Tool = @tools.WriteFileTool::new(fs)
  let read : &@tools.Tool = @tools.ReadFileTool::new(fs)
  let list : &@tools.Tool = @tools.ListDirectoryTool::new(fs)
  let search : &@tools.Tool = @tools.RegexSearchTool::new(fs)
  let shell : &@tools.Tool = @tools.ExecuteShellCommandTool::new(FakeShell::{ })
  let exit : &@tools.Tool = @tools.ExitTool::new()
  let say : &@tools.Tool = @tools.SayToUser::new(msg => {
    println("  [user sees] " + msg)
  })
  let ask : &@tools.Tool = @tools.AskUser::new(_q => "heke1228")
  try {
    println(
      write.execute_raw({ "path": "/proj/readme.md", "content": "hello qwq" }),
    )
    println(
      write.execute_raw({ "path": "/proj/notes.txt", "content": "todo hhh" }),
    )
    println("read: " + read.execute_raw({ "path": "/proj/readme.md" }))
    println("list:\n" + list.execute_raw({ "path": "/proj" }))
    println(
      "search 'todo':\n" +
      search.execute_raw({ "path": "/proj", "pattern": "todo" }),
    )
    println("shell:\n" + shell.execute_raw({ "command": "echo hi" }))
    println("exit: " + exit.execute_raw({ "result": "done, final answer 233" }))
    println("say returns: " + say.execute_raw({ "message": "build is green" }))
    println("ask returns: " + ask.execute_raw({ "question": "your handle?" }))
  } catch {
    e => println("error: " + e.to_string())
  }
}
