---
name: moonkoog
description: "Build an agent on MoonBit: create_agent with a provider and a config, tools that keep state, a middleware pipeline, plan-and-execute, teams that hand over, and the adapters that serve an agent over MCP, A2A, ACP or the Agent Protocol. Use when a task asks for an LLM agent, a tool-calling loop, an agent graph, or a protocol bridge in MoonBit."
---

# moonkoog

An agent is a state graph whose nodes talk to a model. The graph checkpoints, resumes, interrupts
and nests, so an agent, a plan, a team and a protocol server are one machinery.

## Install

```bash
moon add moonbitstack/moonkoog
```

Import the module root for the agent, the middleware, the planner and the teams; import a package
directly when you want one adapter.

```text
import {
  "moonbitstack/moonkoog",
  "moonbitstack/moonkoog/middleware",
  "moonbitstack/moonmuse/fake",
  "moonbitlang/async",
}
```

## Build an agent

`create_agent` takes a provider and a config. Anything implementing `Provider` works; the
scripted provider is what a test should use.

```mbt
async test "build an agent" {
  let provider = @fake.Fake::text("done")
  let agent = @moonkoog.create_agent(
    provider,
    @moonkoog.AgentConfig::new("my-model")
    .with_instructions("You answer in one sentence.")
    .with_tools([@moonkoog.calculator()]),
  )
  assert_eq(agent.run("what is 6 times 7?"), "done")
}
```

## Add middleware

Middleware wraps each model call and each tool call. Registration order is pipeline order: the
first one registered is the outermost.

```mbt
async test "add middleware" {
  let provider = @fake.Fake::text("ok")
  let agent = @moonkoog.create_agent(
    provider,
    @moonkoog.AgentConfig::new("my-model")
    .with_middleware(@middleware.ModelRetry::new(attempts=3))
    .with_middleware(@middleware.ModelCallLimit::new(limit=20))
    .with_middleware(@middleware.Pii::standard()),
  )
  assert_eq(agent.run("hello"), "ok")
}
```

## Stop for a person

`HumanInTheLoop` stops the run on the tools you name; the run raises `AgentError::Engine` wrapping
`GraphError::Interrupted`, and `resume_from` continues it with the answer. Pass a saver, or there
is nothing to resume from.

```mbt
async test "stop for a person" {
  let provider = @fake.Fake::text("ok")
  let saver = @moonstate.MemorySaver::new()
  let agent = @moonkoog.create_agent(
    provider,
    @moonkoog.AgentConfig::new("my-model")
    .with_middleware(@middleware.HumanInTheLoop::new(["delete_file"])),
    saver~,
  )
  let stopped = try Ok(agent.run("go", thread="t1")) catch { error => Err(error) }
  assert_eq(stopped is Err(_), true)
}
```

## Serve an agent

`moonkoog/mcp` exposes the agent as one `chat` tool on an MCP server, and turns a server's tools
into tools of this agent.

```mbt
async test "serve an agent" {
  let served = @moonkoog.create_agent(
    @fake.Fake::text("hello"),
    @moonkoog.AgentConfig::new("my-model", name="helper"),
  )
  let client = @client.Client::connect(@client.Memory::new(@mcp.serve(served)))
  assert_eq(@mcp.tools(client).length(), 1)
}
```

## Pitfalls

- A strategy is data. If you need a node of your own, register its body with
  `AgentConfig::with_node` and name it in the strategy; a node that decides where to go next
  returns `@moonstate.Step::Goto`.
- Tool bodies receive the run context. A tool that needs to remember something writes it with
  `context.pending.push(@moonkoog.Store(...))`; a tool that asks for a handover sets
  `context.handover.val`.
- A run without a saver still checkpoints, but only in memory for the length of the call: pass
  `saver~` when you want a thread to survive.
- `Agent::run` raises `AgentError`. Match `Refused` for a refusal, `Exhausted` for a cap, and
  `Engine(GraphError::Interrupted(..))` for a run that stopped for a person.
- Middleware that changes the conversation should return a new request from `wrap_model`, not
  mutate the state: the state is a snapshot, and writes go through the graph.
