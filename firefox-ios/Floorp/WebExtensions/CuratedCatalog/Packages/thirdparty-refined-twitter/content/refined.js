(() => {
  const annotate = () => document.querySelectorAll('[data-testid="tweet"]').forEach(tweet => {
    if (!tweet.hasAttribute("data-floorp-refined")) tweet.setAttribute("data-floorp-refined", "true");
  });
  annotate();
  new MutationObserver(annotate).observe(document.documentElement, { childList: true, subtree: true });
})();
