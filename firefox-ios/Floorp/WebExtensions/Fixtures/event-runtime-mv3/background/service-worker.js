// This source documents the MV3 behavior exercised by the fixture. Floorp iOS
// does not evaluate arbitrary worker JavaScript: the compatibility harness
// binds these events to the reviewed native-backed lazy event runtime.
browser.runtime.onMessage.addListener(async (message) => {
  if (message?.type !== "floorp-event-runtime-ping") {
    return undefined;
  }
  const result = await browser.storage.local.get(["activationCount"]);
  const activationCount = (result.activationCount ?? 0) + 1;
  await browser.storage.local.set({ activationCount });
  return { accepted: true, activationCount };
});

browser.alarms.onAlarm.addListener(async (alarm) => {
  await browser.storage.local.set({ lastAlarm: alarm.name });
});
