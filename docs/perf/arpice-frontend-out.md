# Frontend and output performance review

All 14 owned files were read in full. This report is based on source inspection,
including repository-wide reference searches and the installed Zig 0.16 stdlib.
No build, test, assembly-generation command, benchmark, or profiler was run.
The ranking below is an expected-payoff hypothesis; workload profiles may reorder it.
Every performance change below is a proposal, not an implemented optimization.

All owned paths execute on the CPU and consume host-visible data. None defines or
launches a device kernel, so there are no GPU findings or GPU speedup claims.

| Owned file | Safe cleanup result |
|---|---|
| `src/frontend/parameter_tests.zig` | Reviewed; unchanged. Existing helpers and numerical cases retained. |
| `src/frontend/parser.zig` | Reused vectorized stdlib byte counting and stdlib concatenation; reused the title delimiter; replaced the private node-shape table with byte dispatch; shared positional-value append handling; removed the unused private Token alias. |
| `src/frontend/source.zig` | Shared relative-path resolution between ordinary and HDL includes. |
| `src/frontend/tokenizer.zig` | Shared the three identical physical-line readers; bounded the existing delimiter scans; removed an unreachable optional fallback after list initialization. |
| `src/frontend/types.zig` | Reviewed; unchanged. DeviceList already uses SoA; public expression pointers require coordinated work described below. |
| `src/output/ascii_raw.zig` | Reviewed; unchanged. Retained exact ASCII headers, point indices, and complex formatting. |
| `src/output/citifile.zig` | Reviewed; unchanged. Retained S-variable selection and section order. |
| `src/output/csv.zig` | Reused the stdlib byte counter in the existing line-count assertion; writer unchanged. |
| `src/output/fsdb.zig` | Replaced integer wrappers with the equivalent Writer.writeInt implementation; removed unreferenced writeF64; corrected the point-major layout description. |
| `src/output/psf.zig` | Reused the existing real/complex stride for sweep values; retained the sweep guard and formatting. |
| `src/output/rawfile.zig` | Corrected the point-major layout description; runtime code unchanged. |
| `src/output/spice_print.zig` | Reviewed; unchanged. Retained index, separator, and complex-column formatting. |
| `src/output/sst2.zig` | Removed the discarded header-length formatting pass; framing and existing limits unchanged. |
| `src/output/touchstone.zig` | Replaced two integer maximum updates with @max; parsing guards and matrix order unchanged. |

No public declarations, public fields, floating-point formulas, tolerances, or
validation guards were changed. DeviceList's optional subcircuit-column fallbacks
remain valid for externally constructed lists. Include-selection flags describe
parser state and are not inactive entities to remove from a hot collection.

## Cache parameter substitution within its defining scope

- **Where**: `src/frontend/parser.zig:1198-1285`, `substDevice`, `substValue`, `findScope`, and `substExprDepth`; `src/frontend/parser.zig:1130-1195`, `foldExpr`.
- **Now**: Every device value can resolve the same parameter through the same scope chain, allocate another expression tree, and fold it again. Calls and binary/unary nodes are copied recursively even when repeated device instances share a definition. The mechanism is redundant recomputation, hash lookups, and arena allocation inside device loops.
- **Change**: Give each immutable parameter scope an index and cache substituted definitions by defining scope, parameter name, and remaining substitution-depth budget. Cache folded values separately for each `model_geometry` mode. Keep instance overrides in distinct scopes and perform instance-specific probe renaming after substitution. In `substExprDepth`'s `.ident` arm, also defer `arena.create(ir.Expr)` until the `.num`/`.name` cases that actually use it; the `.expr` case currently allocates and then immediately recurses without using that allocation.
- **Why it is faster**: Repeated references reuse resolved definitions instead of walking and cloning the same trees. Deferring the discarded allocation removes allocator work and retained arena bytes on every expression-valued alias.
- **Est. payoff**: Potentially substantial for large parameterized subcircuit decks; unknown, needs profiling. The share of total runtime spent in parsing versus simulation is unknown.
- **Risk**: Cache keys must preserve defining-scope shadowing, the depth-64 error, stochastic/geometry handling, and probe namespaces. Preserve expression association and short-circuit ternary folding. Even moving an allocation changes OutOfMemory timing, so it was deferred from the semantics-preserving pass. No GPU ABI is involved.
- **CPU / GPU / both**: CPU.

