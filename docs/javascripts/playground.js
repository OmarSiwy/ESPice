// The ESPice playground: every ```spice block on a page becomes an editable
// netlist with its cktImg schematic beside it and a Run button that
// simulates it with espice.wasm. No build step: the two wasm modules come
// from wasm/ at the site root (`zig build wasm`), uPlot from jsDelivr.
//
// The engine half (wasm loading, simulate, schematic) has no DOM
// dependency: under node, `require` it and replace `fetchWasm`.
(function () {
  "use strict";

  const script = typeof document !== "undefined" ? document.currentScript : null;
  // javascripts/playground.js -> wasm/, wherever the site is mounted.
  const wasmBase = script ? new URL("../wasm/", script.src) : null;
  const uplotBase = "https://cdn.jsdelivr.net/npm/uplot@1.6.31/dist/";

  const api = {
    /** Bytes of `name` (espice.wasm, cktimg.wasm); node replaces this. */
    fetchWasm: (name) => fetch(new URL(name, wasmBase)).then((r) => {
      if (!r.ok) throw new Error(`${name}: HTTP ${r.status}`);
      return r.arrayBuffer();
    }),
  };

  // ---------------------------------------------------------------- engine

  const utf8 = new TextEncoder();
  const text = new TextDecoder();

  // Just enough WASI for espice.wasm: stdout and stderr are captured, there
  // is no file system (path_open fails, so .include reports a missing file),
  // and everything else is ENOSYS.
  function wasi(state) {
    const view = () => new DataView(state.memory.buffer);
    const bytes = () => new Uint8Array(state.memory.buffer);
    const ESUCCESS = 0, EBADF = 8, ENOENT = 44, ENOSYS = 52;
    const calls = {
      fd_write(fd, iovs, n, written) {
        const dv = view();
        let total = 0;
        for (let i = 0; i < n; i++) {
          const ptr = dv.getUint32(iovs + 8 * i, true);
          const len = dv.getUint32(iovs + 8 * i + 4, true);
          const chunk = text.decode(bytes().subarray(ptr, ptr + len));
          if (fd === 1) state.stdout += chunk;
          else if (fd === 2) state.stderr += chunk;
          else return EBADF;
          total += len;
        }
        dv.setUint32(written, total, true);
        return ESUCCESS;
      },
      fd_fdstat_get(fd, out) {
        if (fd > 2) return EBADF;
        bytes().fill(0, out, out + 24);
        view().setUint8(out, 2); // character device
        return ESUCCESS;
      },
      fd_prestat_get: () => EBADF, // no preopened directories
      path_open: () => ENOENT,
      args_sizes_get(argc, size) { view().setUint32(argc, 0, true); view().setUint32(size, 0, true); return ESUCCESS; },
      environ_sizes_get(n, size) { view().setUint32(n, 0, true); view().setUint32(size, 0, true); return ESUCCESS; },
      args_get: () => ESUCCESS,
      environ_get: () => ESUCCESS,
      clock_time_get(id, precision, out) {
        const ns = BigInt(Math.round((id === 0 ? Date.now() : performance.now()) * 1e6));
        view().setBigUint64(out, ns, true);
        return ESUCCESS;
      },
      random_get(ptr, len) { crypto.getRandomValues(bytes().subarray(ptr, ptr + len)); return ESUCCESS; },
      sched_yield: () => ESUCCESS,
      proc_exit(code) { throw new Error(`espice.wasm exited (${code})`); },
    };
    return new Proxy(calls, { get: (t, k) => t[k] || (() => ENOSYS) });
  }

  let espice = null; // Promise of { exports, state }; dropped after a trap
  function loadEspice() {
    if (!espice) espice = (async () => {
      const state = { memory: null, stdout: "", stderr: "" };
      const { instance } = await WebAssembly.instantiate(await api.fetchWasm("espice.wasm"), { wasi_snapshot_preview1: wasi(state) });
      state.memory = instance.exports.memory;
      if (instance.exports._initialize) instance.exports._initialize();
      return { exports: instance.exports, state };
    })();
    espice.catch(() => { espice = null; });
    return espice;
  }

  let cktimg = null;
  function loadCktimg() {
    if (!cktimg) cktimg = WebAssembly.instantiate(api.fetchWasm("cktimg.wasm"), {}).then((r) => r.instance.exports);
    cktimg.catch(() => { cktimg = null; });
    return cktimg;
  }

  // ponytail: a fixed scratch block for out-parameters, enough for one
  // espice_result_info (24 B) and the size/pointer words beside it.
  const SCRATCH = 64;
  const PLOT_TITLE = 0xffffffff;
  const BUFFER_TOO_SMALL = 2;

  /** Cards the browser build cannot run, with why; null when there are none. */
  function unsupported(deck) {
    for (const raw of deck.split("\n")) {
      const line = raw.trim().toLowerCase();
      const words = line.split(/\s+/);
      if (/^\.(hdl|osdi)\b/.test(line)) return `${words[0]}: Verilog-A is compiled with a Zig compiler at run time, which the browser does not have. The playground has the built-in models only.`;
      if (/^\.(include|inc)\b/.test(line) || (words[0] === ".lib" && words.length >= 3)) return `${words[0]}: the browser has no file system, so a playground deck must be self-contained (paste the models in).`;
    }
    return null;
  }

  /**
   * Simulates `deck`. Resolves to { results, stdout, stderr } where each
   * result is { title, names, complex, points, columns: Float64Array[] }
   * (complex columns interleave re/im), or rejects with an Error whose
   * message is the reason.
   */
  async function simulate(deck) {
    const why = unsupported(deck);
    if (why) throw new Error(why);
    const { exports: e, state } = await loadEspice();
    state.stdout = state.stderr = "";
    const scratch = e.espice_wasm_alloc(SCRATCH);
    const src = utf8.encode(deck);
    const srcPtr = e.espice_wasm_alloc(src.length);
    new Uint8Array(state.memory.buffer, srcPtr, src.length).set(src);
    let problem = 0;
    try {
      problem = e.espice_wasm_create(srcPtr, src.length);
      if (!problem) throw new Error(cString(state, e.espice_wasm_diagnostic()) + stderrNote(state));
      const dv = () => new DataView(state.memory.buffer);
      const string = (fn) => {
        // Sizing call, then the copy, per include/espice.h.
        let st = fn(0, 0, scratch);
        if (st !== 0 && st !== BUFFER_TOO_SMALL) return null;
        const need = dv().getUint32(scratch, true);
        const buf = e.espice_wasm_alloc(need);
        st = fn(buf, need, scratch);
        const s = st === 0 ? cString(state, buf) : null;
        e.espice_wasm_free(buf, need);
        return s;
      };
      if (e.espice_run_all(problem) !== 0) throw new Error((string((b, n, r) => e.espice_error_message(problem, b, n, r)) || "run failed") + stderrNote(state));
      e.espice_query_count(problem, scratch);
      const count = dv().getUint32(scratch, true);
      const results = [];
      for (let id = 0; id < count; id++) {
        if (e.espice_get_result_info(problem, id, scratch) !== 0) {
          const err = string((b, n, r) => e.espice_query_error_message(problem, id, b, n, r));
          if (err) results.push({ title: `query ${id}`, error: err });
          continue;
        }
        const vars = dv().getUint32(scratch, true);
        const complex = dv().getUint32(scratch + 4, true) === 1;
        const points = Number(dv().getBigUint64(scratch + 8, true));
        if (e.espice_result_view(problem, id, scratch + 32, scratch + 36) !== 0) continue;
        const ptr = dv().getUint32(scratch + 32, true);
        const len = dv().getUint32(scratch + 36, true);
        const data = new Float64Array(state.memory.buffer, ptr, len);
        const names = [];
        for (let v = 0; v < vars; v++) names.push(string((b, n, r) => e.espice_copy_result_name(problem, id, v, b, n, r)));
        // Point-major rows of `vars` values (pairs when complex) -> columns.
        const width = complex ? 2 : 1, stride = vars * width;
        const columns = names.map((_, v) => {
          const col = new Float64Array(points * width);
          for (let p = 0; p < points; p++) for (let k = 0; k < width; k++) col[p * width + k] = data[p * stride + v * width + k];
          return col;
        });
        results.push({ title: string((b, n, r) => e.espice_copy_result_name(problem, id, PLOT_TITLE, b, n, r)), names, complex, points, columns });
      }
      return { results, stdout: state.stdout, stderr: state.stderr };
    } catch (err) {
      // A trap leaves the instance unusable; the next run starts fresh.
      if (err instanceof WebAssembly.RuntimeError) { espice = null; problem = 0; throw new Error(`the simulator crashed (${err.message})` + stderrNote(state)); }
      throw err;
    } finally {
      if (espice) {
        if (problem) e.espice_destroy(problem);
        e.espice_wasm_free(srcPtr, src.length);
        e.espice_wasm_free(scratch, SCRATCH);
      }
    }
  }

  function cString(state, ptr) {
    const b = new Uint8Array(state.memory.buffer, ptr);
    return text.decode(b.subarray(0, b.indexOf(0)));
  }

  function stderrNote(state) {
    const s = state.stderr.trim();
    return s ? `\n${s}` : "";
  }

  /** The schematic of `deck` as SVG text; rejects with cktImg's reason. */
  async function schematic(deck) {
    const e = await loadCktimg();
    const src = utf8.encode(deck);
    const ptr = e.cktimg_alloc(src.length);
    new Uint8Array(e.memory.buffer, ptr, src.length).set(src);
    const rc = e.cktimg_render(ptr, src.length);
    e.cktimg_free(ptr, src.length);
    const out = text.decode(new Uint8Array(e.memory.buffer, e.cktimg_output_ptr(), e.cktimg_output_len()));
    if (rc !== 0) throw new Error(out);
    return out;
  }

  api.simulate = simulate;
  api.schematic = schematic;
  api.unsupported = unsupported;
  if (typeof module !== "undefined") module.exports = api;
  if (typeof document === "undefined") return;
  window.ESPicePlayground = api;

  // -------------------------------------------------------------------- UI

  let uplot = null;
  function loadUplot() {
    if (!uplot) uplot = new Promise((resolve, reject) => {
      const css = document.createElement("link");
      css.rel = "stylesheet";
      css.href = uplotBase + "uPlot.min.css";
      document.head.appendChild(css);
      const js = document.createElement("script");
      js.src = uplotBase + "uPlot.iife.min.js";
      js.onload = () => resolve(window.uPlot);
      js.onerror = () => { uplot = null; reject(new Error("could not load uPlot from jsDelivr")); };
      document.head.appendChild(js);
    });
    return uplot;
  }

  function el(tag, cls, content) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (content !== undefined) n.textContent = content;
    return n;
  }

  function fmt(x) {
    return Number.isFinite(x) ? x.toPrecision(6).replace(/\.?0+(e|$)/, "$1") : String(x);
  }

  const palette = ["#2a62b8", "#d1495b", "#2e933c", "#e8a33d", "#7b4fb3", "#1b998b", "#c45ab3", "#6c757d"];

  /** One uPlot of `cols` against `x`; `log` puts x on a log scale. */
  function chart(uPlot, host, x, cols, names, xLabel, log) {
    const width = Math.max(280, host.clientWidth || 600);
    const opts = {
      width, height: 260,
      scales: { x: { time: false, distr: log ? 3 : 1 } },
      axes: [{ label: xLabel, stroke: "currentColor", grid: { stroke: "rgba(128,128,128,.2)" } },
        { stroke: "currentColor", grid: { stroke: "rgba(128,128,128,.2)" }, size: 64 }],
      series: [{ label: xLabel }].concat(names.map((n, i) => ({ label: n, stroke: palette[i % palette.length], width: 1.5, value: (u, v) => v == null ? "-" : fmt(v) }))),
    };
    const plot = new uPlot(opts, [x].concat(cols), host);
    new ResizeObserver(() => plot.setSize({ width: Math.max(280, host.clientWidth), height: 260 })).observe(host);
  }

  async function show(out, run) {
    out.replaceChildren();
    for (const r of run.results) {
      const box = el("div", "esp-pg__result");
      out.appendChild(box);
      box.appendChild(el("div", "esp-pg__title", r.title || ""));
      if (r.error) { box.appendChild(el("div", "esp-pg__error", r.error)); continue; }
      if (r.points <= 1 || r.names.length < 2) {
        // An operating point (or a single row): a table.
        const table = el("table", "esp-pg__table");
        r.names.forEach((n, v) => {
          const tr = el("tr");
          tr.appendChild(el("td", "", n));
          const c = r.columns[v];
          tr.appendChild(el("td", "", r.complex ? `${fmt(c[0])} ${c[1] < 0 ? "-" : "+"} ${fmt(Math.abs(c[1]))}j` : fmt(c[0])));
          table.appendChild(tr);
        });
        box.appendChild(table);
        continue;
      }
      const uPlot = await loadUplot();
      // Column 0 is the sweep (time, frequency, source value). Complex
      // results plot magnitude in dB over log frequency.
      const real = (c) => r.complex ? Float64Array.from({ length: r.points }, (_, p) => c[2 * p]) : c;
      const mag = (c) => Float64Array.from({ length: r.points }, (_, p) => 20 * Math.log10(Math.hypot(c[2 * p], c[2 * p + 1])));
      const x = real(r.columns[0]);
      const groups = { v: [], i: [], other: [] };
      r.names.slice(1).forEach((n, k) => {
        const g = /^i\(|#branch/i.test(n) ? "i" : /^v\(/i.test(n) ? "v" : "other";
        groups[g].push(k + 1);
      });
      for (const [g, idx] of Object.entries(groups)) {
        if (idx.length === 0) continue;
        const host = el("div", "esp-pg__plot");
        box.appendChild(host);
        const names = idx.map((v) => r.complex ? `|${r.names[v]}| dB` : r.names[v]);
        chart(uPlot, host, x, idx.map((v) => r.complex ? mag(r.columns[v]) : r.columns[v]), names, r.names[0], r.complex);
      }
    }
    if (run.stdout.trim()) out.appendChild(el("pre", "esp-pg__stdout", run.stdout));
    if (run.results.length === 0) out.appendChild(el("div", "esp-pg__status", "No results."));
  }

  function widget(code) {
    const host = code.closest("div.highlight") || code.closest("pre");
    if (!host || host.dataset.espPlayground) return;
    host.dataset.espPlayground = "1";
    const root = el("div", "esp-pg");
    const top = el("div", "esp-pg__top");
    const src = el("textarea", "esp-pg__src");
    src.value = code.textContent.replace(/\n$/, "");
    src.spellcheck = false;
    src.setAttribute("aria-label", "SPICE netlist");
    src.rows = Math.min(24, Math.max(6, src.value.split("\n").length + 1));
    const sch = el("div", "esp-pg__sch");
    sch.setAttribute("aria-label", "Schematic");
    top.append(src, sch);
    const bar = el("div", "esp-pg__bar");
    const run = el("button", "md-button md-button--primary esp-pg__run", "Run");
    run.type = "button";
    const status = el("span", "esp-pg__status");
    bar.append(run, status);
    const out = el("div", "esp-pg__out");
    out.setAttribute("aria-live", "polite");
    root.append(top, bar, out);
    host.replaceWith(root);

    let pending = 0;
    const draw = async () => {
      const ticket = ++pending;
      try {
        const svg = await schematic(src.value);
        if (ticket !== pending) return;
        const img = el("img");
        img.alt = "Schematic of the netlist";
        img.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg);
        sch.replaceChildren(img);
      } catch (err) {
        if (ticket === pending) sch.replaceChildren(el("div", "esp-pg__error", `No schematic: ${err.message}`));
      }
    };
    let timer = 0;
    src.addEventListener("input", () => { clearTimeout(timer); timer = setTimeout(draw, 300); });
    draw();

    run.addEventListener("click", async () => {
      run.disabled = true;
      status.textContent = "Running…";
      out.replaceChildren();
      // Let the status paint: the simulation runs on this thread.
      await new Promise((r) => setTimeout(r, 0));
      const t0 = performance.now();
      try {
        const result = await simulate(src.value);
        status.textContent = `Done in ${Math.round(performance.now() - t0)} ms.`;
        await show(out, result);
      } catch (err) {
        status.textContent = "";
        out.replaceChildren(el("div", "esp-pg__error", err.message));
      } finally {
        run.disabled = false;
      }
    });
  }

  function init() {
    document.querySelectorAll("pre > code.language-spice, div.language-spice pre > code").forEach(widget);
  }

  // Material's instant navigation swaps the page without reloading scripts.
  if (window.document$ && typeof window.document$.subscribe === "function") window.document$.subscribe(init);
  else if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
