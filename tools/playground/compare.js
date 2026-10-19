// Runs corpus decks through espice.wasm (via docs/javascripts/playground.js,
// the page's own engine) and through the native espice, and fails when any
// value differs by more than 1e-9 of its variable's peak magnitude in that
// plot (1e-15 absolute floor), so noise around zero is not a 100% error.
//
//   node tools/playground/compare.js WASM_DIR ESPICE DECK_OR_DIR...
//
// Decks the browser build refuses (.hdl, .include) and decks the native
// espice fails on are skipped and counted. `zig build wasm-compare` runs it.
// The native espice must be built for baseline x86_64 (two f64 lanes, as
// wasm simd128 has), or every reassociated sum rounds differently.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");
const pg = require("../../docs/javascripts/playground.js");

const RTOL = 1e-9, ATOL = 1e-15;
// Decks known to differ, deck path suffix -> why. They report XFAIL; one
// that starts matching reports XPASS and fails the run, like the corpus.
const KNOWN = {};
const [wasmDir, espiceArg, ...inputs] = process.argv.slice(2);
if (!inputs.length) { console.error("usage: compare.js WASM_DIR ESPICE DECK_OR_DIR..."); process.exit(2); }
const espice = path.resolve(espiceArg || "");
pg.fetchWasm = async (name) => fs.readFileSync(path.join(wasmDir, name));
// Stack depth per deck: paint the idle stack (everything below
// __stack_pointer; wasm-ld puts the stack first), run, then find the lowest
// byte that changed. The run fails past half the stack.
let espiceExports = null;
const instantiate = WebAssembly.instantiate;
WebAssembly.instantiate = async (...args) => {
  const r = await instantiate(...args);
  if (r.instance.exports.espice_wasm_create) espiceExports = r.instance.exports;
  return r;
};
const PAINT = 0xa5;
const stackTop = () => espiceExports.__stack_pointer.value;
const paint = () => new Uint8Array(espiceExports.memory.buffer, 0, stackTop()).fill(PAINT, 1024);
function stackUsed() {
  const mem = new Uint8Array(espiceExports.memory.buffer, 0, stackTop());
  let i = 1024;
  while (i < mem.length && mem[i] === PAINT) i++;
  return mem.length - i;
}

const decks = inputs.flatMap((p) => fs.statSync(p).isDirectory()
  ? fs.readdirSync(p, { recursive: true }).filter((f) => f.endsWith(".sp")).sort().map((f) => path.join(p, f))
  : [p]);

/** The plots of an ngspice binary raw file: { title, names, complex, data }. */
function readRaw(buf) {
  const plots = [];
  let at = 0;
  while (at < buf.length) {
    const end = buf.indexOf("Binary:\n", at);
    const head = buf.toString("latin1", at, end).split("\n");
    const field = (k) => head.find((l) => l.startsWith(k)).slice(k.length).trim();
    const vars = +field("No. Variables:"), points = +field("No. Points:");
    const complex = field("Flags:") === "complex";
    const v0 = head.indexOf("Variables:") + 1;
    const names = head.slice(v0, v0 + vars).map((l) => l.split("\t")[2]);
    const n = vars * points * (complex ? 2 : 1);
    const start = end + "Binary:\n".length;
    const data = new Float64Array(buf.buffer.slice(buf.byteOffset + start, buf.byteOffset + start + 8 * n));
    plots.push({ title: field("Plotname:"), names, complex, data });
    at = start + 8 * n;
  }
  return plots;
}

/** Point-major data from playground.js's columns, as the raw file lays it out. */
function rows(r) {
  const w = r.complex ? 2 : 1, out = new Float64Array(r.points * r.names.length * w);
  r.columns.forEach((col, v) => { for (let p = 0; p < r.points; p++) for (let k = 0; k < w; k++) out[(p * r.names.length + v) * w + k] = col[p * w + k]; });
  return out;
}

