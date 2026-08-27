// Derived from jparise/chrome-utm-stripper's token categories. The upstream
// webRequest blocker is deliberately replaced with a static document/link
// sanitizer because Floorp iOS does not expose webRequestBlocking.
(() => {
  const tracked = /^(utm_[a-z0-9_]+|gclid|dclid|fbclid|mc_[a-z]+|_hs[a-z]+)$/i;
  let strippedCount = 0;
  const clean = value => {
    try {
      const url = new URL(value, location.href);
      let changed = false;
      for (const key of [...url.searchParams.keys()]) {
        if (tracked.test(key)) { url.searchParams.delete(key); changed = true; }
      }
      if (changed) strippedCount += 1;
      return changed ? url.href : value;
    } catch { return value; }
  };
  const replaceCurrent = clean(location.href);
  if (replaceCurrent !== location.href) history.replaceState(history.state, "", replaceCurrent);
  const cleanLinks = root => root.querySelectorAll?.("a[href]").forEach(link => {
    const next = clean(link.href);
    if (next !== link.href) link.href = next;
  });
  cleanLinks(document);
  new MutationObserver(records => records.forEach(record => record.addedNodes.forEach(node => {
    if (node.nodeType === Node.ELEMENT_NODE) cleanLinks(node);
  }))).observe(document.documentElement, { childList: true, subtree: true });

  // The popup receives only a local, profile-scoped summary. It never sees
  // page content or sends history to a network endpoint.
  const storage = globalThis.browser?.storage?.local;
  if (storage && strippedCount > 0) {
    storage.get(["floorpTrackingTokenStripperCount"]).then(values => storage.set({
      floorpTrackingTokenStripperCount:
        Number(values.floorpTrackingTokenStripperCount || 0) + strippedCount,
      floorpTrackingTokenStripperLastURL: location.origin
    })).catch(() => {});
  }
})();
