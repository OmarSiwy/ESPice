# Design review: doc-comments audit, frontend half

- **Change**: comment-only audit of every `pub` declaration and `//!` header against `doc-comments`.
- **Scope**: `src/core/`, `src/frontend/`, `src/output/`, `src/espice.zig`, `src/c_api.zig`, `include/espice.h`.
- **Domain skill(s)**: `doc-comments`, `humanizer`.
- **Hot/cold**: n.a. (no code changed).
- **Stages run**: R10 (doc audit only). Comment edits only; the one non-comment line change is the `csr.zig` `Error` set reflowed one member per line so each member carries its doc (members unchanged). Every edited file parses (`zig fmt --stdin`, same verdict as its base). Not built: zigq refuses agent builds.

Starting state: all files had a `//!` header with in → out; of 615 `pub` declarations, 15 had no doc, and 14 of those are interface plumbing (hash-map `Context`/`Adapter` `hash`/`eql`, stdpp `call` callbacks, `Complex.add`/`sub`/`mul`/`scale`/`zero`, `Sci.format`) whose signatures carry the contract. So the findings are wrong, stale, displaced or missing facts, not missing comments.

## Findings, ranked by impact

| # | Location | Problem | Fix | Status |
| - | -------- | ------- | --- | ------ |
| 1 | `include/espice.h` `espice_status` | INVALID_ARGUMENT omitted max_parallel 0/>65535, `QueryNotReady`, `DuplicateQuery`, `UnknownParameter`; INVALID_QUERY and RESULT_UNAVAILABLE undefined | All listed, checked against `c_api.zig` `status()` | APPLIED 02bf3984 |
| 2 | `include/espice.h` `espice_advance_ready`, `espice_run_all`, `espice_append_directives` | No contract at all | Readiness/distinctness precondition, `*required`, run_all's failure status and skipped `.save`/`.stim`, append's all-or-nothing and id reuse | APPLIED 02bf3984 |
| 3 | `include/espice.h` `espice_create` | ABI_MISMATCH and INVALID_ARGUMENT conditions undocumented | Added, from `c_api.zig` `create` | APPLIED 02bf3984 |
| 4 | `include/espice.h` lifetime paragraph | "Input bytes are copied" was false for `display`/`display_user` | Rewritten: no caller pointer kept except those two | APPLIED 02bf3984 |
| 5 | `src/frontend/netlist.zig` `isGround`/`isGroundName`, `bTransformationWanted`/`seedOption`, `paramText`/`readFunc`, `ModelLine`; `builder.zig` `compileTape`/`foldConstants` | Doc comments drifted onto the neighbouring declaration: one item showed two summaries, the other none | Moved each back; stale duplicate deleted | APPLIED 950e1924 |
| 6 | `src/espice.zig` `advance`, `advance_ready`, `set_params` | Hidden cost: the first call runs `.model OPT` optimization and the MOSRA stress run, with their own errors; `advance_ready` return and errors missing | Added | APPLIED 02bf3984 |
| 7 | `src/output/write.zig` header and `write` | Promised an atomic replace; a device or FIFO destination is written in place | Header and doc name the exception | APPLIED 9bc241d3 |
| 8 | `src/frontend/variants.zig` `TrialDraw.sample` | Claimed an assert the body does not have | Doc now says what the code does | APPLIED 950e1924 (assert itself PROPOSED) |
| 9 | `src/frontend/variants.zig` `Sampler.uniform` | Called `index` the trial; the trial is `trial`, `index` picks the LHS stratum; claimed an assert that is a bounds check | Fixed | APPLIED 950e1924 |
| 10 | `src/frontend/analyses.zig` `queries` | `.disto` yields three vectors with F2; `.lstb` margins row, `UnsupportedAnalysisOutput`, two `InvalidAnalysisArguments` cases missing | Fixed | APPLIED 950e1924 |
| 11 | `src/core/validate.zig` `validateDeck` | Listed only `DcSweepSourceNotFound`; also returns `InvalidQueryOptions` for variant rows past `deck.variants` and reaches `Variants.count`'s assert | Added | APPLIED bd90876e |
| 12 | `src/core/lm.zig` `Lm.init` | DIFSIZ/PARMIN must be positive (`assert(h != 0)` in `jacobianPoints`) | Precondition added | APPLIED bd90876e |
| 13 | `src/core/root.zig` header | "Imports nothing but std"; `numerics.zig` imports stdpp | Says std and stdpp (§2.8) | APPLIED bd90876e |
| 14 | `src/output/session.zig` `endStream`, `publish`, `beginStream` | Row-count failure, `TooManyPlots`, null on a failed session undocumented | Added | APPLIED 9bc241d3 |
| 15 | `src/frontend/prepare.zig` `prepare`, `resolveQueries` | Spectre input reads no data files; two error cases missing | Fixed | APPLIED 950e1924 |
| 16 | `src/frontend/spectre.zig` `Kinds`, `translate`, `switchesTo` | Key is `@intFromPtr` of returned slices (arena lifetime); errors; duplicate summary | Fixed | APPLIED 950e1924 |
| 17 | `src/frontend/netlist.zig` `setLive`, `Analysis.sn`, `netOf`, `measureOption` | Missing `ParseError`/`OutOfMemory`; `.ptdnoise` sets `sn`; `.global` names and Spectre ground; case-sensitive match | Fixed | APPLIED 950e1924 |
| 18 | `src/frontend/expr.zig` `Error`, `fold`, `Code.ident`, `operands`, stale `ponytail:` on `call` | State after error, OOM-only folds, pre-`subst` meaning of `a`, truncation | Fixed | APPLIED 950e1924 |
| 19 | `src/frontend/csr.zig` `Error`, `finish` | Members undocumented; builder unusable after a `finish` error | Per-member docs | APPLIED 950e1924 |
| 20 | `src/frontend/builder.zig` `pwlSlot` | Cited "FastVAF naming.zig"; it is VerA `lib/backend/naming.zig` | Fixed | APPLIED 950e1924 |
| 21 | `src/c_api.zig` `abi_version`, `Handle.last_error` | "Bumped on any layout change" (appends are gated by `struct_size`); "set by every failing call" | Corrected | APPLIED 02bf3984 |
| 22 | `src/output/types.zig` `validateQuery`, `output/measure.zig` `evaluateAll`/`print`, `espice.zig` `print_measures`, `run_all` | Errors undocumented, wrong parameter name, stale list of analysis kinds | Fixed | APPLIED 9bc241d3, 02bf3984 |
| 23 | Headers missing citations: core `eigen`, `numerics`, `deck`, `query`, `validate`, `result`, `intern`; frontend `netlist`, `lines`, `expr`, `builder`, `csr`, `root`, `analyses`, `spice`, `prepare`, `measure`, `wfit`; `output/touchstone` | No "what it cites" line (or no "cites nothing") | Added, each source checked against the body | APPLIED |
| 24 | Smaller contract lines: `core/deck.zig` `Variants.writes` asserts, `numerics.zig` `FreqSweep.at`, `Execution`, `query.zig` `Op.warm_start`, `Pac.n_time_samples`, `bisect.zig` `Status.itropt`; `pattern.zig` `rewrite`; `measure.zig` `parse`/`parseCheck`; `mosra.zig` `plan`; `analyses.zig` `buildJob`, `applyDeckOptions`; `lines.zig` `Lines.next` ownership | Missing or stale | Fixed | APPLIED |
| 25 | `src/frontend/expr.zig` `isOperator` | Omits `%` and `\`, which `compile` reads; netlist.zig:2517 may then split `R1 a b 10 %2` | Doc states current behaviour; the code question is open | PROPOSED (owner decision) |
| 26 | `src/frontend/variants.zig` `TrialDraw.sample` | No `assert(args.len >= 1)`, unlike `OneSigma.sample` | Add the assert | PROPOSED (code change, needs a build) |
| 27 | `src/output/{rawfile,ascii_raw,psf,sst2,fsdb,citifile}.zig` headers | Name the format but cite no spec, and do not say they cite none | Pick the spec references | PROPOSED (owner picks sources) |

## Checklist

| # | Check | Source | Verdict | Evidence |
| - | ----- | ------ | ------- | -------- |
| 1 | Every file has a `//!` header with in → out | AGENTS.md §2.15 | pass | all 50 files, before and after |
| 2 | Header names what it cites, or says it cites nothing | `doc-comments` | pass except #27 | commits bd90876e, 950e1924, 9bc241d3 |
| 3 | Every `pub` item names a fact | `doc-comments` | pass | 15 undocumented, 14 interface plumbing; `isGroundName` fixed |
| 4 | Asserts reachable from `pub` entries documented | `doc-comments` rank 1 | pass for the items above | #11, #12, #24 |
| 5 | Error conditions documented | rank 4 | pass for the items above | #1–3, #10, #11, #14, #15, #17 |
| 6 | Docs compile | `doc-comments/zig.md` | parse-checked only | `zig fmt --stdin` per file; no build (zigq refuses agents) |

## Proposed issues

- **frontend: `%` and `\` do not continue an expression on a card** — `expr.isOperator` (src/frontend/expr.zig) leaves out `%` and `\`, which `expr.compile` reads, so netlist.zig:2517 may split `R1 a b 10 %2` into separate fields. Decide whether they are expression continuations; add a deck that pins the answer against ngspice.
- **variants: `TrialDraw.sample` asserts nothing about `args`** — add `std.debug.assert(args.len >= 1)` as `OneSigma.sample` does, so a ReleaseSafe run names the contract instead of a bounds trap.
