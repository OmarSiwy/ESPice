# Q03-releasefast — `zig build test` reports green while three compiles fail

Plan row: Q03. Scope: **host (ARPice) build hygiene**. This file is a **plan, not a patch**.
Nothing here has been applied. `src/` is untouched.

---

## 1. Reproduction (independently confirmed)

```
$ cd /home/omare/Documents/Projects/Zig/ARPice
$ zig version
0.16.0
$ zig build test --summary all
...
Build Summary: 344/353 steps succeeded (3 failed); 266/266 tests passed
test transitive failure
+- test-problem transitive failure
|  +- run test transitive failure
|  |  +- compile test ReleaseFast native 1 errors
src/analysis/pss/hb.zig:286:22: error: root source file struct 'posix' has no member named 'getenv'
...
|  +- run test transitive failure
|  |  +- compile test ReleaseFast native transitive failure
|  |     +- compile lib espice ReleaseFast native 1 errors
...
+- run exe test-correctness transitive failure
   +- compile exe espice ReleaseFast native 1 errors
error: the following build command failed with exit code 1
```

The three failing *compile* steps, and what each one blocks:

| # | failing step | build.zig | blocks |
|---|---|---|---|
| 1 | `compile exe espice ReleaseFast native` | `exe`, root `src/main.zig` (~line 299) | `run exe test-correctness` → the whole `test` step |
| 2 | `compile lib espice ReleaseFast native` | `c_api_lib`, root `src/problem/c_api.zig` (line 363) | `test-c-api` → `test-problem` → `test` |
| 3 | `compile test ReleaseFast native` | `problem_tests`, root `src/problem/tests/problem.zig` (line 446) | `test-problem` → `test` |

All three die on the **same single expression**.

### Why "266/266 tests passed" is not a green light

That counter reports tests that **ran**. A compile failure contributes zero tests, so it
*lowers the denominator* instead of failing the ratio. With the defect fixed (verified in a
scratch copy, §5) the same command reports **297/297** — the three dead steps were hiding
**31 tests**. Any gate that reads the ratio rather than the process exit code is blind to
this class of breakage. `zig build test` *does* exit 1; it is the human/CI reading of the
summary line that failed here.

---

## 2. Broken site #1 — the actual API removal

**`/home/omare/Documents/Projects/Zig/ARPice/src/analysis/pss/hb.zig:286`**

```zig
if (std.posix.getenv("ESPICE_HB_TRACE") != null) std.debug.print("HB iter={d} res={e} step={e} normx={e}\n", .{ iter, max_residual, step, normInf(x_hat) });
```

`std.posix.getenv` does not exist in Zig 0.16. Environment access moved to
`std/process/Environ.zig` (`std.process.Environ`), which takes an `Environ` value threaded
down from `std.process.Init` rather than reaching for a process global. Confirmed absent:

```
$ grep -rn 'getenv' $ZIG_LIB/std/posix.zig
(no output)
$ grep -n 'pub fn getPosix' $ZIG_LIB/std/process/Environ.zig
606:pub fn getPosix(environ: Environ, key: []const u8) ?[:0]const u8 {
```

### This is NOT optimize-mode dependent

The report frames this as a ReleaseFast problem. It is not — it is a *reachability* problem.
Sema is optimize-mode independent; minimal probe:

```
$ cat /tmp/q03/probe/p.zig
const std = @import("std");
pub fn main() void { _ = std.posix.getenv("X"); }
$ for m in Debug ReleaseSafe ReleaseFast; do zig build-exe p.zig -O $m; done
p.zig:2:35: error: root source file struct 'posix' has no member named 'getenv'   # Debug
p.zig:2:35: error: root source file struct 'posix' has no member named 'getenv'   # ReleaseSafe
p.zig:2:35: error: root source file struct 'posix' has no member named 'getenv'   # ReleaseFast
```

What actually hides it is lazy analysis across a module boundary:

- `src/analysis/executor.zig:220` maps `.hb => @import("pss/hb.zig")` inside `fn module(tag)`,
  reached only from the private `fn run` (`executor.zig:232`) via `inline else`.
- `src/analysis/root.zig` re-exports `session` and two decls from `executor.zig`; its
  `test { ... }` aggregator (lines 7-20) lists twelve `tests/*.zig` files and **no `pss/*`**.
  So `zig build test-analysis`, whose root module *is* `src/analysis/root.zig`, compiles
  clean and never sema-checks `hb.zig`. It passed throughout.
- Only the three roots that actually instantiate the `.hb` arm (exe, C-ABI lib, problem
  tests) drag `hb.zig` into sema, and those are exactly the three that fail.

Same defect under `-Doptimize=Debug`; build.zig only swaps `use_llvm`/`use_lld`
(lines 120, 214, 307), which is codegen, not sema.

### Correct Zig 0.16 replacement

Two candidates. Rung 2 of the ladder (reuse what is already here) picks the first.

**(a) — recommended. The pattern this repo already uses, two files away.**
`src/analysis/solvers/converger.zig` already does exactly this lookup, correctly, with a
cache, and documents why the cache exists:

