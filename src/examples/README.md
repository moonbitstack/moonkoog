# Examples

| # | Example | What it shows |
|:--:|:--|:--|
| 01 | [`prebuilt-tools`](01-prebuilt-tools/) | The ready-made tools driven through `execute_raw`: file tools over a `MemFileSystem`, `RegexSearchTool`, the shell tool over an injected `ShellExecutor`, and the `ExitTool`/`SayToUser`/`AskUser` user-I/O tools |
| 02 | [`agent-loop`](02-agent-loop/) | The `AIAgent` tool-calling loop end to end (Koog's `singleRunStrategy`): request, run the tool the model asked for, feed the result back, finish on plain text — the answer derived from the tool's real output |
| 03 | [`agent-events`](03-agent-events/) | The `EventHandler` hooks: every lifecycle callback wired to a log so one tool-loop run prints its whole shape — agent start, each node visit, the two LLM calls bracketing the tool call, completion |
| 04 | [`choice-selection`](04-choice-selection/) | `ChoiceSelectionStrategy`: `FirstChoice` takes index 0, `LLMChoiceSelector` asks a judge model which candidate to keep |
| 05 | [`history-compression`](05-history-compression/) | `HistoryCompressor`: `WholeHistory` folds a conversation into one summary; `FromLastN` summarizes older turns and keeps the last N verbatim |
| 06 | [`critic`](06-critic/) | `LLMCritic`: a judge model reviews an answer and returns a `CriticVerdict` — CORRECT passes, otherwise it fails and extracts the feedback |
| 07 | [`planner`](07-planner/) | `LLMPlanner`: parse a plan from the model, execute each step threading state, mark it done, drive to completion with `run`, and keep/replan on the critic's verdict |
| 08 | [`goap`](08-goap/) | `goap_plan`: goal-oriented action planning — least-cost action sequence from a start state to a goal over `GoapAction`/`GoapGoal`, pure search, no model |
| 09 | [`agent-serving`](09-agent-serving/) | `AgentEndpoint`: serve an agent as an HTTP handler — a well-formed body returns the output as JSON, `handle_sse` frames it as an SSE event, a malformed body is a 400 |
| 10 | [`mcp`](10-mcp/) | The Model Context Protocol adapter: expose a `ToolRegistry` as an `McpServer`, discover and call it from an `McpClient` over `tools/list`+`tools/call`, and map a full JSON-Schema with `parse_tool` |
| 11 | [`agent-tracing`](11-agent-tracing/) | `EventHandler::tracing` rendering a whole run to a `LineTrace`, an interceptor rewriting the prompt on its way to the client, `on_tool_call_failed` reporting a tool that raised, and the `ResponseMetaInfo` token counts riding back on each reply |
