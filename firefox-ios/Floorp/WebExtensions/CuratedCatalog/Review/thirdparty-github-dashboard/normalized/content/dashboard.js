// Local filtering subset inspired by muan/github-dashboard. It never contacts
// the GitHub API and works only with dashboard content already on the page.
(() => {
  const list = document.querySelector("main") || document.body;
  if (!list || document.querySelector("#floorp-dashboard-filter")) return;
  const input = document.createElement("input");
  input.id = "floorp-dashboard-filter"; input.className = "floorp-dashboard-filter";
  input.type = "search"; input.placeholder = "Filter this GitHub dashboard";
  input.setAttribute("aria-label", "Filter this GitHub dashboard");
  input.addEventListener("input", () => {
    const query = input.value.trim().toLowerCase();
    list.querySelectorAll("article, .Box-row, .dashboard-rollup-item").forEach(item => {
      item.classList.toggle("floorp-dashboard-muted", Boolean(query) && !item.textContent.toLowerCase().includes(query));
    });
  });
  list.prepend(input);
})();
