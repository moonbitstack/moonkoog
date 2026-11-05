// History compression: FromLastN summarizes the older messages and keeps the last N verbatim.

///|
async test "history compression: FromLastN summarizes older messages, keeps the last N" {
  @async.with_task_group(_g => {
    let messages = [
      @moonmuse.Message::user("m1"),
      @moonmuse.Message::assistant("m2"),
      @moonmuse.Message::user("m3"),
      @moonmuse.Message::assistant("m4"),
    ]
    let mock = @agent.MockClient::new([
      @moonmuse.Message::assistant("summary of m1,m2"),
    ])
    let compressor = @agent.HistoryCompressor::new(mock, @models.deepseek_v4_flash)
    let compressed = compressor.compress(messages, @agent.FromLastN(2))
    assert_eq(compressed.length(), 3)
    assert_eq(compressed[0].text_content(), "TLDR: summary of m1,m2")
    assert_eq(compressed[1].text_content(), "m3")
    assert_eq(compressed[2].text_content(), "m4")
  })
}
