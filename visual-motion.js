(() => {
  "use strict";
  const reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const targets = ".panel-section,.stat,.card,.business-card,.product-card,.category-card,.info-panel,.assistant-panel,.policy-content";
  if (reduced || !("IntersectionObserver" in window)) return;
  const observer = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add("is-visible");
      observer.unobserve(entry.target);
    });
  }, { threshold: 0.08, rootMargin: "0px 0px -35px 0px" });
  const enhance = root => {
    if (!root || root.nodeType !== 1) return;
    if (root.matches(targets) && !root.classList.contains("motion-reveal")) {
      root.classList.add("motion-reveal");
      observer.observe(root);
    }
    if (root.querySelectorAll) root.querySelectorAll(targets).forEach(node => {
      if (node.classList.contains("motion-reveal")) return;
      node.classList.add("motion-reveal");
      observer.observe(node);
    });
  };
  const start = () => {
    enhance(document.documentElement);
    const mutations = new MutationObserver(records => records.forEach(record =>
      record.addedNodes.forEach(node => enhance(node))
    ));
    mutations.observe(document.body, { childList: true, subtree: true });
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once:true });
  else start();
})();