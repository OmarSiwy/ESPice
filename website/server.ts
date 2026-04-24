import { marked } from "marked";
import { markedHighlight } from "marked-highlight";
import hljs from "highlight.js";
import { readFileSync, readdirSync, statSync, existsSync } from "fs";
import { join, extname, basename } from "path";

marked.use(
  markedHighlight({
    langPrefix: "hljs language-",
    highlight(code, lang) {
      const language = hljs.getLanguage(lang) ? lang : "plaintext";
      return hljs.highlight(code, { language }).value;
    },
  }),
);

const CONTENT_DIR = join(import.meta.dir, "assets/content");
const STYLE_DIR = join(import.meta.dir, "style");
const PUBLIC_DIR = join(import.meta.dir, "public");
const ASSETS_DIR = join(import.meta.dir, "assets");

// ── Sidebar tree ──────────────────────────────────────────────────────────
interface SidebarItem {
  title: string;
  path: string;
  children: SidebarItem[];
}

function parseNumberedName(name: string): [number, string] {
  const m = name.match(/^(\d+)\)\s*(.*)/);
  return m ? [parseInt(m[1]), m[2].trim()] : [Infinity, name];
}

function formatTitle(s: string): string {
  const [, clean] = parseNumberedName(s);
  return (clean || s)
    .replace(/\.md$/, "")
    .split(/[-_]/)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(" ");
}

function scanDir(dir: string, urlPrefix: string): SidebarItem[] {
  let entries: {
    sortKey: number;
    clean: string;
    orig: string;
    full: string;
  }[] = [];
  try {
    for (const name of readdirSync(dir)) {
      if (name.startsWith(".")) continue;
      const [sortKey, clean] = parseNumberedName(name);
      entries.push({ sortKey, clean, orig: name, full: join(dir, name) });
    }
  } catch {
    return [];
  }
  entries.sort((a, b) => a.sortKey - b.sortKey);

  return entries.flatMap(({ clean, orig, full }) => {
    const stat = statSync(full);
    if (stat.isDirectory()) {
      return [
        {
          title: formatTitle(clean || orig),
          path: `${urlPrefix}/${orig}`,
          children: scanDir(full, `${urlPrefix}/${orig}`),
        },
      ];
    } else if (extname(orig) === ".md") {
      const stem = basename(orig, ".md");
      return [
        {
          title: formatTitle(stem),
          path: `${urlPrefix}/${stem}`,
          children: [],
        },
      ];
    }
    return [];
  });
}

function generateSidebar(): SidebarItem[] {
  let tops: { sortKey: number; clean: string; orig: string; full: string }[] =
    [];
  try {
    for (const name of readdirSync(CONTENT_DIR)) {
      if (name.startsWith(".")) continue;
      const full = join(CONTENT_DIR, name);
      if (!statSync(full).isDirectory()) continue;
      const [sortKey, clean] = parseNumberedName(name);
      tops.push({ sortKey, clean, orig: name, full });
    }
  } catch {
    return [];
  }
  tops.sort((a, b) => a.sortKey - b.sortKey);

  return tops.map(({ clean, orig, full }) => ({
    title: formatTitle(clean || orig),
    path: `/${orig}`,
    children: scanDir(full, `/${orig}`),
  }));
}

function renderItem(item: SidebarItem, active: string, depth = 0): string {
  const isActive = active === item.path || active.startsWith(item.path + "/");
  if (item.children.length === 0) {
    return `<a href="${item.path}" class="topic-link${active === item.path ? " active" : ""}">${item.title}</a>`;
  }
  if (depth === 0) {
    return `
<div class="category">
  <details class="category-dropdown"${isActive ? " open" : ""}>
    <summary class="category-link">${item.title}</summary>
    <div class="chapters">${item.children.map((c) => renderItem(c, active, 1)).join("")}</div>
  </details>
</div>`;
  }
  return `
<details class="chapter-dropdown"${isActive ? " open" : ""}>
  <summary class="chapter-link${isActive ? " active" : ""}"><span class="arrow">▶</span>${item.title}</summary>
  <div class="topics">${item.children.map((c) => renderItem(c, active, 2)).join("")}</div>
</details>`;
}

