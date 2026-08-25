(() => {
  window.dispatchEvent(new CustomEvent("floorp-mv3-page-world", {
    detail: { fixture: "demanding-mv3", isolatedBridgeExposed: false }
  }));
})();
