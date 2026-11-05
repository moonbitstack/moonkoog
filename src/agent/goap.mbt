// Goal-Oriented Action Planning (Koog agents-planner `goap`): an A* search over world states
// for the least-cost sequence of actions that reaches a goal. Each action has a precondition
// (when it applies), an effect (the state it believes it produces), and a cost; the goal has a
// satisfaction test and a heuristic estimate of the remaining cost. `goap_plan` returns the
// action names in order, or `None` when no plan reaches the goal.

///|
/// An action: its name, when it applies, the state it produces, and its cost.
pub(all) struct GoapAction[S] {
  name : String
  precondition : (S) -> Bool
  effect : (S) -> S
  cost : (S) -> Double
}

///|
/// A goal: whether a state satisfies it, and a heuristic estimate of the cost still to go.
pub(all) struct GoapGoal[S] {
  satisfied : (S) -> Bool
  heuristic : (S) -> Double
}

///|
/// Plan the least-cost action-name sequence from `initial` to a state satisfying `goal` with
/// A* over the state space, or `None` when the goal is unreachable.
pub fn[S : Eq + Hash] goap_plan(
  actions : Array[GoapAction[S]],
  initial : S,
  goal : GoapGoal[S],
) -> Array[String]? {
  let inf = 1.0e18
  let g_score : Map[S, Double] = Map([])
  let f_score : Map[S, Double] = Map([])
  let incoming : Map[S, (S, String)] = Map([])
  let open_set : Array[S] = [initial]
  g_score[initial] = 0.0
  f_score[initial] = (goal.heuristic)(initial)
  while open_set.length() > 0 {
    // Take the frontier state with the lowest f-score.
    let mut best = 0
    for i in 1..<open_set.length() {
      if f_score.get(open_set[i]).unwrap_or(inf) <
        f_score.get(open_set[best]).unwrap_or(inf) {
        best = i
      }
    }
    let current = open_set[best]
    open_set.swap(best, open_set.length() - 1)
    open_set.unsafe_pop() |> ignore
    if (goal.satisfied)(current) {
      let names : Array[String] = []
      let mut node = current
      while incoming.get(node) is Some((from, name)) {
        names.push(name)
        node = from
      }
      return Some(names.rev())
    }
    for action in actions {
      if (action.precondition)(current) {
        let next = (action.effect)(current)
        let tentative = g_score.get(current).unwrap_or(inf) +
          (action.cost)(current)
        if tentative < g_score.get(next).unwrap_or(inf) {
          g_score[next] = tentative
          f_score[next] = tentative + (goal.heuristic)(next)
          incoming[next] = (current, action.name)
          open_set.push(next)
        }
      }
    }
  }
  None
}
