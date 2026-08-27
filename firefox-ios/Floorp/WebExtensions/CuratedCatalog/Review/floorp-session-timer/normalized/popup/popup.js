const status = document.querySelector("#status");
document.querySelector("#start")?.addEventListener("click", async () => {
  const minutes = document.querySelector("#minutes")?.value;
  const result = await browser.runtime.sendMessage({ type: "floorp-session-timer-start", minutes });
  status.textContent = result?.scheduled ? `Timer started for ${result.minutes} minutes.` : "Timer was not started.";
});
