// The regex search tool lists files whose contents match the pattern.

///|
test "regex search tool: lists files whose contents match the pattern" {
  let fs = @tools.MemFileSystem::new()
  let write = @tools.WriteFileTool::new(fs)
  @tools.Tool::execute_raw(write, {
    "path": "proj/a.txt",
    "content": "hello world",
  })
  |> ignore
  @tools.Tool::execute_raw(write, { "path": "proj/b.txt", "content": "goodbye" })
  |> ignore
  let search = @tools.RegexSearchTool::new(fs)
  // `wor.d` matches "world" in a.txt but nothing in b.txt.
  assert_eq(
    @tools.Tool::execute_raw(search, { "path": "proj", "pattern": "wor.d" }),
    "proj/a.txt\n",
  )
}
