// The tour: play a recorded run back onto the graph.
//
// The recording is made by `src/examples/browser` from a real run's event stream and written to
// `engine/tour.json` on every deploy. This file only places the steps on the diagram — it knows
// nothing about how a run works, so it cannot show a walk the library did not take.

const stage = document.getElementById("stage");
const log = document.getElementById("log");
const note = document.getElementById("note");
const count = document.getElementById("count");
const ask = document.getElementById("ask");
const toolStrip = document.getElementById("tools-run");
const answerBox = document.getElementById("answer");
const answerText = document.getElementById("answer-text");
const buttons = [...document.querySelectorAll("[data-scenario]")];
const replay = document.getElementById("replay");

const nodes = new Map(
  [...document.querySelectorAll("[data-node]")].map((el) => [el.dataset.node, el])
);
const edges = new Map(
  [...document.querySelectorAll("[data-edge]")].map((el) => [el.dataset.edge, el])
);

const calm = matchMedia("(prefers-reduced-motion: reduce)").matches;
const BEAT = calm ? 0 : 260;
const HOLD = calm ? 0 : 520;

let scenarios = [];
let timers = [];
let current = null;

const stop = () => {
  for (const timer of timers) clearTimeout(timer);
  timers = [];
};

const clear = () => {
  stop();
  for (const node of nodes.values()) node.classList.remove("on", "done", "bad");
  for (const edge of edges.values()) edge.classList.remove("on");
  log.replaceChildren();
  toolStrip.replaceChildren();
  ask.textContent = "";
  answerBox.hidden = true;
  answerText.textContent = "";
  count.textContent = "";
};

const line = (kind, name, detail) => {
  const row = document.createElement("div");
  row.className = "tour-line";
  const k = document.createElement("span");
  k.className = "k " + kind;
  k.textContent = kind;
  const body = document.createElement("span");
  body.className = "body";
  const strong = document.createElement("b");
  strong.textContent = name;
  body.append(strong);
  if (detail) {
    body.append(document.createTextNode("  " + detail));
  }
  row.append(k, body);
  log.append(row);
  log.scrollTop = log.scrollHeight;
};

// The walk a step implies: leaving one node and entering the next is the edge between them.
const edgeOf = (steps, index) => {
  const step = steps[index];
  if (step.kind !== "enter" || index === 0) return null;
  const before = steps[index - 1];
  if (before.kind !== "leave") return null;
  return edges.get(before.name + ">" + step.name) || null;
};

const play = (scenario) => {
  clear();
  current = scenario;
  note.textContent = scenario.note;
  ask.textContent = scenario.input || "";
  for (const button of buttons) {
    button.setAttribute("aria-pressed", String(button.dataset.scenario === scenario.id));
  }

  const steps = scenario.run.steps;
  const total = steps.length;
  const last = steps[total - 1];
  count.textContent = "0/" + total;

  steps.forEach((step, index) => {
    const at = index * BEAT;
    timers.push(
      setTimeout(() => {
        const node = nodes.get(step.name);
        if (step.kind === "enter") {
          // One position is current at a time: the walk moves, it does not accumulate.
          for (const other of nodes.values()) other.classList.remove("on");
          if (node) node.classList.add("on");
          line("enter", step.name, "");
        } else if (step.kind === "leave") {
          if (node) node.classList.add("done");
          line("leave", step.name, "");
        } else if (step.kind === "tool") {
          if (node) {
            node.classList.add("on");
            timers.push(setTimeout(() => node.classList.remove("on"), BEAT));
          }
          line("tool", step.name, step.detail === "failed" ? "failed" : "");
          const call = document.createElement("span");
          call.className = "chip" + (step.detail === "failed" ? " bad" : "");
          call.textContent = step.name;
          toolStrip.append(call);
          if (step.detail === "failed") {
            if (node) node.classList.add("bad");
          }
        } else if (step.kind === "model") {
          line("model", step.name, step.detail || "");
        } else if (step.kind === "answer") {
          line("answer", "answer", "");
          answerText.textContent = step.detail;
          answerBox.hidden = false;
        } else if (step.kind === "stop") {
          line("stop", "stopped", step.detail);
          if (node) node.classList.add("bad");
        }

        const edge = edgeOf(steps, index);
        if (edge) {
          edge.classList.add("on");
          timers.push(setTimeout(() => edge.classList.remove("on"), BEAT * 2));
        }
        count.textContent = index + 1 + "/" + total;
      }, at)
    );
  });

  if (last && last.kind !== "answer" && last.kind !== "stop") {
    timers.push(
      setTimeout(() => {
        line("end", "end of recording", "");
      }, total * BEAT + HOLD)
    );
  }
};

const offline = () => {
  note.textContent =
    "The recording is built with the site. Run the docs build (or open this page from a deployed copy) to see a run.";
  count.textContent = "";
  log.replaceChildren();
  const row = document.createElement("div");
  row.className = "tour-line";
  row.textContent = "engine/tour.json is not here";
  log.append(row);
  for (const button of buttons) button.disabled = true;
  if (replay) replay.disabled = true;
};

const start = async () => {
  try {
    const response = await fetch("engine/tour.json", { cache: "no-store" });
    if (!response.ok) throw new Error(String(response.status));
    const document_ = await response.json();
    scenarios = document_.scenarios || [];
    if (!scenarios.length) throw new Error("no scenarios");
  } catch (error) {
    offline();
    return;
  }
  for (const button of buttons) {
    button.addEventListener("click", () => {
      const found = scenarios.find((one) => one.id === button.dataset.scenario);
      if (found) play(found);
    });
  }
  if (replay) {
    replay.addEventListener("click", () => {
      if (current) play(current);
    });
  }
  play(scenarios[0]);
};

// A scenario can be linked to directly: tour.html#tool opens on it.
const wanted = location.hash.replace("#", "");
start().then(() => {
  if (!wanted) return;
  const found = scenarios.find((one) => one.id === wanted);
  if (found) play(found);
});
