const quiet = document.querySelector("#quiet");
browser.storage.local.get(["quiet"]).then(({ quiet: value }) => { quiet.checked = Boolean(value); });
quiet?.addEventListener("change", () => browser.storage.local.set({ quiet: quiet.checked }));