```
src/analysis/solvers/converger.zig:50:        const s = std.c.getenv("ESPICE_SOLVER") orelse break :blk .auto;
src/analysis/solvers/converger.zig:80:    const v = std.c.getenv(name) != null;   // fn envFlag(cache, name)
```

`std.c.getenv` survives 0.16 and needs `link_libc`, which every artifact that reaches
`hb.zig` already has (`exe.root_module.link_libc` build.zig:299, `c_api_mod.link_libc`
:361, and `problem_test_mod` inherits it through the `host_objs` objects at :210/:228).
Empirically verified to compile and link in all three artifacts (§5).

`hb.zig:17` already has `const converger = @import("solvers").converger;` in scope, so
the root-cause-shaped fix is a third flag beside `opdbg()`/`newtonDbg()` in converger.zig
reusing the existing private `envFlag` + `std.atomic.Value(u8)` cache, and `hb.zig:286`
becomes `if (converger.hbTrace()) ...`. That also fixes a real (if small) second bug:
`hb.zig` re-reads the environment **once per Newton iteration**, which is the exact cost
converger.zig:61-65 measured at 1.58 M instructions and cached away.

**(b) — the "pure" 0.16 API, rejected as over-build for a debug print.**
`std.process.Environ.getPosix(environ, "ESPICE_HB_TRACE")` requires an `Environ` value
obtained from `std.process.Init` in `main` and threaded through `RunCtx` into the PSS
solver. Correct, portable off-libc, and a multi-file plumbing change to gate one
`std.debug.print`. Revisit only if ESPice ever targets a no-libc host.

---

## 3. Full extent of Zig-0.16 API rot — the sweep

`hb.zig:286` is the **only** removed-API site in the tree. Two independent checks.

**Static.** Grep across `src/`, `tests/`, `build.zig` for the 0.15→0.16 casualties:

```
$ grep -rn --include='*.zig' -e 'std\.posix\.' -e 'std\.os\.' -e 'std\.io\.getStd' \
    -e 'usingnamespace' -e 'std\.rand\b' -e 'std\.ChildProcess' -e '@fence' \
    -e '@setCold' -e 'std\.mem\.copy(' -e 'std\.mem\.set(' src tests build.zig
src/analysis/pss/hb.zig:286:        if (std.posix.getenv("ESPICE_HB_TRACE") != null) ...
src/analysis/solvers/dev_harness.zig:22:    var ts: std.os.linux.timespec = undefined;
src/analysis/solvers/dev_harness.zig:23:    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
```

The two `dev_harness.zig` hits are **fine** — `std.os.linux.clock_gettime` still exists
(`$ZIG_LIB/std/os/linux.zig:1937`) and the `.MONOTONIC` enum-literal call form is the 0.16
signature.

**Dynamic (the authoritative check).** A scratch copy of the tree at `/tmp/q03/ARPice`
(siblings `../VerA`, `../gompute` symlinked so the path deps resolve) with `hb.zig:286`
changed to `std.c.getenv`, then **every** build step compiled:

```
$ cd /tmp/q03/ARPice && zig build test
Build Summary: 351/353 steps succeeded (1 failed); 297/297 tests passed
test transitive failure
+- run exe test-correctness failure          # numeric, not a compile error — see §6

$ zig build install test-app test-numerics test-prepared test-output test-frontend \
      test-eval test-builder test-solvers test-devices test-benchmark bench-frontend
Build Summary: 362/367 steps succeeded (2 failed); 237/237 tests passed
```

One token unblocks every compile in the tree. **There is no second removed-API site.**

---

## 4. Broken site #2 — same root cause (a step outside `test`), different API

Found by the §3 sweep. Not a *Zig* API removal — an **internal** API drift that survived
for the same structural reason: its build step is not reachable from `zig build test`.

```
$ zig build test-prepared
src/frontend/tests/prepared.zig:38:26: error: expected 6 argument(s), found 4
```

**`/home/omare/Documents/Projects/Zig/ARPice/src/frontend/tests/prepared.zig:38, :51, :54`**
call `buildJob(dir, node_id, sources, cards)` — 4 arguments. The callee grew two
parameters and the only production caller was updated; the test file was not:

```
src/frontend/prepare.zig:702:fn buildJob(dir: types.Directive, node_id: u32, node_neg: u32, ports: [4]u32, sources: problem.QueryBindings, cards: []const requests.CardRef) !?Job
src/frontend/prepare.zig:338:        if (try buildJob(dir, node_id, node_neg, ports, sources, cards)) |job0| {
```

Fix: supply the `node_neg` and `ports` arguments at all three call sites, matching what
`prepare.zig:338` passes for a directive with no explicit negative node / port list.

### Not defects (checked, listed so the next sweep does not re-open them)

- `zig build bench-frontend` exits 1 with `error: MissingPath`. That is
  `tests/benchmark/frontend.zig:8` — `args.next() orelse return error.MissingPath`. The
  step takes a netlist path: `zig build bench-frontend -- <path>`. Working as designed;
  build.zig:123 just has no default arg. Cosmetic at most.
