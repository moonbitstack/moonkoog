// Prebuilt tools: exit returns the final answer, say/ask route through the injected I/O.

///|
test "prebuilt tools: exit, say_to_user, and ask_user route their arguments" {
  // ExitTool returns the `result` argument as the final answer.
  let exit_tool = @tools.ExitTool::new()
  assert_eq(exit_tool.descriptor().name, "__exit__")
  assert_eq(
    @tools.Tool::execute_raw(exit_tool, { "result": "all done" }),
    "all done",
  )
  // SayToUser writes the message to the sink and confirms.
  let shown : Array[String] = []
  let say = @tools.SayToUser::new(m => shown.push(m))
  let said = @tools.Tool::execute_raw(say, { "message": "hello there" })
  assert_eq(shown, ["hello there"])
  assert_eq(said, "Message shown to the user.")
  // AskUser returns whatever the responder answers.
  let ask = @tools.AskUser::new(q => "answer to: " + q)
  assert_eq(
    @tools.Tool::execute_raw(ask, { "question": "ready?" }),
    "answer to: ready?",
  )
}
