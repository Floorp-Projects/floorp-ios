(() => {
  const marker = "data-floorp-mv3-document-start";
  document.documentElement?.setAttribute(marker, "true");
  browser.runtime.sendMessage({
    type: "floorp-fixture-ping",
    documentGeneration: performance.timeOrigin
  }).catch(() => {});
})();
