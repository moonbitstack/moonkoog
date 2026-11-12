///|
/// One action of a goal-oriented plan: when it applies, what it changes, and what it costs.
///
/// A GOAP plan is searched over world states, so an action has to be a pure function of the
/// state it runs in — that is what lets the search try it without side effects.
pub(all) struct GoapAction[S] {
  name : String
  applies : (S) -> Bool
  effect : (S) -> S
  cost : (S) -> Double
}

///|
/// An action named `name` that applies when `applies`, produces `effect`, and costs 1 by
/// default.
pub fn[S] GoapAction::new(
  name~ : String,
  applies~ : (S) -> Bool,
  effect~ : (S) -> S,
  cost? : (S) -> Double,
) -> GoapAction[S] {
  {
    name,
    applies,
    effect,
    cost: match cost {
      Some(cost) => cost
      None => _state => 1.0
    },
  }
}

///|
/// What a plan is for: a test for "done", and an estimate of how far away that is.
pub(all) struct GoapGoal[S] {
  reached : (S) -> Bool
  estimate : (S) -> Double
}

///|
/// A goal with no estimate beyond "zero when reached" — Dijkstra's search instead of A*.
pub fn[S] GoapGoal::new(
  reached~ : (S) -> Bool,
  estimate? : (S) -> Double,
) -> GoapGoal[S] {
  {
    reached,
    estimate: match estimate {
      Some(estimate) => estimate
      None => state => if reached(state) { 0.0 } else { 1.0 }
    },
  }
}

///|
/// The least-cost sequence of action names that reaches `goal` from `start`, or `None` when no
/// sequence does.
///
/// The search is A* over the state space: the frontier is ordered by the cost so far plus the
/// goal's estimate, and a state reached more cheaply replaces the one recorded. A state is keyed
/// by the value itself, so the state type has to be comparable — for a world state that means a
/// record of flags or a small map, not a mutable object.
pub fn[S : Eq + Hash] search(
  actions : Array[GoapAction[S]],
  start : S,
  goal : GoapGoal[S],
) -> Array[String]? {
  let far_away = 1.0e18
  let so_far : Map[S, Double] = Map([])
  let through : Map[S, Double] = Map([])
  let previous : Map[S, (S, String)] = Map([])
  let frontier : Array[S] = [start]
  so_far[start] = 0.0
  through[start] = (goal.estimate)(start)
  while frontier.length() > 0 {
    let mut best = 0
    let mut index = 1
    while index < frontier.length() {
      if through.get(frontier[index]).unwrap_or(far_away) <
        through.get(frontier[best]).unwrap_or(far_away) {
        best = index
      }
      index = index + 1
    }
    let current = frontier[best]
    frontier.swap(best, frontier.length() - 1)
    frontier.unsafe_pop() |> ignore
    if (goal.reached)(current) {
      let names : Array[String] = []
      let mut node = current
      while previous.get(node) is Some((from, name)) {
        names.push(name)
        node = from
      }
      return Some(names.rev())
    }
    for action in actions {
      if !(action.applies)(current) {
        continue
      }
      let next = (action.effect)(current)
      let candidate = so_far.get(current).unwrap_or(far_away) +
        (action.cost)(current)
      if candidate < so_far.get(next).unwrap_or(far_away) {
        so_far[next] = candidate
        through[next] = candidate + (goal.estimate)(next)
        previous[next] = (current, action.name)
        frontier.push(next)
      }
    }
  }
  None
}
