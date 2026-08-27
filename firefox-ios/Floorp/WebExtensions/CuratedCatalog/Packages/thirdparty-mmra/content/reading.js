(() => {
  document.documentElement.dataset.floorpMediumReadingLayout = "1";
  document.querySelectorAll("article").forEach(article => article.setAttribute("data-floorp-readable", "true"));
})();