(async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "espice-cmp-"));
  let compared = 0, skipped = 0, failed = 0, xfail = 0, unexposed = 0, values = 0, worst = 0, worstAt = "";
  let stackPeak = 0, stackPeakAt = "";
  // Instantiate espice.wasm before the first deck, so that deck is painted too.
  await pg.simulate("load\n.end\n").catch(() => {});
  for (const deck of decks) {
    const text = fs.readFileSync(deck, "utf8");
    if (pg.unsupported(text)) { skipped++; continue; }
    const raw = path.join(tmp, "out.raw");
    fs.rmSync(raw, { force: true });
    try {
      execFileSync(espice, ["-b", "-r", raw, path.resolve(deck)], { cwd: tmp, stdio: "pipe" });
    } catch { skipped++; continue; }
    const native = fs.existsSync(raw) ? readRaw(fs.readFileSync(raw)) : [];
    let wasm;
    if (espiceExports) paint();
    try { wasm = (await pg.simulate(text)).results.filter((r) => !r.error); } catch (err) {
      console.log(`FAIL ${deck}: wasm: ${err.message}`); failed++; continue;
    }
    const depth = stackUsed();
    if (depth > stackPeak) { stackPeak = depth; stackPeakAt = deck; }
    const used = new Set();
    let bad = null;
    for (const p of native) {
      const i = wasm.findIndex((r, j) => !used.has(j) && r.title === p.title && r.names.join() === p.names.join());
      // The C API has no call for these (espice.zig `run_results`, the
      // MOSRA table), so the playground cannot show them either.
      if (i < 0 && (p.title === "MOSRA Degradation" || /\(\w+=[^)]*\)$/.test(p.title))) { unexposed++; continue; }
      if (i < 0) { bad = `no wasm result for plot "${p.title}"`; break; }
      used.add(i);
      const d = rows(wasm[i]);
      if (d.length !== p.data.length) { bad = `"${p.title}": ${d.length / p.names.length} vs ${p.data.length / p.names.length} values per variable`; break; }
      const w = p.complex ? 2 : 1, nv = p.names.length;
      const scale = new Float64Array(nv);
      for (let k = 0; k < d.length; k++) { const v = Math.floor(k / w) % nv; if (Number.isFinite(p.data[k])) scale[v] = Math.max(scale[v], Math.abs(p.data[k])); }
      for (let k = 0; k < d.length; k++) {
        const a = p.data[k], b = d[k], v = Math.floor(k / w) % nv;
        if (a === b || (Number.isNaN(a) && Number.isNaN(b))) continue;
        const diff = Math.abs(a - b);
        if (diff > ATOL && diff / scale[v] > worst) { worst = diff / scale[v]; worstAt = `${deck} "${p.title}" ${p.names[v]}`; }
        if (!(diff <= RTOL * scale[v] + ATOL)) { bad = `"${p.title}" ${p.names[v]} value ${k}: native ${a}, wasm ${b}`; break; }
      }
      values += d.length;
      if (bad) break;
    }
    const known = Object.keys(KNOWN).find((k) => deck.endsWith(k));
    if (known && bad) { console.log(`XFAIL ${deck}: ${KNOWN[known]}`); xfail++; }
    else if (known) { console.log(`XPASS ${deck}: drop it from KNOWN`); failed++; }
    else if (bad) { console.log(`FAIL ${deck}: ${bad}`); failed++; } else compared++;
  }
  fs.rmSync(tmp, { recursive: true, force: true });
  console.log(`wasm-compare: ${compared} decks match (${values} values), ${failed} differ, ${xfail} xfail, ${skipped} skipped, ${unexposed} plots outside the C API; max relative deviation ${worst.toExponential(2)}${worstAt ? ` at ${worstAt}` : ""}`);
  const stackSize = espiceExports ? stackTop() : 0;
  console.log(`wasm-compare: stack peak ${(stackPeak / 1024).toFixed(0)} KiB of ${stackSize >> 10} KiB at ${stackPeakAt}`);
  process.exit(failed || !compared || 2 * stackPeak > stackSize ? 1 : 0);
})();
