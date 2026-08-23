const enabled = document.querySelector("#enabled");
browser.storage.local.get(["alarmEnabled"]).then((value) => {
  enabled.checked = value.alarmEnabled === true;
});
enabled.addEventListener("change", () => {
  browser.storage.local.set({ alarmEnabled: enabled.checked });
});
