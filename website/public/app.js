// Spout Docs — client-side interactivity

function initTheme() {
  // Default: dark
  const saved = localStorage.getItem("spout-theme") || "dark";
  document.documentElement.setAttribute("data-theme", saved);
  updateThemeBtn(saved);
}

function updateThemeBtn(theme) {
  const btn = document.querySelector(".theme-toggle");
  if (btn) btn.textContent = theme === "dark" ? "light" : "dark";
}

function toggleTheme() {
  const current = document.documentElement.getAttribute("data-theme") || "dark";
  const next = current === "dark" ? "light" : "dark";
  document.documentElement.setAttribute("data-theme", next);
  localStorage.setItem("spout-theme", next);
  updateThemeBtn(next);
}

function initSidebar() {
  const closed = localStorage.getItem("spout-sidebar") === "closed";
  const sidebar = document.querySelector(".sidebar");
  const content = document.querySelector(".content");
  if (closed) {
    sidebar?.classList.add("closed");
    content?.classList.add("expanded");
  }
}

function toggleSidebar() {
  const sidebar = document.querySelector(".sidebar");
  const content = document.querySelector(".content");
  const isClosed = sidebar?.classList.toggle("closed");
  content?.classList.toggle("expanded");
  localStorage.setItem("spout-sidebar", isClosed ? "closed" : "open");
}

function initScrollSpy() {
  const center = document.getElementById("topbar-center");
  if (!center) return;
  const headers = document.querySelectorAll(
    ".markdown-body h1, .markdown-body h2, .markdown-body h3",
  );
  const obs = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (e.isIntersecting) {
          center.textContent = e.target.textContent || "";
        }
      }
    },
    { rootMargin: "0px 0px -80% 0px", threshold: 0.1 },
  );
  headers.forEach((h) => obs.observe(h));
}

function highlightActive() {
  const path = window.location.pathname;
  document.querySelectorAll(".sidebar a").forEach((a) => {
    a.classList.toggle("active", a.getAttribute("href") === path);
  });
}

function formatCallouts() {
  document.querySelectorAll("blockquote p").forEach((p) => {
    const text = p.textContent?.trim() || "";
    if (text.startsWith("[!NOTE]")) {
      p.closest("blockquote")?.classList.add("note");
      p.innerHTML = p.innerHTML.replace("[!NOTE]", "<strong>Note</strong>");
    } else if (text.startsWith("[!WARNING]")) {
      p.closest("blockquote")?.classList.add("warning");
      p.innerHTML = p.innerHTML.replace(
        "[!WARNING]",
        "<strong>Warning</strong>",
      );
    } else if (text.startsWith("[!TIP]")) {
      p.closest("blockquote")?.classList.add("tip");
      p.innerHTML = p.innerHTML.replace("[!TIP]", "<strong>Tip</strong>");
    }
  });
}

function addCodeLangLabels() {
  document.querySelectorAll("pre code[class*='language-']").forEach((code) => {
    const lang = [...code.classList]
      .find((c) => c.startsWith("language-"))
      ?.replace("language-", "");
    if (lang && lang !== "plaintext") {
      code.closest("pre")?.setAttribute("data-lang", lang);
    }
  });
}

function attachListeners() {
  document
    .querySelector(".theme-toggle")
    ?.addEventListener("click", toggleTheme);
  document
    .querySelector(".sidebar-toggle")
    ?.addEventListener("click", toggleSidebar);
}

function init() {
  initTheme();
  initSidebar();
  initScrollSpy();
  highlightActive();
  formatCallouts();
  addCodeLangLabels();
  attachListeners();
}

document.addEventListener("DOMContentLoaded", init);
