(() => {
  document.querySelectorAll(".titleline > a").forEach((link, index) => {
    link.dataset.floorpHnRank = String(index + 1);
    link.setAttribute("aria-label", `${index + 1}. ${link.textContent?.trim() || "story"}`);
  });
  document.addEventListener("keydown", event => {
    if (event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement) return;
    const links = [...document.querySelectorAll(".titleline > a")];
    const current = links.indexOf(document.activeElement);
    if (event.key === "j" && links.length) { event.preventDefault(); links[Math.min(links.length - 1, current + 1)].focus(); }
    if (event.key === "k" && links.length) { event.preventDefault(); links[Math.max(0, current - 1)].focus(); }
  });
})();
