browser.storage.local.get(["activationCount"]).then(({ activationCount = 0 }) => {
  document.querySelector("#status").textContent = `Activations: ${activationCount}`;
});
