browser.runtime.onMessage.addListener(async message => {
  if (message?.type !== "floorp-session-timer-start") return undefined;
  const minutes = Math.max(1, Math.min(120, Number(message.minutes) || 25));
  await browser.storage.local.set({ startedAt: Date.now(), minutes });
  await browser.alarms.create("floorp-session-timer", { delayInMinutes: minutes });
  return { scheduled: true, minutes };
});

browser.alarms.onAlarm.addListener(async alarm => {
  if (alarm.name === "floorp-session-timer") {
    await browser.storage.local.set({ completedAt: Date.now() });
  }
});
