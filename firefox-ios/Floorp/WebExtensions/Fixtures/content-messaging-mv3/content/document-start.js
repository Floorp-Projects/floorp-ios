(() => {
  document.documentElement?.setAttribute("data-floorp-content-message", "ready");
  browser.runtime.sendMessage({
    type: "floorp-content-message-ready",
    location: location.origin
  }).then((reply) => {
    document.documentElement?.setAttribute(
      "data-floorp-content-message-reply",
      reply?.accepted === true ? "accepted" : "rejected"
    );
  }).catch(() => {
    document.documentElement?.setAttribute("data-floorp-content-message-reply", "unavailable");
  });
})();