function renderSidebar(active: string): string {
  return `
<aside class="sidebar">
  <a href="/" class="sidebar-logo">
    <img src="/spout.svg" alt="Spout"/>
    <div class="logo-text">
      <span class="logo-name">Spout</span>
      <span class="logo-sub">IC layout automation</span>
    </div>
  </a>
  <button class="sidebar-toggle" title="Toggle sidebar">
    <span></span><span></span><span></span>
  </button>
  <nav>${generateSidebar()
    .map((i) => renderItem(i, active))
    .join("")}</nav>
</aside>`;
}

function layout(opts: {
  title: string;
  heading: string;
  sidebar: string;
  body: string;
}): string {
  return `<!DOCTYPE html>
<html lang="en" data-theme="dark">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>${opts.title}</title>
  <link rel="icon" type="image/svg+xml" href="/spout.svg"/>
  <link rel="stylesheet" href="/style/main.css"/>
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/atom-one-dark.min.css"/>
  <script src="/public/app.js" defer></script>
</head>
<body>
  <div class="topbar">
    <div class="left"></div>
    <div class="center" id="topbar-center">${opts.heading}</div>
    <div class="right">
      <button class="theme-toggle" title="Toggle theme">light</button>
    </div>
  </div>
  <div id="app">
    ${opts.sidebar}
    <main class="content">
      <div id="page-content" class="markdown-body">${opts.body}</div>
    </main>
  </div>
</body>
</html>`;
}

async function renderMd(
  file: string,
  active: string,
  heading: string,
): Promise<string | null> {
  try {
    const md = readFileSync(file, "utf-8");
    const body = await marked(md);
    return layout({
      title: `${heading} — Spout`,
      heading,
      sidebar: renderSidebar(active),
      body,
    });
  } catch {
    return null;
  }
}

const server = Bun.serve({
  port: 3000,
  async fetch(req) {
    const { pathname } = new URL(req.url);

    if (pathname.startsWith("/style/")) {
      const f = join(STYLE_DIR, pathname.slice(7));
      if (existsSync(f)) return new Response(Bun.file(f));
    }
    if (pathname.startsWith("/public/")) {
      const f = join(PUBLIC_DIR, pathname.slice(8));
      if (existsSync(f)) return new Response(Bun.file(f));
    }
    if (pathname.startsWith("/assets/")) {
      const f = join(ASSETS_DIR, pathname.slice(8));
      if (existsSync(f)) return new Response(Bun.file(f));
    }
    if (pathname === "/spout.svg") {
      const f = join(import.meta.dir, "spout.svg");
      if (existsSync(f))
        return new Response(Bun.file(f), {
          headers: { "Content-Type": "image/svg+xml" },
        });
    }

    if (pathname === "/") {
      const html = await renderMd(
        join(CONTENT_DIR, "index.md"),
        "/",
        "Spout Documentation",
      );
      if (html)
        return new Response(html, { headers: { "Content-Type": "text/html" } });
    }

    const segs = pathname
      .split("/")
      .filter(Boolean)
      .map((s) => decodeURIComponent(s));
    const mdFile = join(CONTENT_DIR, ...segs) + ".md";
    const heading = formatTitle(segs.at(-1) || "index");

    if (existsSync(mdFile)) {
      const html = await renderMd(mdFile, pathname, heading);
      if (html)
        return new Response(html, { headers: { "Content-Type": "text/html" } });
    }

    const dirIndex = join(CONTENT_DIR, ...segs, "index.md");
    if (existsSync(dirIndex)) {
      const html = await renderMd(dirIndex, pathname, heading);
      if (html)
        return new Response(html, { headers: { "Content-Type": "text/html" } });
    }

    return new Response("<h1>404</h1>", {
      status: 404,
      headers: { "Content-Type": "text/html" },
    });
  },
});

console.log(`Spout docs → http://localhost:${server.port}`);
