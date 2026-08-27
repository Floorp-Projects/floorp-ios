// Local feed discovery subset derived from idealclover/Easy-to-RSS.
(() => {
  if (document.querySelector("#floorp-easy-rss")) return;
  const feed = [...document.querySelectorAll('link[type="application/rss+xml"], link[type="application/atom+xml"]')]
    .map(link => link.href).find(Boolean);
  if (!feed) return;
  const notice = document.createElement("aside"); notice.id = "floorp-easy-rss";
  notice.setAttribute("role", "status");
  const link = document.createElement("a"); link.href = feed; link.textContent = "RSS feed available";
  notice.append(link); document.body.append(notice);

  // Keep the last locally discovered feed in this profile only. The popup
  // receives the page-declared feed URL; there is no fetch, subscription, or
  // external RSS service in this compatibility build.
  globalThis.browser?.storage?.local?.set({
    floorpEasyToRSSLastFeedURL: feed,
    floorpEasyToRSSLastPageOrigin: location.origin
  }).catch(() => {});
})();
