// Floorp-managed, local-only readability adjustment. No network access or
// page-world execution is used; the native host controls site consent.
(() => {
  const root = document.documentElement;
  if (!root || root.dataset.floorpSiteAppearance === "1") return;
  root.dataset.floorpSiteAppearance = "1";
  root.classList.add("floorp-site-appearance");
})();
