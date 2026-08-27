const status = document.querySelector("#status");
const render = values => {
  const count = Number(values.floorpTrackingTokenStripperCount || 0);
  const origin = values.floorpTrackingTokenStripperLastURL || "no site";
  status.textContent = count
    ? String(count) + " tracking token" + (count === 1 ? "" : "s")
      + " removed locally. Last site: " + origin + "."
    : "No tracking tokens removed in this profile yet.";
};

browser.storage.local.get([
  "floorpTrackingTokenStripperCount",
  "floorpTrackingTokenStripperLastURL"
]).then(render).catch(() => {
  status.textContent = "Local summary is unavailable.";
});

document.querySelector("#reset")?.addEventListener("click", async () => {
  await browser.storage.local.set({
    floorpTrackingTokenStripperCount: 0,
    floorpTrackingTokenStripperLastURL: ""
  });
  render({});
});
