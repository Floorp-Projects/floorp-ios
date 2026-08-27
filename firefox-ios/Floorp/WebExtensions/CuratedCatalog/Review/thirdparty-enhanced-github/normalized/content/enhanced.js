// Fixed DOM enhancement inspired by softvar/enhanced-github.
(() => {
  if (document.documentElement.dataset.floorpEnhancedGithub) return;
  document.documentElement.dataset.floorpEnhancedGithub = "1";
  document.querySelectorAll("a[href*='/blob/'], a[href*='/tree/']").forEach(link => {
    if (link.querySelector(".floorp-github-path")) return;
    const path = link.getAttribute("href")?.split("/").slice(5).join("/");
    if (!path) return;
    const label = document.createElement("span"); label.className = "floorp-github-path"; label.textContent = path;
    link.append(" ", label);
  });
})();
