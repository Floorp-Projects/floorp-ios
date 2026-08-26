// Local fork-list filtering derived from useful-forks/useful-forks.github.io.
(() => {
  const heading = [...document.querySelectorAll("h1, h2")].find(node => /fork/i.test(node.textContent || ""));
  const container = heading?.parentElement || document.querySelector("main");
  if (!container || document.querySelector("#floorp-useful-forks-filter")) return;
  const input = document.createElement("input");
  input.id = "floorp-useful-forks-filter"; input.className = "floorp-useful-forks-filter";
  input.type = "search"; input.placeholder = "Filter forks on this page";
  input.setAttribute("aria-label", "Filter forks on this page");
  input.addEventListener("input", () => {
    const query = input.value.toLowerCase();
    document.querySelectorAll("li, .Box-row").forEach(row => {
      const relevant = row.querySelector("a[href*='/']");
      if (relevant) row.classList.toggle("floorp-useful-forks-hidden", Boolean(query) && !row.textContent.toLowerCase().includes(query));
    });
  });
  container.prepend(input);
})();
