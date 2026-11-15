// The cases of `MissingToolsConversionStrategyTest`, transcribed: a conversation that names a
// tool the current agent does not offer is rewritten before it is sent, so a provider never sees
// a call it did not advertise or a result whose call it cannot find.

///|
/// A conversation recorded by an agent with two tools: one call and its result per tool.
fn missing_tools_conversation() -> Array[@moonmuse.Message] {
  [
    @moonmuse.Message::user("User message"),
    @moonmuse.Message::assistant("Assistant message"),
    @moonmuse.Message::new(Assistant, [
      @moonmuse.Part::call(
        "test-call-id",
        "test-tool",
        Json::object(Map([("param", Json::string("value"))])),
      ),
    ]),
    @moonmuse.Message::new(Tool, [
      @moonmuse.Part::result("test-call-id", "Test result content"),
    ]),
    @moonmuse.Message::new(Assistant, [
      @moonmuse.Part::call(
        "another-call-id",
        "another-tool",
        Json::object(Map([("param", Json::string("another-value"))])),
      ),
    ]),
    @moonmuse.Message::new(Tool, [
      @moonmuse.Part::result("another-call-id", "Another test result content"),
    ]),
  ]
}

///|
/// The text of the only part of `message`.
fn only_text(message : @moonmuse.Message) -> String {
  message.text_content()
}

///|
test "koog: testConvertMessageWithToolCall — a call becomes the text that describes it" {
  let messages = [
    @moonmuse.Message::new(Assistant, [
      @moonmuse.Part::call(
        "test-call-id",
        "test-tool",
        Json::object(Map([("param", Json::string("value"))])),
      ),
    ]),
  ]
  let converted = @agent.convert_missing_tools(messages, [], @agent.ConvertAll)
  assert_eq(converted.length(), 1)
  assert_eq(
    only_text(converted[0]),
    "{\"tool_call_id\":\"test-call-id\",\"tool_name\":\"test-tool\",\"tool_args\":{\"param\":\"value\"}}",
  )
  // The message is still the assistant's: what it said is now prose rather than a call.
  assert_eq(converted[0].role is Assistant, true)
}

///|
test "koog: testConvertMessageWithToolResult — a result becomes the text that describes it" {
  let messages = [
    @moonmuse.Message::new(Assistant, [
      @moonmuse.Part::call("test-call-id", "test-tool", Json::object(Map([]))),
    ]),
    @moonmuse.Message::new(Tool, [
      @moonmuse.Part::result("test-call-id", "Test result content"),
    ]),
  ]
  let converted = @agent.convert_missing_tools(messages, [], @agent.ConvertAll)
  assert_eq(
    only_text(converted[1]),
    "{\"tool_call_id\":\"test-call-id\",\"tool_name\":\"test-tool\",\"tool_result\":\"Test result content\"}",
  )
}

///|
test "koog: testConvertMessageWithRegularMessage — a message with no tool parts is untouched" {
  let messages = [@moonmuse.Message::user("Regular message content")]
  let converted = @agent.convert_missing_tools(messages, [], @agent.ConvertAll)
  assert_eq(converted.length(), 1)
  assert_eq(only_text(converted[0]), "Regular message content")
  assert_eq(converted[0].calls().length(), 0)
}

///|
test "koog: testAllStrategyConvertPrompt — every call and result is rewritten, in place" {
  let converted = @agent.convert_missing_tools(
    missing_tools_conversation(),
    ["test-tool", "another-tool"],
    @agent.ConvertAll,
  )
  assert_eq(converted.length(), 6)
  assert_eq(only_text(converted[0]), "User message")
  assert_eq(only_text(converted[1]), "Assistant message")
  assert_eq(
    only_text(converted[2]),
    "{\"tool_call_id\":\"test-call-id\",\"tool_name\":\"test-tool\",\"tool_args\":{\"param\":\"value\"}}",
  )
  assert_eq(
    only_text(converted[3]),
    "{\"tool_call_id\":\"test-call-id\",\"tool_name\":\"test-tool\",\"tool_result\":\"Test result content\"}",
  )
  assert_eq(converted[2].calls().length(), 0)
}

