name = "moonbitstack/moonkoog"

version = "0.6.0"

readme = "README.md"

repository = "https://github.com/moonbitstack/moonkoog"

license = "Apache-2.0"

keywords = [ "koog", "agent", "llm", "tool-calling", "moonbit" ]

description = "moonkoog — a MoonBit port of JetBrains Koog (1.1.1): a type-safe agent-orchestration framework. The prompt/message model, LLM client contract, tool registry with a JSON-schema descriptor model, and the AIAgent tool-calling loop (Koog's singleRunStrategy), built to compose with the moonbitstack full-stack suite."

import {
  "moonbitstack/moonpool@0.2.0",
  "moonbitstack/moonhttp@0.9.0",
  "moonbitstack/moondate@0.1.0",
  "moonbitlang/async@0.20.3",
  "DC-Z-lab/moonllm@0.1.0",
}
