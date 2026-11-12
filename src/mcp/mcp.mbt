///|
/// The text of a tool result: every text block, in order. A result with no text — an image, say —
/// is reported as such rather than silently becoming an empty string.
pub fn text_of(result : @types.CallToolResult) -> String {
  let out = StringBuilder()
  for block in result.content {
    match block {
      @types.ContentBlock::Text(text~, ..) => out.write_string(text)
      _ => ()
    }
  }
  let text = out.to_string()
  if text == "" {
    if result.is_error {
      "the tool reported an error without a message"
    } else {
      "the tool returned no text"
    }
  } else {
    text
  }
}

///|
/// The tools of a server behind `client`, as tools of this framework.
///
/// The listing comes from the server, so a tool added there reaches the model without a line of
/// local code — which is the point of speaking the protocol rather than importing a library.
/// `prefix` namespaces the names, for a run that talks to more than one server.
pub async fn tools(
  client : @client.Client,
  prefix? : String,
) -> Array[@agent.ToolSpec] {
  let listed = client.list_tools()
  let specs : Array[@agent.ToolSpec] = []
  for tool in listed {
    let name = match prefix {
      Some(prefix) => prefix + "_" + tool.name
      None => tool.name
    }
    let remote = tool.name
    specs.push(
      @agent.ToolSpec::new(
        name~,
        description=tool.description.unwrap_or(tool.name),
        schema=tool.input_schema,
        run=async fn(args, _context) {
          let called = client.call_tool(
            remote,
            arguments=arguments_of(args).unwrap_or(Map([])),
          ) catch {
            error => return "error: the call failed: " + error.to_string()
          }
          text_of(called)
        },
      ),
    )
  }
  specs
}

///|
/// The arguments of a call as the protocol wants them: an object, or nothing.
fn arguments_of(args : Json) -> Map[String, Json]? {
  match args {
    Object(fields) => Some(fields)
    _ => None
  }
}

///|
/// The tool a served agent answers on.
pub let chat_tool : String = "chat"

///|
/// Expose an agent as an MCP server: one tool, `chat`, that takes a message and returns the
/// agent's answer.
///
/// A server is the right shape for an agent other programs drive — an editor, a desktop app, an
/// orchestrator that speaks MCP already — because it needs no HTTP surface of its own and can
/// run over stdio.
pub fn serve(
  agent : @agent.Agent,
  name? : String,
  version~ : String = "0.1.0",
) -> @moonmcp.Server raise @moonmcp.FastMCPError {
  let server = @moonmcp.Server::new(name.unwrap_or(agent.name()), version~)
  server.add_tool(
    @tools.Tool::new(
      chat_tool,
      parameters=Json::object(
        Map([
          ("type", Json::string("object")),
          (
            "properties",
            Json::object(
              Map([
                (
                  "message",
                  Json::object(Map([("type", Json::string("string"))])),
                ),
              ]),
            ),
          ),
          ("required", Json::array([Json::string("message")])),
        ]),
      ),
      run_fn=async fn(args) raise @moonmcp.FastMCPError {
        let message = match args.get("message") {
          Some(String(message)) => message
          _ => ""
        }
        if message == "" {
          return @tools.ToolResult::new(content=[
            @moonmcp.text_block("error: no message was given"),
          ])
        }
        let answered = Ok(agent.run(message)) catch { error => Err(error) }
        match answered {
          Ok(answer) =>
            @tools.ToolResult::new(content=[@moonmcp.text_block(answer)])
          Err(_) =>
            @tools.ToolResult::new(content=[
              @moonmcp.text_block("error: the agent run failed"),
            ])
        }
      },
    ),
  )
  server
}
