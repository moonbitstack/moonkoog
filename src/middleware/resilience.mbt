///|
/// Wait `ms` milliseconds. A sleeping call is the one place a middleware needs the runtime's
/// timer, and a target without one simply does not wait.
async fn pause(ms : Int32) -> Unit {
  if ms <= 0 {
    return
  }
  let sleeper : async (Int32) -> Unit = ms => @async.sleep(ms)
  sleeper(ms) catch {
    _ => ()
  }
}

///|
/// The delay before attempt `attempt`, counting from one: the base, multiplied by the factor once
/// per attempt already made, capped so a long streak does not wait for hours.
fn delay_for(
  base_ms : Int32,
  factor : Double,
  attempt : Int32,
  cap_ms : Int32,
) -> Int32 {
  let mut value = base_ms.to_double()
  let mut index = 1
  while index < attempt {
    value = value * factor
    index = index + 1
  }
  if value > cap_ms.to_double() {
    cap_ms
  } else {
    value.to_int()
  }
}

///|
/// Retry a model call that failed in a way the provider itself calls retryable: a rate limit, a
/// gateway error, a timeout. A rejected request is not retried, because the same request would be
/// rejected again.
pub struct ModelRetry {
  attempts : Int32
  base_ms : Int32
  factor : Double
  cap_ms : Int32
}

///|
/// Retry up to `attempts` times, waiting the base delay and then growing it by the factor.
pub fn ModelRetry::new(
  attempts~ : Int32 = 3,
  base_ms~ : Int32 = 200,
  factor~ : Double = 2.0,
  cap_ms~ : Int32 = 10_000,
) -> ModelRetry {
  { attempts, base_ms, factor, cap_ms, }
}

///|
pub extend ModelRetry with @agent.Middleware::{
  name,
  install,
  before_agent,
  wrap_model,
  wrap_tool,
  after_agent,
}

///|
pub impl @agent.Middleware for ModelRetry with fn name(_self) {
  "model_retry"
}

///|
pub impl @agent.Middleware for ModelRetry with fn install(_self, _tools) {
  ()
}

///|
pub impl @agent.Middleware for ModelRetry with fn before_agent(_self, _context) {
  []
}

///|
pub impl @agent.Middleware for ModelRetry with fn wrap_model(
  self,
  _context,
  call,
  next,
) {
  let mut attempt = 1
  while true {
    let outcome = next(call)
    match outcome {
      @agent.ModelOutcome::Failed(retryable~, ..) =>
        if !retryable || attempt >= self.attempts {
          return outcome
        } else {
          pause(delay_for(self.base_ms, self.factor, attempt, self.cap_ms))
          attempt = attempt + 1
        }
      _ => return outcome
    }
  }
  abort("unreachable")
}

///|
pub impl @agent.Middleware for ModelRetry with fn wrap_tool(
  _self,
  _context,
  call,
  next,
) {
  next(call)
}

///|
pub impl @agent.Middleware for ModelRetry with fn after_agent(
  _self,
  _context,
  _state,
) {
  []
}

///|
/// Retry a tool call that failed. Whether a failure is worth another attempt is the tool's
/// business — a network read is, a rejected argument is not — so the policy looks at the reason
/// the tool gave and retries everything unless told otherwise.
pub struct ToolRetry {
  attempts : Int32
  base_ms : Int32
  factor : Double
  cap_ms : Int32
}

///|
/// Retry up to `attempts` times with the same growth as a model retry.
pub fn ToolRetry::new(
  attempts~ : Int32 = 2,
  base_ms~ : Int32 = 100,
  factor~ : Double = 2.0,
  cap_ms~ : Int32 = 5_000,
) -> ToolRetry {
  { attempts, base_ms, factor, cap_ms, }
}

///|
pub extend ToolRetry with @agent.Middleware::{
  name,
  install,
  before_agent,
  wrap_model,
  wrap_tool,
  after_agent,
}

///|
pub impl @agent.Middleware for ToolRetry with fn name(_self) {
  "tool_retry"
}

///|
pub impl @agent.Middleware for ToolRetry with fn install(_self, _tools) {
  ()
}

///|
pub impl @agent.Middleware for ToolRetry with fn before_agent(_self, _context) {
  []
}

///|
pub impl @agent.Middleware for ToolRetry with fn wrap_model(
  _self,
  _context,
  call,
  next,
) {
  next(call)
}

///|
pub impl @agent.Middleware for ToolRetry with fn wrap_tool(
  self,
  _context,
  call,
  next,
) {
  let mut attempt = 1
  while true {
    let outcome = next(call)
    match outcome {
      @agent.ToolOutcome::Failed(_) =>
        if attempt >= self.attempts {
          return outcome
        } else {
          pause(delay_for(self.base_ms, self.factor, attempt, self.cap_ms))
          attempt = attempt + 1
        }
      _ => return outcome
    }
  }
  abort("unreachable")
}

///|
pub impl @agent.Middleware for ToolRetry with fn after_agent(
  _self,
  _context,
  _state,
) {
  []
}

///|
/// One alternative to fall back to: another provider, another model, or both.
pub(all) struct Fallback {
  provider : &@moonmuse.Provider
  model : String
}

///|
/// A fallback to `model` on `provider`.
pub fn Fallback::new(
  provider : &@moonmuse.Provider,
  model : String,
) -> Fallback {
  { provider, model, }
}

///|
/// Try the alternatives in order when the primary model call fails.
///
/// The order is the point: a smaller local model first, a larger one second, and the primaries'
/// own retry policy already applied inside. Fallbacks call their provider directly — a fallback
/// is a different endpoint, not the same one with different arguments — so the middleware inside
/// them is skipped deliberately.
pub struct ModelFallback {
  entries : Array[Fallback]
}

///|
/// Fall back to `entries` in order.
pub fn ModelFallback::new(entries : Array[Fallback]) -> ModelFallback {
  { entries, }
}

///|
pub extend ModelFallback with @agent.Middleware::{
  name,
  install,
  before_agent,
  wrap_model,
  wrap_tool,
  after_agent,
}

///|
pub impl @agent.Middleware for ModelFallback with fn name(_self) {
  "model_fallback"
}

///|
pub impl @agent.Middleware for ModelFallback with fn install(_self, _tools) {
  ()
}

///|
pub impl @agent.Middleware for ModelFallback with fn before_agent(
  _self,
  _context,
) {
  []
}

///|
pub impl @agent.Middleware for ModelFallback with fn wrap_model(
  self,
  _context,
  call,
  next,
) {
  let outcome = next(call)
  match outcome {
    @agent.ModelOutcome::Failed(..) => {
      for entry in self.entries {
        let request = { ..call.request, model: entry.model, }
        let asked = Ok(entry.provider.chat(request)) catch {
          error => Err(error)
        }
        match asked {
          Ok(reply) => return @agent.ModelOutcome::Replied(reply)
          Err(_) => continue
        }
      }
      outcome
    }
    other => other
  }
}

///|
pub impl @agent.Middleware for ModelFallback with fn wrap_tool(
  _self,
  _context,
  call,
  next,
) {
  next(call)
}

///|
pub impl @agent.Middleware for ModelFallback with fn after_agent(
  _self,
  _context,
  _state,
) {
  []
}
