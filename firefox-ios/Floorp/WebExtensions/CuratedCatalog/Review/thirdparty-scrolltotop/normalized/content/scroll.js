// Local accessibility-oriented subset derived from pratikabu/scrolltotop.
(() => {
  if (document.querySelector("#floorp-scroll-to-top")) return;
  const button = document.createElement("button"); button.id = "floorp-scroll-to-top";
  button.type = "button"; button.hidden = true; button.textContent = "↑";
  button.setAttribute("aria-label", "Scroll to top");
  button.addEventListener("click", () => window.scrollTo({ top: 0, behavior: "smooth" }));
  document.body.append(button);
  const update = () => { button.hidden = window.scrollY < 360; };
  addEventListener("scroll", update, { passive: true }); update();
})();