## Memoize expanded device counts by remaining depth

- **Where**: `src/frontend/parser.zig:108-143`, `Parser.parse`'s registry and capacity sizing; `src/frontend/parser.zig:1003-1029`, `countExpanded`.
- **Now**: The parser recursively counts every subcircuit for its registry entry, then recursively counts the top-level device list again. Repeated instances revisit the same definition and descendants. This is redundant tree traversal and repeated string-hash lookup before actual expansion begins.
- **Change**: Build the subcircuit type-ID registry first, then store counts indexed by `(type_id, remaining_depth)`. Reuse those counts for both `SubcktType.device_count` and `expanded_hint`. Retain the existing handling of unresolved/non-name instances and the `depth > 32` limit.
- **Why it is faster**: Counting work follows unique definition/depth combinations rather than every repeated instance path. Actual device expansion still performs the necessary work per emitted device.
- **Est. payoff**: Most useful in deeply repeated hierarchies; unknown, needs profiling. It only reduces preprocessing, whose total-runtime share is unknown.
- **Risk**: A cache keyed only by type changes depth-limited results. Cycles, missing definitions, u16 registry count casts, and integer overflow behavior need equivalent handling. No floating-point or GPU layout changes are needed.
- **CPU / GPU / both**: CPU.

## Format independent output points in bounded batches

- **Where**: `src/output/ascii_raw.zig:30-45`, `src/output/csv.zig:29-40`, `src/output/psf.zig:42-58`, `src/output/spice_print.zig:38-49`, and `src/output/touchstone.zig:37-69`, each `write` data loop.
- **Now**: One CPU serially converts every sample with `w.print`, interleaving formatting with writer-buffer maintenance. The existing 4 KiB/8 KiB buffers already batch filesystem writes; there is not a syscall per value. The potential bottleneck is serialized floating-point text conversion.
- **Change**: After profiling confirms formatting dominates, split already-computed points into bounded ranges. Format ranges into independent worker buffers using the existing format strings, then append completed buffers in point order. Keep headers/trailers on the caller. Pass absolute point indices and whole-plot PSF sweep/Touchstone port metadata into each formatter.
- **Why it is faster**: Independent decimal conversions can execute concurrently while ordered buffer emission preserves file ordering. A bounded number of buffers controls memory consumption.
- **Est. payoff**: Potentially several-fold on formatting-bound large exports, subject to CPU count and storage throughput; needs measurement. Export's fraction of complete simulation time is unknown.
- **Risk**: Preserve byte-for-byte formatting, signed zero/nonfinite representation, ASCII point indices, PSF section order, and Touchstone's two-port permutation. Propagate worker and write failures; small plots should retain serial formatting. This parallelizes serialization of existing samples, not transient timesteps.
- **CPU / GPU / both**: CPU.

## Store expression nodes in indexed arena columns

