# FastVAF production Verilog-A coverage

Can FastVAF swallow real production Verilog-A? Tested 2026-07-11 against the
OpenVAF integration-test models (github.com/pascalkuthe/OpenVAF,
`integration_tests/`) plus VBIC 1.2 from designers-guide.org
(`vbic_4T_et_cf.vla`). Harness: each model behind a `.hdl` card in a trivial
netlist, run through `espice -b` — the exact runtime pipeline
(`src/devices/loader.zig` → `fastvaf.compileSource` → `va.codegen.generate` → zig
build-lib → dlopen). Models with local `` `include `` files were pre-flattened
(FastVAF replaces non-standard includes with a comment — see P0), so the
matrix reflects the model *body*, not the include gap.

Compiling models were then sanity-checked with a real `.op`
(instantiation + bias point).

## Matrix (updated 2026-07-12 — after the P0–P9 fix pass)

All P0–P9 blockers below were fixed (preprocessor rewrite, named-branch
semantics, loop/conditional codegen, default folding, engine param binding).
Re-run of the same harness; **2026-07-11** column kept for history.

Result key: **loads** = compiles to .so and dlopens; **op-ok** = .op result
physically plausible; **live** = loads and stamps real currents (electrically
present), numerics not independently verified.

| Model | 2026-07-11 | 2026-07-12 | .op evidence |
|---|---|---|---|
| RESISTOR | loads, params unbindable | **op-ok** | divider with card `r=2000` + 2k load → v(out)=0.500 |
| VCCS | loads, dead | **op-ok** | Vin=1, G=10 into 1 Ω → v(out)=−10.000 |
| CCCS | loads, dead | **op-ok** | I(br) probe drives gain: v(out)=−10.000 (branch-current unknown) |
| DIODE | loads, dead | **op-ok** | 1 V, 1 kΩ → v(out)=0.371 (0.63 V forward drop); switch branch `V(br)<+0` collapses rs=0 |
| EKV 2.6 | parse error (P4) | **live** | loads + stamps, but .op diverges to ~1.4e7 V — numerics wrong, needs its own pass |
| VBIC 1.2 (4T et cf) | loads, dead | **op-ok** | forward active (Vb=0.9, Rc=1k, nonzero R's) → v(c)=0.116, Ic≈2.9 mA |
| HICUML2 | parse errors (P3) | **loads, live** | 89 KCL stamps; no reference bias point run |
| MEXTRAM 505 | loads, op-ok | **op-ok** | unchanged: Vb=0.9/Rc=1k → v(c)=0.096, saturated |
| PSP103.7 | empty eval (P1) | **op-ok** | defaults: Id=0.52 mA @Vg=3; vacask model card: Id=0.24 mA @Vg=1.2 — real NMOS behavior |
| BSIMSOI 4.6.1 | codegen error (P6) | **loads, live** | 135 KCL stamps |
| BSIM4 | 212 parse errors (P2) | **loads, live** | 118 KCL stamps |
| BSIMBULK | parse errors (P3) | **loads, live** | 139 KCL stamps |
| BSIMCMG 110 | 92 unused-const (P5) | **loads, live** | 99 KCL stamps |
| HiSIM2 2.8 | parse errors (P1) | **loads, live** | 65 KCL stamps (needed the loop-codegen chain rewrite) |
| ASMHEMT 101.1 | loads, dead (P8) | **op-ok** | voff=−2.0/ute=−0.5 preserved; normally-on at Vg=0: v(d)≈6 mV (Id≈5 mA) |
| MVSG_CMC 1.2 | empty eval (P1) | **loads, live** | 259 KCL stamps |
| DIODE_CMC 2.0 | parse errors (P3) | **loads, live** | 25 KCL stamps |

Also: local `` `include `` now resolves against the .va file's dir (no
pre-flattening needed), and unresolvable includes are a loud error.
Big models (PSP103: ~24k dual-number locals per eval) need the fat-stack
threads added to `src/main.zig` / `problem/par.zig`.

Known remaining gaps after the pass:
- EKV: live but diverges (bias-independent ~1e7 A in the Id chain at any
  bias) — first candidate for a numerics-debug pass with reference data.
