///|
/// A retriever over two short documents, which is all a retrieval test needs.
async fn sample_retriever() -> @moonrag.SimilarityRetriever {
  let embedder = @moonrag.HashingEmbedder::new(dimension=64)
  let store = @moonrag.InMemoryVectorStore::new(embedder)
  let _ = store.add([
    @moonrag.Document::new("The answer to the ultimate question is forty-two."),
    @moonrag.Document::new("Bananas are yellow and grow in bunches."),
  ])
  @moonrag.SimilarityRetriever::new(embedder, store)
}

///|
async test "rag: the middleware puts the matching passage in front of the model" {
  let retriever = sample_retriever()
  let provider = @fake.Fake::text("forty-two")
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model").with_middleware(
      @rag.Rag::new(retriever, limit=1),
    ),
  )
  assert_eq(
    agent.run("what is the answer to the ultimate question?"),
    "forty-two",
  )
  let messages = provider.seen()[0].messages
  assert_eq(messages[0].role is @moonmuse.System, true)
  assert_eq(messages[0].text_content().contains("forty-two"), true)
  assert_eq(messages[0].text_content().contains("Bananas"), false)
}

///|
async test "rag: the retrieval tool returns the passages it found" {
  let retriever = sample_retriever()
  let provider = @fake.Fake::new([
    @moonmuse.Reply::new(
      @moonmuse.Message::new(@moonmuse.Assistant, [
        @moonmuse.Part::call(
          "call_1",
          @rag.search_tool,
          Json::object(Map([("query", Json::string("bananas"))])),
        ),
      ]),
      finish=@moonmuse.Finish::Calls,
    ),
    @moonmuse.Reply::new(@moonmuse.Message::assistant("they are yellow")),
  ])
  let agent = @agent.create_agent(
    provider,
    @agent.AgentConfig::new("test-model").with_tools([
      @rag.retrieval_tool(retriever, limit=1),
    ]),
  )
  assert_eq(agent.run("what colour are bananas?"), "they are yellow")
  let seen = provider.seen()
  let last = seen[seen.length() - 1]
  let mut reported = ""
  for message in last.messages {
    for part in message.results() {
      match part {
        @moonmuse.Part::Result(content~, ..) => reported = content
        _ => ()
      }
    }
  }
  assert_eq(reported.contains("Bananas"), true)
}
