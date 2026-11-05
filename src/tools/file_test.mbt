// File tools over an in-memory filesystem: write, read back, handle a miss, and list.

///|
test "file tools: write, read, and list over an in-memory filesystem" {
  let fs = @tools.MemFileSystem::new()
  let write = @tools.WriteFileTool::new(fs)
  let read = @tools.ReadFileTool::new(fs)
  let ls = @tools.ListDirectoryTool::new(fs)
  assert_eq(
    @tools.Tool::execute_raw(write, { "path": "proj/a.txt", "content": "alpha" }),
    "Wrote proj/a.txt",
  )
  let _ = @tools.Tool::execute_raw(write, {
    "path": "proj/b.txt",
    "content": "beta",
  })
  assert_eq(@tools.Tool::execute_raw(read, { "path": "proj/a.txt" }), "alpha")
  assert_eq(
    @tools.Tool::execute_raw(read, { "path": "proj/missing.txt" }),
    "file not found: proj/missing.txt",
  )
  assert_eq(
    @tools.Tool::execute_raw(ls, { "path": "proj" }),
    "proj/a.txt\nproj/b.txt",
  )
}
