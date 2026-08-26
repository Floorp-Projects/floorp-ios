const status = document.querySelector("#status");
const feedLink = document.querySelector("#feed");

browser.storage.local.get([
  "floorpEasyToRSSLastFeedURL",
  "floorpEasyToRSSLastPageOrigin"
]).then(values => {
  const feed = values.floorpEasyToRSSLastFeedURL;
  if (!feed) return;
  status.textContent = "Feed discovered on " + (values.floorpEasyToRSSLastPageOrigin || "this profile") + ".";
  feedLink.href = feed;
  feedLink.hidden = false;
}).catch(() => {
  status.textContent = "Local feed summary is unavailable.";
});