- `std.os.linux.*` in `src/analysis/solvers/dev_harness.zig` — current 0.16 API.

---

## 5. The guard that would have caught it

The honest finding first: **a step that compiles the ReleaseFast lib already exists and
already fires.** `test-c-api` (build.zig:409) does `c_api_test_mod.linkLibrary(c_api_lib)`
and is wired into `test-problem` → `test` (:453-454). `zig build test` exited 1 on this
defect. Adding *another* lib-compiling test step would catch nothing new.

What is actually missing is two things.

### 5a. Wire the ten orphan test steps into `test_step` — the real gap

`test_step` (build.zig:399) depends on only five things: `test-problem` (:454),
`test-analysis` (:496), `test-native-lines` (:503), `test-device-errors` (:520),
`test-correctness` (:560). These ten declared steps are reachable by name and by nothing else:

`test-app`, `test-numerics`, `test-prepared`, `test-output`, `test-frontend`, `test-eval`,
`test-builder`, `test-solvers`, `test-devices`, `test-benchmark`

That is how §4 rotted: `test-prepared` has been uncompilable and nobody ran it. AGENTS.md:131
prescribes `zig build && zig build test` as the gate, and `zig build test` does not reach it.

Minimal diff — one `dependOn` per orphan, no new machinery:

- inside the suite loop (build.zig:542-546) add `test_step.dependOn(&run.step);` — covers
  `test-output`, `test-frontend`, `test-eval`, `test-builder`, `test-solvers`, `test-devices`
  in one line;
- four more lines for `run_exe_tests` (:433), `run_numerical_tests` (:459),
  `run_prepared` (:477), `run_bench_tests` (:579).

Cost of wiring them in today: §4 must be fixed first (one broken step). §3 proved the other
nine compile and pass — 237 additional tests.

### 5b. Gate on the exit code, not the summary ratio

`Build Summary: 344/353 steps succeeded (3 failed); 266/266 tests passed` must be read as
RED. The `N/N tests passed` clause counts only tests that were built and run; three dead
compiles silently removed 31 of them from both sides of the fraction. Any CI/agent check
that greps for `tests passed` instead of checking `$?` will keep missing this. If a textual
signal is wanted, grep the `steps succeeded` clause for a non-zero `(N failed)`.

---

## 6. Deliberately NOT covered by this row

- **The fix itself.** Nothing in `src/` or `build.zig` was modified. §2 names the
  replacement; applying it is a separate change.
- **`run exe test-correctness`: 518 passed, 98 failed of 616.** Unmasked by the scratch
  fix — it has been hidden behind the exe compile failure, so it has no recorded baseline.
  Sampled failures are genuine numeric/coverage debt, not build rot, e.g.
  `fixtures/convergence/monotonic_cubic_1.sp` expects `v(out)[0]=6.8232780382802e-1`
  and gets `1e0`; `fixtures/dc/device_b3soidd_output.sp` fails with
  `MOSFET LEVEL 56 needs model 'b3soidd', which is not in the device catalog`.
  These belong to their own plan rows, not Q03. Q03 is done when the tree **compiles**.
- **Per-iteration `getenv` cost in `hb.zig`.** Noted in §2 because the recommended fix
  removes it for free; not a separate deliverable.
- **Non-native targets / no-libc hosts.** Option (a) pins ESPice's env access to libc,
  which every current artifact already links. If that stops being true, option (b) is the
  plumbing job waiting.

---

## 7. Commands that exercise this row

Today (all three must be observed to fail):

```
cd /home/omare/Documents/Projects/Zig/ARPice
zig build test --summary all ; echo "exit=$?"     # exit=1, 344/353, 3 failed
zig build test-prepared      ; echo "exit=$?"     # exit=1, prepared.zig:38
zig build                    ; echo "exit=$?"     # exit=1, exe + lib
```

After §2 and §4 are fixed and §5a is wired:

```
zig build test --summary all
# expect: exit 0 on every *compile* step,
#         >=534 tests passed (297 today + 237 from the ten orphan steps),
#         0 `N errors` lines,
#         `run exe test-correctness` the only remaining failure (§6, separate row).
```

Scratch tree used for §3/§5 verification, reproducible from scratch, safe to delete:

```
rm -rf /tmp/q03 && mkdir -p /tmp/q03
cd /home/omare/Documents/Projects/Zig/ARPice \
  && tar --exclude=.zig-cache --exclude=zig-out --exclude=.git --exclude=obj_dir -cf - . \
   | (mkdir -p /tmp/q03/ARPice && cd /tmp/q03/ARPice && tar xf -)
ln -s /home/omare/Documents/Projects/Zig/VerA    /tmp/q03/VerA
ln -s /home/omare/Documents/Projects/Zig/gompute /tmp/q03/gompute
sed -i 's/std\.posix\.getenv("ESPICE_HB_TRACE")/std.c.getenv("ESPICE_HB_TRACE")/' \
  /tmp/q03/ARPice/src/analysis/pss/hb.zig
cd /tmp/q03/ARPice && zig build test --summary all
```
