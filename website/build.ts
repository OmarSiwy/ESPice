import { marked } from "marked";
import { markedHighlight } from "marked-highlight";
import hljs from "highlight.js";
import {
  readFileSync,
  readdirSync,
  statSync,
  existsSync,
  mkdirSync,
  writeFileSync,
  copyFileSync,
} from "fs";
import { join, extname, basename, relative } from "path";

marked.use(
  markedHighlight({
    langPrefix: "hljs language-",
    highlight(code, lang) {
      const language = hljs.getLanguage(lang) ? lang : "plaintext";
      return hljs.highlight(code, { language }).value;
    },
  }),
);

const ROOT = import.meta.dir;
const CONTENT_DIR = join(ROOT, "assets/content");
const STYLE_DIR = join(ROOT, "style");
const PUBLIC_DIR = join(ROOT, "public");
const OUT_DIR = join(ROOT, "dist");

// ── Sidebar (duplicate of server.ts — kept in sync) ───────────────────────
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
    if (statSync(full).isDirectory())
      return [
        {
          title: formatTitle(clean || orig),
          path: `${urlPrefix}/${orig}`,
          children: scanDir(full, `${urlPrefix}/${orig}`),
        },
      ];
    if (extname(orig) === ".md")
      return [
        {
          title: formatTitle(basename(orig, ".md")),
          path: `${urlPrefix}/${basename(orig, ".md")}`,
          children: [],
        },
      ];
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
  if (item.children.length === 0)
    return `<a href="${item.path}" class="topic-link${active === item.path ? " active" : ""}">${item.title}</a>`;
  if (depth === 0)
    return `<div class="category"><details class="category-dropdown"${isActive ? " open" : ""}><summary class="category-link">${item.title}</summary><div class="chapters">${item.children.map((c) => renderItem(c, active, 1)).join("")}</div></details></div>`;
  return `<details class="chapter-dropdown"${isActive ? " open" : ""}><summary class="chapter-link${isActive ? " active" : ""}"><span class="arrow">▶</span>${item.title}</summary><div class="topics">${item.children.map((c) => renderItem(c, active, 2)).join("")}</div></details>`;
}

function renderSidebar(active: string): string {
  return `<aside class="sidebar"><a href="/" class="sidebar-logo"><img src="/spout.svg" alt="Spout"/><div class="logo-text"><span class="logo-name">Spout</span><span class="logo-sub">IC layout automation</span></div></a><button class="sidebar-toggle" title="Toggle sidebar"><span></span><span></span><span></span></button><nav>${generateSidebar()
    .map((i) => renderItem(i, active))
    .join("")}</nav></aside>`;
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
    <div class="right"><button class="theme-toggle" title="Toggle theme">light</button></div>
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

// ── File collection ───────────────────────────────────────────────────────
interface Page {
  mdPath: string;
  urlPath: string;
}

function collectPages(dir: string, urlPrefix: string, out: Page[]) {
  for (const name of readdirSync(dir).sort()) {
    if (name.startsWith(".")) continue;
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      collectPages(full, `${urlPrefix}/${name}`, out);
    } else if (extname(name) === ".md") {
      const stem = basename(name, ".md");
      out.push({
        mdPath: full,
        urlPath: stem === "index" ? urlPrefix || "/" : `${urlPrefix}/${stem}`,
      });
    }
  }
}

function copyDir(src: string, dest: string) {
  mkdirSync(dest, { recursive: true });
  for (const name of readdirSync(src)) {
    const s = join(src, name);
    const d = join(dest, name);
    if (statSync(s).isDirectory()) copyDir(s, d);
    else copyFileSync(s, d);
  }
}

// ── Build ─────────────────────────────────────────────────────────────────
async function build() {
  mkdirSync(OUT_DIR, { recursive: true });
  copyDir(STYLE_DIR, join(OUT_DIR, "style"));
  copyDir(PUBLIC_DIR, join(OUT_DIR, "public"));
  copyFileSync(join(ROOT, "spout.svg"), join(OUT_DIR, "spout.svg"));

  const pages: Page[] = [];
  const indexMd = join(CONTENT_DIR, "index.md");
  if (existsSync(indexMd)) pages.push({ mdPath: indexMd, urlPath: "/" });
  collectPages(CONTENT_DIR, "", pages);

  let n = 0;
  for (const { mdPath, urlPath } of pages) {
    const md = readFileSync(mdPath, "utf-8");
    const body = await marked(md);
    const heading =
      urlPath === "/"
        ? "Spout Documentation"
        : formatTitle(basename(mdPath, ".md"));
    const html = layout({
      title: `${heading} — Spout`,
      heading,
      sidebar: renderSidebar(urlPath),
      body,
    });

    let outFile: string;
    if (urlPath === "/") {
      outFile = join(OUT_DIR, "index.html");
    } else {
      const parts = urlPath.split("/").filter(Boolean);
      const dir = join(OUT_DIR, ...parts);
      mkdirSync(dir, { recursive: true });
      outFile = join(dir, "index.html");
    }
    writeFileSync(outFile, html);
    n++;
  }
  console.log(`Built ${n} pages → ${relative(process.cwd(), OUT_DIR)}/`);
}

build().catch((e) => {
  console.error(e);
  process.exit(1);
});
