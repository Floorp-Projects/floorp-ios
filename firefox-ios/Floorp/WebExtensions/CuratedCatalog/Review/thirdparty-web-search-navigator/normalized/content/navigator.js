// Static keyboard-navigation subset derived from infokiller/web-search-navigator.
(() => {
  const resultLinks = () => [...document.querySelectorAll("#search a[href], #b_results a[href], [data-testid=results-list] a[href]")]
    .filter(link => link.offsetParent && link.textContent?.trim());
  let selected = -1;
  const select = index => {
    const links = resultLinks(); if (!links.length) return;
    links.forEach(link => link.classList.remove("floorp-search-selected"));
    selected = (index + links.length) % links.length;
    links[selected].classList.add("floorp-search-selected"); links[selected].focus({ preventScroll: false });
  };
  document.addEventListener("keydown", event => {
    if (event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement) return;
    if (event.key === "j") { event.preventDefault(); select(selected + 1); }
    if (event.key === "k") { event.preventDefault(); select(selected - 1); }
  }, true);
})();