- The bias-point sanity for the `loads, live` rows still needs golden
  references (vacask/ngspice comparisons); "live" only asserts real stamps.
- Switch-branch mode uses a runtime select; `$param_given` still always 1.0.
- Loops inside select-lowered conditionals now force block lowering; loops
  reached through *inlined user functions inside conditionals* would still
  mis-lower (loudly, as a Zig compile error — none in this corpus).

## Historical matrix (2026-07-11, pre-fix)

| Model | VA lines (flat) | Result | First hard blocker | Class |
|---|---|---|---|---|
| RESISTOR | 21 | loads | card params unbindable (P9); default `R=0` → NaN | engine/runtime |
| VCCS | 24 | loads, dead | named-branch contribs never reach node KCL rows (P7) | codegen semantics |
| CCCS | 25 | loads, dead | same as VCCS (P7) | codegen semantics |
| DIODE | 102 | loads, dead | `branch (A,CI)` contribs land on branch rows only → v(out)=5.0 instead of ~0.57 (P7) | codegen semantics |
| EKV 2.6 | 841 | parse error | inline `nature … endnature` / `discipline` blocks (P4): `expected semicolon, got 'units'` | parser |
| VBIC 1.2 (4T et cf) | 685 | loads, dead | all contributions on named-branch rows 12+, ports c/b/e/s untouched (P7) | codegen semantics |
| HICUML2 | 2121 | parse errors | trailing `//` comment inside `` `define `` body comments out rest of expanded line (P3): `` `GMIN`` kills `*V(br_biei);` | preprocessor |
| MEXTRAM 505 (bjt505t) | 2022 | loads, **op-ok** | none after flattening — forward-active .op is physical (Vb=0.9, Rc=1k → v(c)=0.069 V, saturated as expected) | — (needs P0 flatten) |
| PSP103.7 | 6625 | empty eval → zig error | comma inside quoted macro arg splits args (P1): first at `` `MPIty(TYPE …"…, +1=NMOS -1=PMOS")``; unbalanced quote then eats source to EOF, analog block lost, 39/~900 params survive | preprocessor |
| BSIMSOI 4.6.1 | 8147 | codegen → zig error | loop-carried phi copy emitted with const-folded LHS: `S.con(@as(f64, model.KU0)) = …` — invalid assignment target (P6) | codegen |
| BSIM4 | 12594 | 212 parse errors | macro invocation with arg list spanning lines: trailing args substituted empty (P2) → `T0 = DMCGeff + ;` | preprocessor |
| BSIMBULK | 4719 | parse errors | P3 again: `` `REFTEMP`` = `300.15 // 27 degrees C` comments out `- 273.15;` | preprocessor |
| BSIMCMG 110 | 4891 | codegen → zig error | 92 × `unused local constant` — temporaries emitted inside nested if/else blocks lack the top-level `_ = .{…}` discard (P5) | compile-of-generated-Zig |
| HiSIM2 2.8 | 10183 | parse errors | P1: desc string with comma (`COVDSRES`) → unbalanced quote, string token swallows following lines | preprocessor |
| ASMHEMT 101.1 | 1232 | loads, dead | negative parameter defaults dropped to 0 (P8): `voff` −2.0→0, `ute` −0.5→0 → device permanently off | codegen |
| MVSG_CMC 1.2 | 1348 | empty eval → zig error | P1: `` `MPIsw(noisemod …"…0=off, 1=on")`` splits, eats to EOF | preprocessor |
| DIODE_CMC 2.0 | 2352 | parse errors → zig error | P3: unit-conversion macros with trailing `//` comments (`NDIBOT_i = NDIBOT * (1.0e6) // [cm-3]…` eats `;`) | preprocessor |

(Historical notes below reflect the 2026-07-11 state.)

Positive control: the in-tree fixtures (`benchmark/fixtures/verilogA/*`) and
simple node-pair models (`I(a,c) <+ …`) compile, load, and give correct .op.
MEXTRAM proves the full pipeline works end-to-end on a real 2 kline
production BJT when the source dodges every bug below.

