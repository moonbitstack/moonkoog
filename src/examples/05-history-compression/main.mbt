///|
/// History compression (Koog `HistoryCompressor`): fold a long conversation into a
/// short TLDR the model produces. `WholeHistory` replaces everything with one
/// summary; `FromLastN` summarizes the older turns and keeps the last N verbatim.
/// The scripted client stands in for the summarizing model.
///
///     moon run examples/14-history-compression --target native
#coverage.skip
async fn main {
  @async.with_task_group(_g => {
    let history = [
      @moonmuse.Message::user("m1: hello"),
      @moonmuse.Message::assistant("m2: hi"),
      @moonmuse.Message::user("m3: what's the weather"),
      @moonmuse.Message::assistant("m4: sunny in heke1228"),
    ]
    fn dump(label : String, msgs : Array[@moonmuse.Message]) -> Unit {
      println(label + " (\{msgs.length()} messages):")
      for m in msgs {
        println("  " + m.text_content())
      }
    }

    // FromLastN(2): summarize m1,m2 into a TLDR, keep m3,m4 as they are.
    let c1 = @agent.HistoryCompressor::new(
      @agent.MockClient::new([
        @moonmuse.Message::assistant("greeting, then a weather ask"),
      ]),
      @models.deepseek_v4_flash,
    )
    dump("FromLastN(2)", c1.compress(history, @agent.FromLastN(2)))

    // WholeHistory: one summary replaces the whole conversation.
    let c2 = @agent.HistoryCompressor::new(
      @agent.MockClient::new([
        @moonmuse.Message::assistant(
          "user greeted and asked about weather; assistant answered sunny",
        ),
      ]),
      @models.deepseek_v4_flash,
    )
    dump("WholeHistory", c2.compress(history, @agent.WholeHistory))
  })
}
