///|
/// How one model call is made: the middleware chain, outermost first, ending at the provider.
/// Each middleware receives the rest of the chain, so a retry policy re-runs the ones inside it
/// and a cache short-circuits them.
pub async fn pipeline_model(
  runtime : Runtime,
  context : RunContext,
  call : ModelCall,
  mode : RequestMode,
) -> ModelOutcome {
  model_chain(runtime, 0, context, call, mode)
}

///|
async fn model_chain(
  runtime : Runtime,
  index : Int32,
  context : RunContext,
  call : ModelCall,
  mode : RequestMode,
) -> ModelOutcome {
  if index >= runtime.middleware.length() {
    return dispatch_model(runtime, mode, call)
  }
  let next : async (ModelCall) -> ModelOutcome = async fn(call) {
    model_chain(runtime, index + 1, context, call, mode)
  }
  runtime.middleware[index].wrap_model(context, call, next)
}

///|
/// The call itself — the innermost step of the chain.
async fn dispatch_model(
  runtime : Runtime,
  mode : RequestMode,
  call : ModelCall,
) -> ModelOutcome {
  match mode {
    StructuredOutput =>
      match runtime.structured {
        Some(spec) => {
          let asked = Ok(
            @structured.ask(
              runtime.provider,
              call.request,
              name=spec.name,
              schema=spec.schema,
              decode=json => Some(json),
            ),
          ) catch {
            error => Err(error)
          }
          let answer = match asked {
            Ok(answer) => answer
            Err(error) =>
              return Failed(reason=error_text(error), retryable=@moonmuse.LlmError::is_retryable(error))
          }
          let text = @moonjson.dumps(answer)
          Replied(
            @moonmuse.Reply::new(
              @moonmuse.Message::assistant(text),
              finish=@moonmuse.Finish::Stop,
            ),
          )
        }
        None =>
          Replied(
            @moonmuse.Reply::new(
              @moonmuse.Message::assistant(""),
              finish=@moonmuse.Finish::Stop,
            ),
          )
      }
    Streaming => {
      (runtime.events.on_llm_streaming_starting)(call.request)
      let streamed = Ok(
        runtime.provider.stream(call.request, delta => {
          match delta {
            @moonmuse.Delta::Text(chunk) =>
              (runtime.events.on_llm_streaming_frame)(chunk)
            _ => ()
          }
        }),
      ) catch {
        error => Err(error)
      }
      match streamed {
        Ok(reply) => {
          (runtime.events.on_llm_streaming_completed)(reply)
          Replied(reply)
        }
        Err(error) =>
          Failed(reason=error_text(error), retryable=@moonmuse.LlmError::is_retryable(error))
      }
    }
    _ => {
      let chatted = Ok(runtime.provider.chat(call.request)) catch {
        error => Err(error)
      }
      match chatted {
        Ok(reply) => Replied(reply)
        Err(error) =>
          Failed(
            reason=error_text(error),
            retryable=@moonmuse.LlmError::is_retryable(error),
          )
      }
    }
  }
}

///|
/// How one tool call is made: the middleware chain, ending at the toolbox. A tool that raises
/// or is not registered comes back as a failed outcome, which is what the model reads.
pub async fn pipeline_tool(
  runtime : Runtime,
  context : RunContext,
  call : ToolCall,
) -> ToolOutcome {
  tool_chain(runtime, 0, context, call)
}

///|
async fn tool_chain(
  runtime : Runtime,
  index : Int32,
  context : RunContext,
  call : ToolCall,
) -> ToolOutcome {
  if index >= runtime.middleware.length() {
    return dispatch_tool(runtime, call)
  }
  let next : async (ToolCall) -> ToolOutcome = async fn(call) {
    tool_chain(runtime, index + 1, context, call)
  }
  runtime.middleware[index].wrap_tool(context, call, next)
}

///|
/// Run the call through the toolbox and read the result back as an outcome.
async fn dispatch_tool(runtime : Runtime, call : ToolCall) -> ToolOutcome {
  let called = Ok(runtime.toolbox.call(call.part)) catch { error => Err(error) }
  let result = match called {
    Ok(result) => result
    Err(error) => return Failed("error: " + raised_text(error))
  }
  match result {
    @moonmuse.Part::Result(content~, error~, ..) =>
      if error {
        Failed(content)
      } else {
        Done(content)
      }
    other => Failed("error: not a tool result: " + other.text_of())
  }
}

///|
/// Run the run-start hooks in order and return what they asked to write.
pub async fn before_agent_hooks(
  runtime : Runtime,
  context : RunContext,
) -> Array[Update] {
  let updates : Array[Update] = []
  for middleware in runtime.middleware {
    let written = middleware.before_agent(context)
    for update in written {
      updates.push(update)
    }
  }
  updates
}

///|
/// Run the run-end hooks in order and return what they asked to write.
pub async fn after_agent_hooks(
  runtime : Runtime,
  context : RunContext,
  state : AgentState,
) -> Array[Update] {
  let updates : Array[Update] = []
  for middleware in runtime.middleware {
    let written = middleware.after_agent(context, state)
    for update in written {
      updates.push(update)
    }
  }
  updates
}

///|
/// Install every middleware's tools into the toolbox. Done once, when the agent is built.
pub fn install_tools(runtime : Runtime) -> Unit {
  for middleware in runtime.middleware {
    middleware.install(runtime.toolbox)
  }
}
