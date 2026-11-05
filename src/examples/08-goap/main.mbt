///|
/// A tiny world state the planner searches over.
struct World {
  has_axe : Bool
  has_wood : Bool
  has_house : Bool
} derive(Eq, Hash)

///|
/// Goal-oriented action planning (Koog's GOAP): from a start state and a set of
/// actions — each a precondition, an effect, and a cost — find the least-cost
/// sequence that satisfies the goal. This is pure search, no model in the loop, so
/// it runs synchronously and deterministically.
///
///     moon run examples/17-goap --target native
#coverage.skip
fn main {
  let get_axe : @agent.GoapAction[World] = {
    name: "get_axe",
    precondition: _s => true,
    effect: s => { ..s, has_axe: true, },
    cost: _s => 1.0,
  }
  let chop_wood : @agent.GoapAction[World] = {
    name: "chop_wood",
    precondition: s => s.has_axe,
    effect: s => { ..s, has_wood: true, },
    cost: _s => 1.0,
  }
  let build_house : @agent.GoapAction[World] = {
    name: "build_house",
    precondition: s => s.has_wood,
    effect: s => { ..s, has_house: true, },
    cost: _s => 1.0,
  }
  let goal : @agent.GoapGoal[World] = {
    satisfied: s => s.has_house,
    heuristic: s => if s.has_house { 0.0 } else { 1.0 },
  }
  let start = World::{ has_axe: false, has_wood: false, has_house: false, }
  match @agent.goap_plan([get_axe, chop_wood, build_house], start, goal) {
    Some(plan) => println("plan: " + plan.join(" -> "))
    None => println("no plan reaches the goal")
  }

  // With the axe already in hand, the planner skips the first action.
  let armed = World::{ has_axe: true, has_wood: false, has_house: false, }
  match @agent.goap_plan([get_axe, chop_wood, build_house], armed, goal) {
    Some(plan) => println("from armed: " + plan.join(" -> "))
    None => println("no plan reaches the goal")
  }
}
