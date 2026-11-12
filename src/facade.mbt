///|
/// The agent: what a run is, what it is configured with, and how it is started.
pub using @agent {
  type Agent,
  type AgentConfig,
  type AgentError,
  type AgentState,
  type Event,
  type EventHandler,
  type Limits,
  trait Middleware,
  type ModelOutcome,
  type NodeKind,
  type Options,
  type RequestMode,
  type RunContext,
  type Strategy,
  type ToolOutcome,
  type ToolSpec,
  type Tools,
  type Update,
  create_agent,
  default_limits,
  default_options,
  describe,
  single_run,
  chat,
  react,
  answer_only,
}

///|
/// The built-in middleware. Each one is a type here and a value with `new` on it.
pub using @middleware {
  type ContextEditing,
  type EditingStrategy,
  type FileSearch,
  type HumanInTheLoop,
  type ModelCallLimit,
  type ModelFallback,
  type ModelRetry,
  type Pii,
  type PiiRule,
  type ShellTool,
  type Summarization,
  type TodoList,
  type ToolCallLimit,
  type ToolRetry,
  type ToolSelection,
}

///|
/// Planning: the goal-oriented search, and the plan-and-execute strategy.
pub using @plan {type GoapAction, type GoapGoal, plan_and_execute, search}

///|
/// Teams: members handing the conversation to each other, or a supervisor choosing.
pub using @multi {handoff_tool, supervisor, swarm}

///|
/// The tools this module ships.
pub using @tools {calculator}
