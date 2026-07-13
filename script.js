document.documentElement.classList.add("motion-ready");

const header = document.querySelector("[data-header]");
const menuToggle = document.querySelector("[data-menu-toggle]");
const navLinks = document.querySelector("[data-nav-links]");
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

function setMenu(open) {
  if (!menuToggle || !navLinks) return;

  menuToggle.setAttribute("aria-expanded", String(open));
  menuToggle.querySelector(".sr-only").textContent = open ? "Close navigation" : "Open navigation";
  navLinks.classList.toggle("is-open", open);
  document.body.classList.toggle("menu-open", open);
}

menuToggle?.addEventListener("click", () => {
  setMenu(menuToggle.getAttribute("aria-expanded") !== "true");
});

navLinks?.addEventListener("click", (event) => {
  if (event.target.closest("a")) setMenu(false);
});

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") setMenu(false);
});

window.addEventListener("resize", () => {
  if (window.innerWidth > 760) setMenu(false);
});

function updateHeader() {
  header?.classList.toggle("is-scrolled", window.scrollY > 28);
}

updateHeader();
window.addEventListener("scroll", updateHeader, { passive: true });

const revealElements = document.querySelectorAll(".reveal");

if (reducedMotion.matches || !("IntersectionObserver" in window)) {
  revealElements.forEach((element) => element.classList.add("is-visible"));
} else {
  const observer = new IntersectionObserver(
    (entries, revealObserver) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-visible");
        revealObserver.unobserve(entry.target);
      });
    },
    { threshold: 0.12, rootMargin: "0px 0px -4%" },
  );

  revealElements.forEach((element) => observer.observe(element));
}

const gallery = document.querySelector("[data-gallery]");
const tabs = [...document.querySelectorAll("[data-gallery-tab]")];
const panels = [...document.querySelectorAll("[data-gallery-panel]")];

function selectGalleryTab(tab) {
  const target = tab.dataset.galleryTab;

  tabs.forEach((item) => {
    const selected = item === tab;
    item.setAttribute("aria-selected", String(selected));
    item.tabIndex = selected ? 0 : -1;
  });

  panels.forEach((panel) => {
    panel.hidden = panel.dataset.galleryPanel !== target;
  });
}

gallery?.addEventListener("click", (event) => {
  const tab = event.target.closest("[data-gallery-tab]");
  if (tab) selectGalleryTab(tab);
});

gallery?.addEventListener("keydown", (event) => {
  const current = event.target.closest("[data-gallery-tab]");
  if (!current || !["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;

  event.preventDefault();
  const currentIndex = tabs.indexOf(current);
  let nextIndex = currentIndex;

  if (event.key === "ArrowRight") nextIndex = (currentIndex + 1) % tabs.length;
  if (event.key === "ArrowLeft") nextIndex = (currentIndex - 1 + tabs.length) % tabs.length;
  if (event.key === "Home") nextIndex = 0;
  if (event.key === "End") nextIndex = tabs.length - 1;

  selectGalleryTab(tabs[nextIndex]);
  tabs[nextIndex].focus();
});

const parallaxStage = document.querySelector("[data-parallax-stage]");
const parallaxProduct = document.querySelector("[data-parallax]");

if (parallaxStage && parallaxProduct && !reducedMotion.matches && window.matchMedia("(pointer: fine)").matches) {
  parallaxStage.addEventListener("pointermove", (event) => {
    const bounds = parallaxStage.getBoundingClientRect();
    const x = (event.clientX - bounds.left) / bounds.width - 0.5;
    const y = (event.clientY - bounds.top) / bounds.height - 0.5;
    parallaxProduct.style.transform = `rotateX(${1 - y * 2.5}deg) rotateY(${x * 2.5}deg) translate3d(${x * 3}px, ${y * 3}px, 0)`;
  });

  parallaxStage.addEventListener("pointerleave", () => {
    parallaxProduct.style.transform = "rotateX(1deg) rotateY(0deg) translate3d(0, 0, 0)";
  });
}

const platform = navigator.userAgentData?.platform || navigator.platform || "";
const downloadLabels = document.querySelectorAll("[data-download-label]");

if (/Mac/i.test(platform)) {
  downloadLabels.forEach((label) => { label.textContent = "Download for macOS"; });
} else if (/Win/i.test(platform)) {
  downloadLabels.forEach((label) => { label.textContent = "Download for Windows"; });
}

const year = document.querySelector("[data-year]");
if (year) year.textContent = String(new Date().getFullYear());
