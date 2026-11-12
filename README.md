<div align="center">

# moonkoog

**An agent framework for MoonBit: a run is a state graph.**

[![Check and Test](https://github.com/moonbitstack/moonkoog/actions/workflows/ci.yml/badge.svg)](https://github.com/moonbitstack/moonkoog/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)

[Home](https://moonbitstack.github.io/moonkoog/) · [Guide](https://moonbitstack.github.io/moonkoog/guide.html) · [API](https://moonbitstack.github.io/moonkoog/api.html) · [mooncakes](https://mooncakes.io/docs/moonbitstack/moonkoog)

</div>

An agent is a loop: ask a model, run what it asked for, feed the result back, ask again. What
makes an agent usable in a real program is everything around that loop — the state it keeps, the
place it stops, the way it is retried, the budget it may spend, and how it is reached from
outside.

moonkoog puts all of that on one engine. A run is a graph whose nodes talk to a model; the graph
checkpoints, resumes, interrupts, and nests, so an agent, a planner, a team and a protocol server
are the same machinery configured differently rather than four systems that have to agree.

```bash
moon add moonbitstack/moonkoog
```

## A first run

```mbt
async test "a first run" {
  let provider = @fake.Fake::text("A run is a graph that talks to a model.")
  let agent = @moonkoog.create_agent(
    provider,
    @moonkoog.AgentConfig::new("scripted").with_instructions("Answer in one sentence."),
  )
  assert_eq(agent.run("What is a run?"), "A run is a graph that talks to a model.")
}
```

`create_agent` takes a provider — anything implementing `Provider` — and a config. The config says
which model, what the instructions are, which tools may be called, which strategy the run follows,
what it may spend, and what middleware wraps its calls.

## The model

| Piece | What it is |
|:--|:--|
| **State** | `AgentState`: the conversation, the run's scratch space, and the calls it has spent. It round-trips through JSON, which is what makes a checkpoint a checkpoint. |
| **Strategy** | Data: named nodes, what each one does, and the edges between them. `single_run`, `chat`, `react`, `answer_only` and the plan-and-execute loop are presets; a node that decides where to go next returns a `Goto`. |
| **Nodes** | Four kinds cover a whole family of behaviours: a request (tools on, off, forced, several candidates, streamed, structured), a tool execution (all, or one), a history compression, and the exit. |
| **Middleware** | A chain around each model and tool call, taking the rest of the chain as a function. |
| **Events** | A run reports what it did; observers watch and interceptors rewrite the value in flight. |

A strategy is data, so a composed strategy — a plan, a team — compiles against the same runtime
and gets the same checkpointing, budgets and middleware for free.

## Tools

```mbt
async test "a tool" {
  let provider = @fake.Fake::new([
    @moonmuse.Reply::new(
      @moonmuse.Message::new(@moonmuse.Assistant, [
        @moonmuse.Part::call("c1", "echo", Json::object(Map([("text", Json::string("hi"))]))),
      ]),
      finish=@moonmuse.Finish::Calls,
    ),
    @moonmuse.Reply::new(@moonmuse.Message::assistant("done")),
  ])
  let tool = @moonkoog.ToolSpec::new(
    name="echo",
    description="Echo the text back.",
    schema=Json::object(Map([("type", Json::string("object"))])),
    run=fn(args, _context) {
      match args {
        Object(fields) =>
          match fields.get("text") {
            Some(String(text)) => text
            _ => ""
          }
        _ => ""
      }
    },
  )
  let agent = @moonkoog.create_agent(
    provider,
    @moonkoog.AgentConfig::new("scripted").with_tools([tool]),
  )
  assert_eq(agent.run("echo hi"), "done")
}
```

A tool's body receives the arguments and the run's context, which is what lets a tool keep state:
the todo list, the approval gate and the retrieval tool all use it.

## Middleware

Thirteen middlewares ship with the module. Each is a type with a `new` and no hidden global:

| Middleware | What it does |
|:--|:--|
| `ModelCallLimit` | Refuses a call once the run has spent its budget. |
| `ToolCallLimit` | Refuses a tool call, in total or for one tool. |
| `ModelRetry` | Retries the failures the provider calls retryable, with growing delays. |
| `ToolRetry` | Retries a failed tool call. |
| `ModelFallback` | Tries the alternatives in order when the primary fails. |
| `Summarization` | Folds an over-long conversation into a summary before sending it. |
| `ContextEditing` | Clears older tool results, or drops the oldest turns. |
| `TodoList` | Gives the model a list it writes its plan into. |
| `HumanInTheLoop` | Stops the run on a tool call until a person answers. |
| `Pii` | Scrubs personal data out of what the provider sees. |
| `ToolSelection` | Advertises only the tools a call needs. |
| `ShellTool` | Gives the model a shell, rooted where you say. |
| `FileSearch` | Gives the model a glob and a file reader, rooted where you say. |

```mbt
async test "a pipeline" {
  let provider = @fake.Fake::text("ok")
  let agent = @moonkoog.create_agent(
    provider,
    @moonkoog.AgentConfig::new("scripted")
    .with_middleware(@middleware.ModelCallLimit::new(limit=2))
    .with_middleware(@middleware.Pii::standard()),
  )
  assert_eq(agent.run("write to leo@example.com"), "ok")
  assert_eq(provider.seen()[0].messages[1].text_content(), "write to [email]")
}
```

## Planning and teams

`plan_and_execute` is a strategy: a planner node writes the steps, the model works through them
with its tools, and a step whose tool call failed sends the run back to the planner. Goal-oriented
planning is a search over world states — `GoapAction`, `GoapGoal`, `search` — independent of any
model, for the steps that can be planned without one.

A team is a strategy whose nodes are agents. Each member is a nested graph over the same
conversation, so a member sees what the ones before it said; a handover is a tool that records
where the conversation should go, and the team's router follows. `swarm` follows the members'
own handovers; `supervisor` asks its model which member acts next.

```mbt
async test "a team" {
  let first = @fake.Fake::new([
    @moonmuse.Reply::new(
      @moonmuse.Message::new(@moonmuse.Assistant, [
        @moonmuse.Part::call("c1", "handoff", Json::object(Map([("to", Json::string("writer"))]))),
      ]),
      finish=@moonmuse.Finish::Calls,
    ),
  ])
  let second = @fake.Fake::new([@moonmuse.Reply::new(@moonmuse.Message::assistant("written"))])
  let researcher = @moonkoog.create_agent(
    first,
    @moonkoog.AgentConfig::new("scripted", name="researcher")
    .with_tools([@moonkoog.handoff_tool(["writer"])]),
  )
  let writer = @moonkoog.create_agent(second, @moonkoog.AgentConfig::new("scripted", name="writer"))
  let team = @moonkoog.create_agent(
    first,
    @moonkoog.swarm(@moonkoog.AgentConfig::new("scripted", name="team"), [researcher, writer]),
  )
  assert_eq(team.run("write a line"), "written")
}
```

## Protocols

Six adapters put an agent behind something else. Each is a translation of events, tools and
interrupts the agent already has; none keeps a second copy of that state.

| Package | Direction |
|:--|:--|
| `moonkoog/mcp` | A server's tools as this agent's tools; this agent as an MCP server (`chat`). |
| `moonkoog/a2a` | An agent as an A2A executor; a remote agent as one tool. |
| `moonkoog/acp` | An agent behind ACP: events become `session/update`, a stop becomes a refusal. |
| `moonkoog/rag` | Retrieval as a tool, and retrieval before every call. |
| `moonkoog/skills` | A skill listing in the instructions, a skill's body loaded on demand. |
| `moonkoog/serve` | The Agent Protocol's threads and runs, with routes for `moonapi`. |

## Observability

`moonkoog/otel` turns a run into the two signals a GenAI trace is made of: an `invoke_agent` span
with the tokens it spent, and an `execute_tool` span per call, with the attribute names from the
semantic conventions. The tracer is yours; the library never reads a clock of its own.

## Consistency

The test suite runs on all four targets. What it covers, and what it does not:

- The graph engine, the strategies, the middleware and the adapters are tested here, against
  scripted providers and the in-memory transports the protocol packages ship.
- The middleware's order, the interrupt-and-resume path, and the handover between team members are
  each covered by a test that fails when the mechanism is broken.
- Nothing here is tested against a live model provider: a key and a network are the caller's, and
  the scripted provider is what a run's own tests should use.

## License

Apache-2.0.
