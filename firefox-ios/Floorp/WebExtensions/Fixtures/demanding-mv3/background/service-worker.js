const fixtureState = new Map();

browser.runtime.onMessage.addListener((message, sender) => {
  if (message?.type !== "floorp-fixture-ping") {
    return undefined;
  }

  const key = `${sender.tab?.id ?? "worker"}:${message.documentGeneration ?? 0}`;
  fixtureState.set(key, Date.now());
  return Promise.resolve({ accepted: true, key });
});
