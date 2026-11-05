// GOAP plans the least-cost action sequence to reach a goal over a small world.

///|
struct World {
  has_axe : Bool
  has_wood : Bool
  has_house : Bool
} derive(Eq, Hash)

///|
test "goap: plans get_axe then chop_wood then build_house to reach the goal" {
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
  let initial = World::{ has_axe: false, has_wood: false, has_house: false, }
  let plan = @agent.goap_plan([get_axe, chop_wood, build_house], initial, goal)
  assert_eq(plan, Some(["get_axe", "chop_wood", "build_house"]))
}
