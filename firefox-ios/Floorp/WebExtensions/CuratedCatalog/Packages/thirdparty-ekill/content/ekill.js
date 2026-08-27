// Derived from rhardih/ekill's local element-selection interaction. Press
// Alt+Shift+K to hide the currently highlighted element, then Alt+Shift+U to
// restore it. Nothing is sent off-device or persisted.
(() => {
  let target = null;
  let hidden = [];
  document.addEventListener("pointerover", event => {
    target?.classList.remove("floorp-ekill-hover");
    target = event.target instanceof Element ? event.target : null;
    target?.classList.add("floorp-ekill-hover");
  }, true);
  document.addEventListener("keydown", event => {
    if (!event.altKey || !event.shiftKey) return;
    if (event.key.toLowerCase() === "k" && target && target !== document.body) {
      event.preventDefault(); target.classList.remove("floorp-ekill-hover");
      target.classList.add("floorp-ekill-hidden"); hidden.push(target); target = null;
    }
    if (event.key.toLowerCase() === "u") {
      event.preventDefault(); hidden.pop()?.classList.remove("floorp-ekill-hidden");
    }
  }, true);
})();
