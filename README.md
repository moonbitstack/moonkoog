<div align="center">

# moonkoog

**A MoonBit port of [JetBrains Koog](https://github.com/JetBrains/koog) — a type-safe agent-orchestration framework.**

[![Check and Test](https://github.com/moonbitstack/moonkoog/actions/workflows/ci.yml/badge.svg)](https://github.com/moonbitstack/moonkoog/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)

</div>

Koog is a Kotlin framework for building LLM agents: a prompt/message model, an
LLM-client contract, a tool registry, and an `AIAgent` that drives the
tool-calling loop. moonkoog transcribes it to MoonBit feature by feature, anchored
to Koog's `1.1.1` release. Where Kotlin leans on reflection (deriving a tool's
JSON schema from its argument type via `kotlinx.serialization` + a `TypeToken`),
MoonBit has none, so a tool states its schema through an explicit descriptor — the
same approach [moonapi](https://github.com/moonbitstack/moonapi) and
[moonctl](https://github.com/moonbitstack/moonctl) take. It is part of the **moon-heke**
full-stack suite and composes with it: an agent serves over
[moonapi](https://github.com/moonbitstack/moonapi)/[mooncat](https://github.com/moonbitstack/mooncat),
streams tokens over moonasgi SSE, and checkpoints to
[moonorm](https://github.com/moonbitstack/moonorm).

## What works today

The core loop, end to end. An `AIAgent` sends a prompt with the tools it may call,
runs whatever tools the model asks for, feeds the results back, and repeats until
the model answers in plain text — Koog's `singleRunStrategy`, bounded by
`maxIterations`.

```moonbit
// A tool: name + JSON-schema descriptor, and a body that runs on decoded args.
struct Add {}
impl @tools.Tool for Add with descriptor(_) {
  {
    name: "add",
    description: "add two integers a and b",
    required_parameters: [
      { name: "a", description: "first", ptype: @tools.TInteger },
      { name: "b", description: "second", ptype: @tools.TInteger },
    ],
    optional_parameters: [],
  }
}
impl @tools.Tool for Add with execute_raw(_, args) { /* a + b */ ... }

// An agent over any LLM client (a scripted MockClient in tests; the real
// DeepSeek/OpenAI-compatible client rides moonllm — see the roadmap).
let agent = @agent.AIAgent::new(
  client,
  model=@llm.deepseek_v4_flash,
  tool_registry=@tools.ToolRegistry::new().add(Add::{}),
)
let answer = agent.run("what is 2 + 3?")   // -> the model's final text
```

## The chain

| Koog concern | Koog module (`1.1.1`) | moonkoog |
|---|---|---|
| Message / Prompt / PromptBuilder | `prompt-model` | `prompt/` |
| LLModel / LLMProvider / LLMCapability | `prompt-llm` | `llm/` |
| Tool / ToolDescriptor / ToolRegistry | `agents-tools` | `tools/` |
| LLMClient contract, AIAgent, singleRunStrategy | `prompt-executor-clients`, `agents-core` | `agent/` |

The LLM client is a `pub(open) trait` — bring your own. A scripted `MockClient`
ships for deterministic tests; the real transport reuses
[`DC-Z-lab/moonllm`](https://github.com/DC-Z-lab/moonllm) (native
`moonbitlang/async` + TLS + SSE + tool-calling) behind moonkoog's own client
interface.

## Roadmap

Transcription tracks Koog `1.1.1` module by module. Landed: the prompt model, the
model catalog, the tool/registry model, the `AIAgent` tool-calling loop, and the
strategy graph it is one wiring of — nodes, edges with arbitrary conditions and
transforms, nested subgraphs, and parallel nodes; per-agent `LLMParams`, native
structured output, a typed per-run store, node-boundary checkpointing with resume,
and a retry with backoff and error classification. The event pipeline covers the
agent, strategy, subgraph, node, LLM, streaming and tool hooks — including the
failure ones — and the LLM and tool hooks come in an intercepting form that can
rewrite the prompt, the reply, a tool's arguments or its result; `Tracing` renders
all of them to a `TraceWriter`, and a reply carries the tokens the provider charged
as `ResponseMetaInfo`. Next: multi-provider executors, memory, an OpenTelemetry
exporter, and the `a2a` / `rag` / MCP layers — plus the moon-heke integration
(serving).

## Build

```console
$ moon check --target all --deny-warn
$ moon test --target all      # pure packages on every backend; the agent loop on native
```

## License

Apache-2.0.