## Blocker catalog (ALL FIXED 2026-07-12)

Fix locations: P0–P3 `../VerA/src/frontend/preprocessor.zig` (comment
pre-strip, string-aware multi-line arg scan, two-phase substitution, real
include resolution via `compileSourceOpts`); P4 `frontend/Parser.zig`
(optional header semicolon); P5+P6 `backend/codegen.zig` (per-scope discards,
aliased-phi skip, loop-chain emission with join-once + entry phi init) and
`ir/Lower.zig` (select-based case, loop-depth counter, stale-cache fallback,
block lowering for loop-containing conditionals); P7 `ir/Lower.zig`
(named/implicit branches, branch-current unknowns, switch-branch mode
select); P8 `backend/codegen.zig` (constFold for defaults); P9
`src/frontend/parser.zig` + `src/devices/engine.zig` + `src/devices/loader.zig`
(card-kv into model blob, case-insensitive params and registry, `.model`
kind indirection).

All reproduced with minimal cases (scratch harness was under /tmp/vah, not
committed).

- **P0 — local `` `include `` skipped silently.**
  `Preprocessor.handleInclude` only knows the standard headers; anything else
  becomes `// [zvaf] skipped include: …`. A multi-file top (psp103.va,
  mextram.va, bsimcmg.va, diode_cmc.va, hisim2 .inc) compiles to an *empty
  device* with no diagnostic (fails later on `unused function parameter` in
  the generated Zig). `vaload.ensureLoaded` passes only source text, no
  directory, so there is nothing to resolve against.
  Lands: `../VerA/src/frontend/preprocessor.zig` (`handleInclude`) +
  an include-dir option threaded through `compileSource`
  (`../VerA/src/root.zig`) and `src/devices/loader.zig`. Effort: S.

