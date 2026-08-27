(() => {
  const root = document.documentElement;
  if (!root || root.dataset.floorpMinimalTwitter) return;
  root.dataset.floorpMinimalTwitter = "1";
  document.addEventListener("keydown", event => {
    if (event.key === "Escape") document.activeElement?.blur?.();
  }, { capture: true });
})();