- **Where**: `src/frontend/types.zig:176-198`, `Value`, `Group`, and `Expr`; `src/frontend/parser.zig:678-695`, `ExprP.mk`; `src/frontend/parser.zig:967-1001` and `1249-1285`, expression cloning.
- **Now**: Expressions link full tagged-union nodes through pointers; calls have separate pointer slices. Recursive substitution, folding, and probe remapping chase these links and repeatedly allocate nodes. Tags, numeric payloads, names, and child links share each union's footprint despite different access patterns.
- **Change**: In a separately coordinated API migration, use a parse-lifetime expression arena with tag, operator, numeric payload, child-index, and call-argument-range columns; keep identifier/function strings in a separate column. Replace child pointers and argument-pointer arrays with checked u32 expression indices. Migrate `ExprP.mk`, `foldExpr`, `substExprDepth`, `mapProbeNodes`, and downstream builder consumers together.
- **Why it is faster**: Dense indices reduce link storage, and contiguous columns reduce allocation overhead and cache traffic during traversal. The benefit depends on how much expression work remains after substitution caching.
- **Est. payoff**: Unknown, needs profiling; most relevant to expression-heavy model libraries. It affects parser/builder startup, not solver arithmetic, and its total-runtime fraction is unknown.
- **Risk**: This changes public IR fields and therefore is explicitly outside the current cleanup contract. Establish the node-count limit before narrowing, retain arena lifetimes and all expression semantics, and do not reassociate numerical operations. These are frontend types, not frozen GPU PODs.
- **CPU / GPU / both**: CPU.

## Transpose selected CITIfile columns before repeated scans

- **Where**: `src/output/citifile.zig:29-51`, `write` frequency list and S-parameter sections.
- **Now**: `Plot.data` is point-major, but each DATA section walks one variable across all points with stride `nvars * 2` doubles. Large matrices revisit the same cache lines in separate column passes, consuming only one complex pair per visit. Frequency output makes another strided pass.
- **Change**: For large exports where profiling shows memory stalls, collect the selected S-variable indices once and transpose their complex pairs into contiguous per-variable scratch slices using bounded tiles. Read the frequency real parts into a contiguous slice as part of that pass. Emit the existing sections from those slices. Keep the direct path when scratch size or small input makes a transpose unattractive.
- **Why it is faster**: Tiled reads use neighboring point-major values while they are resident, and subsequent section emission reads contiguous data. This trades an extra copy and scratch storage for fewer repeated cache-line fetches.
- **Est. payoff**: Only plausibly useful for many variables and matrices exceeding cache; unknown, needs profiling. Decimal conversion may dominate and erase the benefit; total-runtime share is unknown.
- **Risk**: Preserve the current S-prefix filtering, frequency column, variable order, complex-pair order, and output text. Bound scratch allocation and retain a direct fallback. Keep `Plot.data` and all GPU boundary layouts unchanged.
- **CPU / GPU / both**: CPU.

## Tune the stream buffer for many narrow rows

- **Where**: `src/output/rawfile.zig:59-85`, `Stream.init` and `Stream.record`.
- **Now**: A stream gathers each accepted row and writes it through a 4096-byte buffer. For millions of narrow rows, the buffer fills frequently, making writer drains and filesystem calls a possible cost. Bulk `writeInner` already writes the whole payload as bytes.
- **Change**: Compare the current stream buffer against larger bounded buffers, starting with 64 KiB, on narrow-row transient streams. Choose a fixed size from that measurement; retain row gathering, successful-record counting, final count patching, and atomic publication.
- **Why it is faster**: A larger buffer can amortize drains across more small records. It is unlikely to help wide rows that already trigger large direct writes.
- **Est. payoff**: Unknown, needs profiling. At most it reduces the I/O portion of `record`; transient solve cost and storage throughput determine the total effect.
- **Risk**: Buffered errors may surface later, and more memory is held per stream. The existing failure test assumes the current buffer capacity and must be updated in the later change. Preserve failure propagation and atomic replacement semantics; no numeric or GPU ABI changes.
- **CPU / GPU / both**: CPU.

## Avoid copying the completed include expansion