///|
test "koog: testMissingStrategyConvertPromptWithMissingTool — only the tool that is gone is rewritten" {
  let converted = @agent.convert_missing_tools(
    missing_tools_conversation(),
    ["test-tool"],
    @agent.Convert,
  )
  assert_eq(converted.length(), 6)
  // The tool this agent still has keeps its call and its result.
  assert_eq(converted[2].calls().length(), 1)
  assert_eq(converted[3].results().length(), 1)
  // The one it does not have becomes text, and the result still names its tool.
  assert_eq(
    only_text(converted[4]),
    "{\"tool_call_id\":\"another-call-id\",\"tool_name\":\"another-tool\",\"tool_args\":{\"param\":\"another-value\"}}",
  )
  assert_eq(
    only_text(converted[5]),
    "{\"tool_call_id\":\"another-call-id\",\"tool_name\":\"another-tool\",\"tool_result\":\"Another test result content\"}",
  )
}

///|
test "koog: testMissingStrategyConvertPromptWithAllToolsPresent — nothing is rewritten when every tool is there" {
  let converted = @agent.convert_missing_tools(
    missing_tools_conversation(),
    ["test-tool", "another-tool"],
    @agent.Convert,
  )
  assert_eq(converted.length(), 6)
  assert_eq(converted[2].calls().length(), 1)
  assert_eq(converted[3].results().length(), 1)
  assert_eq(converted[4].calls().length(), 1)
  assert_eq(converted[5].results().length(), 1)
}

///|
test "koog: testMissingStrategyConvertPromptWithEmptyTools — an agent with no tools rewrites all of it" {
  let converted = @agent.convert_missing_tools(
    missing_tools_conversation(),
    [],
    @agent.Convert,
  )
  assert_eq(converted.length(), 6)
  assert_eq(converted[2].calls().length(), 0)
  assert_eq(converted[3].results().length(), 0)
  assert_eq(converted[4].calls().length(), 0)
  assert_eq(converted[5].results().length(), 0)
  assert_eq(
    only_text(converted[2]).contains("\"tool_name\":\"test-tool\""),
    true,
  )
}

///|
test "koog: testEmptyPrompt — an empty conversation stays empty" {
  let converted = @agent.convert_missing_tools(
    [],
    ["test-tool"],
    @agent.Convert,
  )
  assert_eq(converted.length(), 0)
}

///|
test "koog: testNullIdToolCall — a call without an id is still rewritten" {
  let messages = [
    @moonmuse.Message::new(Assistant, [
      @moonmuse.Part::call("", "test-tool", Json::object(Map([]))),
    ]),
  ]
  let converted = @agent.convert_missing_tools(messages, [], @agent.Convert)
  assert_eq(converted[0].calls().length(), 0)
  assert_eq(only_text(converted[0]).contains("\"tool_call_id\":\"\""), true)
}

///|
test "koog: testNullIdToolResult — a result without an id is rewritten and names no tool" {
  let messages = [
    @moonmuse.Message::new(Tool, [@moonmuse.Part::result("", "orphan result")]),
  ]
  let converted = @agent.convert_missing_tools(messages, [], @agent.Convert)
  assert_eq(converted[0].results().length(), 0)
  let text = only_text(converted[0])
  assert_eq(text.contains("\"tool_result\":\"orphan result\""), true)
  // No call with that id was seen, so no tool name is invented.
  assert_eq(text.contains("tool_name"), false)
}

///|
test "koog: the keeping policy leaves the conversation exactly as it was" {
  let messages = missing_tools_conversation()
  let converted = @agent.convert_missing_tools(messages, [], @agent.Keep)
  assert_eq(converted.length(), 6)
  assert_eq(converted[2].calls().length(), 1)
  assert_eq(converted[5].results().length(), 1)
}
