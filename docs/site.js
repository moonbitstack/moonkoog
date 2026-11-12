// Two small behaviours: the page scrollbar's thumb appears once the page leaves the top, and the
// theme toggle remembers the choice for the visit but follows the system again on the next one.

const root = document.documentElement;
const mark = () => root.classList.toggle("at-top", window.scrollY === 0);
window.addEventListener("scroll", mark, { passive: true });
mark();

const button = document.getElementById("theme");
const system = () => (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
const apply = (choice) => {
  if (choice === "system") {
    root.removeAttribute("data-theme");
  } else {
    root.setAttribute("data-theme", choice);
  }
  if (button) button.textContent = "theme: " + choice;
};

apply(sessionStorage.getItem("moonkoog-theme") || "system");
if (button) {
  button.addEventListener("click", () => {
    const current = sessionStorage.getItem("moonkoog-theme") || "system";
    const next = current === "system" ? (system() === "dark" ? "light" : "dark") : current === "dark" ? "light" : "system";
    sessionStorage.setItem("moonkoog-theme", next);
    apply(next);
  });
}

for (const block of document.querySelectorAll(".install")) {
  const target = block.querySelector("code");
  const copy = block.querySelector(".copy");
  if (!target || !copy) continue;
  copy.addEventListener("click", async () => {
    await navigator.clipboard.writeText(target.textContent.trim());
    copy.textContent = "copied";
    copy.classList.add("ok");
    setTimeout(() => {
      copy.textContent = "copy";
      copy.classList.remove("ok");
    }, 1200);
  });
}