- **P1 — macro-arg scanner is not string-aware.**
  `Preprocessor.expandAndAppend` splits invocation args on `,`/`()` depth but
  ignores quotes; `"Flag …, 0=off, 1=on"` splits into extra args, leaves an
  unbalanced quote, and the resulting string token swallows source to EOF
  ("expected endmodule, got 'EOF'"). Kills PSP103, HiSIM2, MVSG, contributes
  to BSIM4/BSIMBULK/DIODE_CMC. Minimal repro: any
  `` `M(nam,"desc with, comma") `` macro. Fix is ~10 lines in the arg-scan
  loop. Lands: `Preprocessor.zig:292-318`. Effort: S. **Highest leverage
  single fix in the whole list.**

- **P2 — macro invocation cannot span lines.**
  The arg scan stops at end-of-line; remaining parameters substitute empty
  (`T0 = DMCG + DMCI;` → `T0 = DMCGeff + ;`), silently. BSIM4 calls
  `` `BSIM4PAeffGeo(…, `` across two lines everywhere. Lands: same loop in
  `Preprocessor.zig` — needs lookahead across `\n` (or pre-join before
  expansion). Effort: S/M.

- **P3 — trailing `//` comments in macro bodies.**
  `handleDefine` keeps `// …` in the body; on expansion the comment comments
  out the *rest of the caller's line*. Kills HICUML2 (`` `GMIN``), BSIMBULK
  (`` `REFTEMP``), DIODE_CMC (unit-conversion macros). Fix: strip `//`
  comments (quote-aware) when capturing the body. Lands:
  `Preprocessor.zig:181+`. Effort: S.

- **P4 — inline `nature`/`discipline` declarations unsupported** (EKV only).
  Parser has no production for `nature X … endnature` at file scope. Lands:
  `frontend/Parser.zig` (skip-or-parse at source-file level). Effort: S
  (skipping with abstol capture is enough).

- **P5 — generated Zig: unused `const` in nested blocks.**
  Codegen's `_ = .{…}` discard only covers top-level values; temporaries
  emitted inside `if/else` blocks that end up unused are hard errors in Zig.
  Sole blocker for BSIMCMG (parses clean!). Lands:
  `backend/codegen.zig` (per-block discard list, or emit-only-live-values).
  Effort: S/M.

- **P6 — loop-carried phi with const-folded source.**
  For `while` loops, codegen emits phi copies `vN = vM;`, but when the
  incoming value folded to a constant it emits the constant *as the
  assignment target*: `S.con(@as(f64, model.KU0)) = S.con(…);`. Sole
  hard blocker for BSIMSOI. Lands: `backend/codegen.zig` phi materialization
  + `ir/SsaBuilder.zig`. Effort: M.

- **P7 — named-branch contributions never reach node rows.**
  `branch (a,c) br; I(br) <+ …` creates `br` as an extra unknown and all
  stamps stay on the branch row; ports get zero current. Devices load and
  solve but are electrically absent (verified with a minimal named-branch
  resistor: no voltage division). Blocks VBIC, HICUML2, the DIODE/VCCS/CCCS
  warmups, and switch-branch (`V(br) <+ 0`) patterns. Lands: `ir/Lower.zig`
  (map branch access to node-pair KCL ± rows; keep a branch unknown only for
  V-contributions / switch branches). Effort: M/L — this is a semantic
  feature, not a bug-fix.

- **P8 — non-literal parameter defaults become 0.**
  `parameter real voff = -2.0` → Model field default `0`: Lower stores the
  default as an SSA value; `codegen.emitDefault` only emits it when it's a
  literal constant. Unary minus is enough to lose it — silent numerical
  corruption in every CMC model (ASMHEMT is off at any bias because of it).
  Fix: const-fold the default expression in `Lower.lowerParamDecl` (or emit
  the folded value in `emitDefault`). Lands: `ir/Lower.zig:270`,
  `backend/codegen.zig:264`. Effort: S.

- **P9 — engine-side (.hdl binding, not FastVAF).**
  (a) Card params (`N1 out 0 resistor_va R=100`) are applied only to
  `Instance` (which is just `temp`); model params bind only via a `.model`
  card. (b) The ngspice tokenizer lowercases keys while generated Model
  fields keep VA case (`R`, `VOFF`), so `set_model_param` misses. Every
  parameterized use fails silently → NaN/defaults. Lands:
  `src/frontend/parser.zig:addDynDevices` (try model blob for card kv),
  `src/devices/engine.zig:setParam` (case-insensitive match).
  Effort: S.

## Priority to unlock PSP103 and BSIMSOI

PSP103 (in order; 1–3 are all in `Preprocessor.zig`):
1. **P1** string-aware macro args — S, removes the EOF cascade; expect the
   full param list + analog block to parse.
2. **P0** real include resolution — S (pre-flattening works meanwhile).
3. **P8** param-default folding — S, mandatory for sane numerics
   (`VFB = -1.0` etc.).
   Then P9 (engine) to bind the vacask `.model psp103n` cards, and re-test
   parse for stragglers (multi-line calls → P2).

BSIMSOI:
1. **P6** loop-phi assignment targets — M, the only hard compile blocker.
2. **P5** nested-block discards — S/M (will surface once P6 clears, as in
   BSIMCMG).
3. **P8** negative defaults — S.

vacask/graetz + PSP fixtures (`benchmark/fixtures/vacask/*.sp`): not feasible
today — PSP103 VA doesn't compile (P1), and even once it does, the fixtures'
lowercase `.model` params won't bind (P9). After P1+P8+P9 the wrappers in
`models_psp.inc` map 1:1 onto the VA module (level/type switches included),
so graetz-vs-builtin-PSP is a realistic first validation target.

## Verified positives

- `.hdl` runtime pipeline (compile → cache → dlopen → stamp) is solid: 7 of
  17 models produce a loadable .so; cache re-use works.
- MEXTRAM 505 (2 klines, node-pair contribs, no macro-with-string tricks):
  correct saturated-BJT .op out of the box — the MIR/codegen core handles
  production-scale math (ddt, limexp-style guards, temperature scaling).
- Named blocks (`begin : init`), function-like macros (single-line,
  comma-in-parens args), `analog function`, `$strobe`/`$simparam`/`$limit`,
  attributed `parameter integer … from[-1:1] exclude 0` all parse and lower
  correctly (probed individually).