- **Where**: `src/frontend/source.zig:10-24`, `load`; `src/frontend/source.zig:43-111`, `appendFile` and `appendContents`.
- **Now**: Include expansion grows an output ArrayList with the page allocator, then copies the complete expanded text into the caller's allocator. Both expanded buffers coexist during the final copy. Included source files are separately read and released.
- **Change**: Thread an output allocator through the private append helpers, build the expanded output using the caller's allocator, and return `out.toOwnedSlice` instead of `arena.dupe`. Keep temporary included-file reads separately scoped and retain the existing include-free return path.
- **Why it is faster**: Transferring ownership can remove the final full-size copy and duplicate expanded buffer. Actual gains depend on ArrayList growth and whether the caller allocator can shrink in place.
- **Est. payoff**: Saves up to one expanded-source copy, subject to allocator behavior; needs measurement on large libraries. Source loading's total-runtime share is unknown.
- **Risk**: Arena growth can retain abandoned buffers and offset the saving. Preserve cleanup for non-arena callers, OutOfMemory propagation, title bytes, injected newlines, relative paths, library selection, and depth errors. No GPU boundary is involved.
- **CPU / GPU / both**: CPU.

## Copy Spectre text between comments in bulk

- **Where**: `src/frontend/tokenizer.zig:389-406`, `spectre.Lines.stripBlockComments`.
- **Now**: Once any block comment exists, the function scans every byte and calls `ArrayList.append` for each retained byte. This repeats delimiter branches and capacity checks across long comment-free portions of the same line.
- **Change**: Reuse the existing stdlib substring search to locate each opening and closing marker, then append each retained span with `appendSlice`. Keep the initial no-comment return and the current rule that an unterminated comment discards the remaining text.
- **Why it is faster**: Span copies replace per-byte append overhead and let substring search/copy implementations process contiguous ranges efficiently.
- **Est. payoff**: Limited to Spectre lines containing block comments; unknown, needs profiling. Usually a small startup fraction, with total-runtime share unknown.
- **Risk**: Preserve trimming, adjacent markers, the current treatment of markers inside quotes, and continuation processing order. Allocation/error timing can change, which is why this remains a proposal.
- **CPU / GPU / both**: CPU.

## Combine lowercase copying through the standard library if SIMD is retained

- **Where**: `src/frontend/parser.zig:6-20`, `simdLower`; `src/frontend/parser.zig:50-65`, `Parser.parse` source preparation.
- **Now**: Case-normalized dialects first duplicate the entire source, then lowercase the copy with an explicit vector loop; newline counting is a separate stdlib vector scan. The duplicate and lowercase stages write the destination twice.
- **Change**: Compare `std.ascii.allocLowerString(arena, orig)` with the current duplicate-plus-`simdLower` sequence. It allocates the output and copies lowercased bytes in one pass. Replace the private SIMD helper only if generated assembly and representative benchmarks confirm suitable vectorization; otherwise retain the current implementation.
- **Why it is faster**: Combining copying and case conversion can remove one source-sized memory pass without changing original-byte retention for foreign paths. A scalar lowering of the stdlib loop could instead lose throughput.
- **Est. payoff**: Unknown, needs profiling and assembly inspection. Most relevant to very large normalized netlists; preprocessing's fraction of total runtime is unknown.
- **Risk**: Keep the original source untouched for case-sensitive path recovery, retain non-ASCII bytes, and leave Spectre case preservation unchanged. No new SIMD implementation was introduced in this pass because its required verification was prohibited.
- **CPU / GPU / both**: CPU.

## Nothing to do

- `src/frontend/parameter_tests.zig`: Test-only helpers and semantic coverage are appropriate; no runtime performance work identified.
- `src/output/fsdb.zig`: After the safe helper cleanup, payload output is already one contiguous byte write; no further CPU/GPU performance finding.
- `src/output/sst2.zig`: After removing discarded header counting, point payloads already use bulk record writes; no demonstrated performance reason to change framing. Its existing 64-name block and 512-byte header fallback need a separate compatibility/validation decision before capacity changes, so they remain untouched.

The unchanged files `src/frontend/types.zig`, `src/output/ascii_raw.zig`,
`src/output/citifile.zig`, and `src/output/spice_print.zig` have only deferred
performance proposals above; no safe cleanup was established for them.
