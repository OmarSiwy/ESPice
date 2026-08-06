<!-- Imported verbatim from ../VerAReWrite/AGENTS.md (lines 324-1506, 2026-10-17). Edit the ruling in AGENTS.md §2, not here. -->

These Principles are binding where a principle states a rule; otherwise they
are the reasoning behind the rules. `§0`–`§2` and the design review `§1` live
in `AGENTS.md`; this project's overrides there (§2) beat any principle here.
Section numbers are kept so cross-references in both files resolve.
ARPice (Principle 11.2, Appendix B) is this project under its earlier name;
Appendix B's ARPice row is ESPice's testing roadmap (`TESTING.md`).

# The Principles

**The five commitments.** Every principle below serves one of these:

1. **Lean storage.** Each repeated thing is as small as it can be, and data that is touched together sits together.
2. **Zero runtime overhead.** An abstraction may cost compile time, build time or test time. It may not cost a cycle or a byte that hand-written code would not also spend. The skills call this extra work **residue**.
3. **Easy to modify.** A change touches one place, and the compiler finds every other place that must change.
4. **Contained failure.** An error is handled where it happens or returned as a value. A bug stops the program before it corrupts anything else.
5. **Proven by tests.** Untested code is not good code, and code with weak tests is not good code either. Tests are part of the design, not an afterthought.

**Why the fifth commitment ranks with the others.** The first four are claims about the code. Only tests turn claims into evidence. A layout you believe is compact, a dispatch you believe is free, a module you believe is isolated: each is a hypothesis until a test, a size assertion, a codegen probe, a benchmark or a fuzzer checks it. So testing is the fifth design property, and every principle names how you would verify it.

**Organization.** Part I, Foundations: the cost model, data and hardware. Part II, Lean Storage: layout, references, state, encodings and ownership. Part III, Zero-Overhead Abstraction: the design-pattern catalog pruned to compile-time and data forms. Part IV, Easy to Modify: module depth, boundaries and safe change. Part V, Contained Failure: errors, bugs and how to stop either from spreading. Part VI, Testing: oracles, techniques, process and release criteria. Part VII, Synthesis: one subsystem built end to end, plus checklists.

**Languages.** Examples are in Zig 0.17 and Rust 1.95, because both give compile-time generics, tagged unions, explicit errors and no hidden allocation. The principles transfer to C and C++ with more discipline and fewer compiler guarantees.

**Sources.** Martin (_Clean Code_, _Clean Architecture_), Fowler (_Refactoring_, _PoEAA_), McConnell (_Code Complete_), Hunt and Thomas (_The Pragmatic Programmer_), Ousterhout (_A Philosophy of Software Design_), the Gang of Four, Buschmann et al. (_POSA_), Evans (_Domain-Driven Design_), Richards and Ford, Bass et al., Fabian (_Data-Oriented Design_), Nystrom (_Game Programming Patterns_), Gregory (_Game Engine Architecture_), Bryant and O'Hallaron (_CS:APP_), Drepper, Acton, Kelley, Muratori, TigerBeetle's TigerStyle, SQLite's testing practice, the supplied testing research, and the 33 skills in `coding-skills-combined.md`. Where those sources disagree, this file says so and picks a side with a reason (§2).

---

## 3. Part I — Foundations

### Chapter 1. The Cost Model

**Principle 1.1 — Every cost has a payer and a time.** Software cost is paid by someone at some moment: the programmer while reading, the compiler while building, the test machine overnight, or the user's CPU every time the code runs. A system design programmer moves cost _leftward_ in that list. Work done once at compile time beats work done a billion times at runtime.

| When the cost is paid                                         | Who pays          | Allowed?                                          |
| ------------------------------------------------------------- | ----------------- | ------------------------------------------------- |
| Reading and changing code                                     | The programmer    | Yes; minimize it (Part IV)                        |
| Compile time (comptime, generics, monomorphization)           | The build machine | Yes, freely                                       |
| Build time (code generation, table generation, linking)       | The build machine | Yes, freely                                       |
| Test time (fuzzing, simulation, mutation, sanitizers, probes) | CI hardware       | Yes, generously (Part VI)                         |
| Runtime, for the work itself                                  | The user          | Yes; this is the product                          |
| Runtime, for an abstraction (residue)                         | The user          | **No** (§2.1)                                     |
| Runtime, for a safety check                                   | The user          | Only by deliberate budget (Principle 17.10, §2.5) |

**Principle 1.2 — Zero overhead means "no worse than the hand-written version."** This is Stroustrup's zero-overhead principle stated precisely. What you don't use, you don't pay for. What you do use, you couldn't hand-code any cheaper. "No runtime overhead" does _not_ mean "no runtime work": if the data genuinely varies at runtime, some decision must happen at runtime. The rule is that the abstraction adds nothing on top of the cheapest possible form of that decision. The evidence is a codegen probe (`zig/zero-cost.md`, `rust/zero-cost.md`): a `gen_` function through the abstraction beside a `hand_` function without it, judged by `asm_probe.py`.

| Verdict    | Meaning                                                                       |
| ---------- | ----------------------------------------------------------------------------- |
| FOLDED     | LLVM merged the two bodies into one symbol: the strongest result              |
| IDENTICAL  | Same instructions after label and constant-pool normalization                 |
| EQUIVALENT | Same mnemonic sequence, different registers                                   |
| NEGATIVE   | `gen` does strictly less static work, or is vectorized where `hand` is scalar |
| RESIDUE    | `gen` leaves extra work; the probe fails and prints a side-by-side diff       |

- **Example:** A generic `sum(comptime T: type, xs: []const T)` compiles to the same loop as a hand-written `sumF32`: FOLDED, zero overhead. A `sum(xs: []const *Summable)` calling a virtual `value()` per element adds an indirect call and a pointer per element that the hand-written loop never had: RESIDUE.
- Counts are static (instructions in the listing). An unroll can raise the static count while cutting per-iteration work; on a RESIDUE verdict for a loop, compare the inner loop blocks.

**Principle 1.3 — Compile-time abstractions still have runtime and build footprints.** Monomorphizing a generic for 12 types emits 12 copies, and instruction-cache misses are a runtime cost. The `zig` skill measured roughly 264 B per distinct comptime value and roughly 810 B per stdpp pipeline instantiation. Report each cost dimension an abstraction moves (`zig/zero-cost.md`):

| Dimension             | Measure with                                                                                |
| --------------------- | ------------------------------------------------------------------------------------------- |
| Run-time instructions | The probe                                                                                   |
| Data size             | `@sizeOf`, `@alignOf` (Zig) or `size_of` (Rust) in a compile-time assert                    |
| Code size             | `nm -S --size-sort` on the object, per instantiation                                        |
| Compile time          | Build wall time with a fresh cache dir, with and without the abstraction                    |
| Debug-build speed     | The same benchmark at `-O Debug`: abstractions that fold in ReleaseFast stay calls in Debug |

Specialize hot paths; keep cold paths (error reporting, setup, logging) non-generic so they exist once. Chapter 12 shows the "generic shell, concrete core" technique.

**Principle 1.4 — Name the properties in every design review.** For any proposed design, ask: how many bytes per item, what residue does the abstraction leave, how many existing bodies change for a likely change (the change radius), how many concepts a caller must learn (the interface weight), and how far can a failure travel? Then ask the fifth question: what test proves each answer? §1 turns these questions into stages.

### Chapter 2. Thinking in Data

Skill: `data-oriented-design` (`foundations.md` for the theory).

**Principle 2.1 — A program transforms data from one form into another.** This is Mike Acton's thesis. Code exists to perform those transformations; it is not the point. Before writing code, write down the data: its shape, its count, its size, how often each field is read and written, and which transform reads it. Answer the Six Questions out loud: what goes in and out; how many; how wide (from the spec); access pattern; lifetime; parallelizable.

**Principle 2.2 — Reject the three lies.** Acton names three false beliefs:

1. _Software is the platform._ The hardware is the platform. Different hardware calls for a different solution.
2. _Code should model the world._ Modeling "chairs" and "monsters" hides what the transforms need: positions, extents, counts. A noun list becomes a class list, and a class list becomes a topic folder (`codebase-clean-code`).
3. _Code matters more than data._ Understand the data first; the code follows from it.

**Principle 2.3 — Where there is one, there are many.** Design for the batch, not the instance. `updateAll(positions, velocities)` beats `monster.update()` because it runs one loop over dense arrays instead of N calls over scattered objects. The caller owns the loop (`data-oriented-design/measurement.md`).

**Principle 2.4 — Solve the common case first.** Measure the distribution. If 90% of entities never change state in a frame, design for the 90% and handle the rest separately (Ousterhout's "design around the critical path").

**Principle 2.5 — State is a database.** Fabian's insight: normalize program state into tables keyed by small integer IDs, as a relational database does. A relationship is a table of ID pairs, not a vector of pointers inside an object. A flag is membership in a table, not a field. Tables beat trees, and trees beat graphs (`data-oriented-design` rule 5).

- **Example:** A `Room` holding `ArrayList(*Item)` becomes a `RoomItem{ room: RoomId, item: ItemId }` table. There is no per-room list header and no pointer chasing, and "all items in all rooms" is one linear scan.

### Chapter 3. The Machine

Skill: `data-oriented-design/measurement.md` (latency costs, branch prediction, false sharing, the profile-first workflow). Sources: _CS:APP_ chapters 3, 5, 6 and 9; Drepper.

**Principle 3.1 — Memory is the bottleneck.** A modern core can execute hundreds of instructions in the time one main-memory load takes to return. Cache hits are cheap; misses dominate. Most "performance work" is reducing bytes moved and making access predictable.

**Principle 3.2 — The unit of memory traffic is the cache line (64 bytes on common x86 and ARM cores).** Loading one byte loads its whole line. If a loop uses 4 bytes of each 64-byte object, it wastes 94% of its bandwidth.

**Principle 3.3 — Sequential access is fast, random access is slow.** Hardware prefetchers detect stride-1 access and fetch ahead. Pointer chasing defeats them: each node's address is unknown until the previous load returns.

**Principle 3.4 — Alignment creates padding.** Every K-byte primitive sits at a multiple of K, so field order changes struct size. `struct { a: u8, b: u32, c: u8 }` in C order is 12 bytes; reordered to `{ b: u32, a: u8, c: u8 }` it is 8. Zig's auto (plain) `struct` reorders fields for you; `extern struct` keeps C order. In Zig 0.17, `?u32` is 8 bytes, a sentinel enum 4 bytes, `?*T` 8 bytes (`zig/zero-cost.md`).

**Principle 3.5 — Branches are cheap when predictable and expensive when not.** A mispredict flushes the pipeline. A branch on random data per element can cost more than the work it guards, and a data-dependent branch blocks vectorization. Removing the branch entirely (by partitioning data) beats making it predictable; when it must stay, make it a select (`branchless`).

**Principle 3.6 — SIMD needs contiguous, homogeneous data.** One instruction can process 4 to 16 lanes, but only if the lanes sit next to each other in memory. Struct-of-arrays layouts make that possible; array-of-structs layouts mostly prevent it. Zig 0.17 ships with LLVM's loop vectorizer off, so Zig vector code is written explicitly: stdpp pipelines or `@Vector(W)` (`zig/simd-first.md`). In Rust, explicit SIMD goes through `fearless_simd` on stable (`rust/simd-first.md`).

**Principle 3.7 — Cores share lines, so writes can collide.** Two threads writing different variables in the same cache line force that line to bounce between cores (false sharing). Give per-thread mutable data its own line.

**Principle 3.8 — Every allocation has hidden cost.** A small `malloc` typically carries header and alignment overhead and lands at an unpredictable address. A million tiny allocations waste memory and scatter data. Bulk allocation (arenas, pools, arrays) avoids both.

**How to verify Part I:** measure, don't believe. Use a profiler for time, compile-time size asserts for layout, hardware counters (cache misses, branch mispredicts) for the mechanism, codegen probes for residue, and a benchmark with a regression threshold to keep the result (median of repeated runs, results kept alive with `std.mem.doNotOptimizeAway` in Zig).

---

## 4. Part II — Lean Storage

Skills: `data-oriented-design` (+ `zig.md`, `rust.md`, `REFERENCE.md` anti-patterns), `zig/memory.md`, `rust/memory.md`, `rust/types.md`.

The master rule of this part comes from Andrew Kelley: **find where you have many of something, and make each one smaller.** A struct that exists once can be any size. A struct that exists a million times is your memory footprint and your cache-miss rate.

### Chapter 4. Layout

**Principle 4.1 — Lay data out by transform, not by concept.** Group fields by which loop reads them together. The concept "monster" is irrelevant to the movement loop; positions and velocities are what it reads.

**Principle 4.2 — SoA by default for anything iterated in bulk.** Each field lives in its own contiguous array. A loop that reads one field streams only that field, there is no padding between fields, and SIMD becomes possible. Switch to AoS **only** when every loop always accesses all fields of an entity together (`data-oriented-design` rule 2).

```zig
const Monster = struct { x: f32, y: f32, z: f32, hp: u16, kind: Kind };

// One array per field, managed for you.
var monsters: std.MultiArrayList(Monster) = .empty;
defer monsters.deinit(gpa);
try monsters.append(gpa, .{ .x = 0, .y = 0, .z = 0, .hp = 100, .kind = .goblin });

const xs = monsters.items(.x); // []f32, contiguous
for (xs) |*x| x.* += 1.0;      // touches only x
```

In Rust, use `soa_derive` or write the struct of `Vec`s by hand (`data-oriented-design/rust.md`). A `@Vector` type is a loop detail: it never becomes a struct field or appears in a public signature (`data-oriented-design/zig.md` §9).

**Principle 4.3 — Split hot from cold.** Fields read every frame go in the hot table. Names, debug info, timestamps and rarely used configuration go in a cold table indexed by the same ID. The hot table then fits more items per cache line.

**Principle 4.4 — Narrow every field to its real range, from the spec.** Width is derived, never defaulted (`data-oriented-design` question 3):

| Stated range                                  | Type                                    |
| --------------------------------------------- | --------------------------------------- |
| `[0, 1]`, or a handful of named states        | `bool`, or `enum(u8)` / packed bitfield |
| `[0, 255]`                                    | `u8`                                    |
| `[0, 65535]`                                  | `u16`                                   |
| `[0, 4294967295]`                             | `u32`                                   |
| Genuinely unbounded, or a real memory address | `usize` / `u64`                         |

A health value from 0 to 1000 is a `u16`. A kind with 12 variants is a `u8` enum. Quantize where precision allows: animation engines store rotations as 16-bit integers instead of 32-bit floats (Gregory, ch. 12). An `id: u32, hp: u16, team: u8` row costs 7 bytes in parallel arrays and 12 padded as a struct. Narrower is not free in two places: an accumulator must be wide enough for the _sum_, not the element; and a field whose range grows later is a breaking change, so widen deliberately instead of pre-widening defensively. A range you cannot state is a spec gap: ask, don't reach for `u64`.

**Principle 4.5 — Order fields to remove padding, or let the compiler do it.** In `extern struct` and C, order fields from largest to smallest alignment. A Zig auto `struct` reorders fields; Rust's default representation may too. Use `extern`/`#[repr(C)]` only when you need a fixed ABI.

**Principle 4.6 — Assert sizes at compile time.** A size you designed for is a size you check. If a later edit adds a field, the build fails and someone decides deliberately. Every type stored in a large table carries one (`rust` skill step 1).

```zig
const Token = struct { tag: Tag, start: u32 }; // Tag = enum(u8)
comptime {
    std.debug.assert(@sizeOf(Token) == 8);
}
```

```rust
const _: () = assert!(std::mem::size_of::<Token>() == 8);
```

### Chapter 5. References

**Principle 5.1 — Use indices, not pointers.** A `u32` index is half the size of a 64-bit pointer. It survives reallocation of the array it points into, serializes trivially, and can be bounds-checked. If you have fewer than 65,536 of something, a `u16` halves it again: the index width follows the arena's capacity. No pointer is stored in a struct field; pointers live inside a block (`codebase-clean-code/HIERARCHY.md`).

**Principle 5.2 — Give every index its own type.** A raw `u32` for a monster and a raw `u32` for a texture can be mixed up silently. A distinct type costs nothing at runtime (FOLDED against raw `u32` in the `zig` skill's probes) and turns the mix-up into a compile error. This is Evans' Value Object reduced to its zero-cost core.

```zig
pub const MonsterId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const TextureId = enum(u32) { none = std.math.maxInt(u32), _ };

fn hpOf(store: *const Store, id: MonsterId) u16 {
    std.debug.assert(id != .none);
    return store.hp[@backingInt(id)]; // 0.17: @backingInt / @fromBackingInt
}
// hpOf(store, texture_id) is a compile error.
```

```rust
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
#[repr(transparent)]
pub struct MonsterId(u32);
```

Reserving the maximum value as a niche (`none = maxInt(u32)` in Zig, `NonZero<u32>` or `u16::MAX` = none in Rust) buys the optional back for zero bytes, where `?u32` would cost 8.

**Principle 5.3 — Use generational handles where items are freed and reused.** Pack an index with a generation counter. When a slot is reused, its generation increments, so an old handle no longer matches. A stale reference becomes a detectable error instead of silent corruption. This is also a failure-containment tool (Part V).

```zig
pub const Handle = packed struct(u32) { index: u20, generation: u12 };

fn get(s: *Store, h: Handle) error{StaleHandle}!*Item {
    if (s.generation[h.index] != h.generation) return error.StaleHandle;
    return &s.items[h.index];
}
```

**Principle 5.4 — Represent relationships as tables of ID pairs.** A tree becomes arrays with `parent: []u32`, sorted so parents precede children. Then a single forward pass computes world transforms without recursion. A many-to-many relationship becomes a `(a_id, b_id)` table that holds only real pairs. Replace `HashMap<EntityId, Component>` with a dense packed array plus a sparse-to-dense map (`data-oriented-design`, "Refactoring OOP to DOD").

### Chapter 6. State as Existence

**Principle 6.1 — A boolean field is a table membership in disguise.** Instead of `alive: bool` on every monster, keep alive monsters in one table and dead monsters in another. The flag costs zero bytes, and the loop over living monsters has no branch. This is Fabian's _existence-based processing_. Never store a component with an `active: bool` or `Option<T>` to skip it; add or remove it from the array instead (`data-oriented-design` rule 4).

```zig
// Before: one table, a flag, a branch per item
for (monsters) |*m| if (m.burning) { m.hp -|= burn_damage; }

// After: a table of burning monster IDs, no flag, no branch
for (burning.items) |id| hp[@backingInt(id)] -|= burn_damage;
```

**Principle 6.2 — An enum state is a set of tables.** If behavior depends on state and the state changes rarely, keep one table per state. Changing state means moving a row. Each per-state loop does exactly one kind of work.

**Principle 6.3 — Store sparse data sparsely.** If 1% of items have a property, do not reserve space for it in all of them. Put it in a hash map or a side table keyed by ID (Kelley's trick 4). In Zig, a comptime-known optional field is `field: if (has_x) T else void`, which takes zero bytes when absent (`zig/comptime.md`).

**Principle 6.4 — Encode variants as tag plus fixed data plus extra.** For a closed set of variants with different sizes, store a small `tag`, a fixed-size `data` field big enough for the common variants, and an index into a shared `extra: []u32` array for the rare large ones. This beats a union sized for the largest variant and beats a heap object per item. The Zig compiler's AST and IR use this encoding (`compiler-construction` builds passes as stages over such rows).

```zig
const Node = struct {
    tag: Tag,                            // u8
    main_token: u32,
    data: struct { lhs: u32, rhs: u32 }, // lhs/rhs may index into `extra`
};
// Store nodes in std.MultiArrayList(Node); large payloads in extra: []u32.
```

**Principle 6.5 — Compute instead of store when recomputation is cheap.** The Zig tokenizer stores only a token's start offset; the end is found by re-tokenizing when needed. A derived value that is cheap to compute and rarely read should not occupy memory (Fowler's _Replace Derived Variable with Query_, applied to storage).

**Principle 6.6 — Share what is identical (Flyweight, Type Object).** If a million trees share 20 species, store the species data once in a table and give each tree a `u8` species index. Sum types beat flag-bags: an `enum` over a struct of bools whose combinations are mostly illegal.

### Chapter 7. Allocation and Ownership

**Principle 7.1 — Allocate at boundaries, never in hot loops.** Hot paths use memory that already exists. Allocation happens at startup, at the start of a request or phase, or when a table grows geometrically. Nothing grows element-wise in a loop.

**Principle 7.2 — Prefer static allocation at startup where the bound is known.** TigerStyle: "All memory must be statically allocated at startup." Then out-of-memory cannot happen mid-operation, and the memory budget is visible in one place.

**Principle 7.3 — Give each lifetime its own allocator, named for that lifetime.** An arena per request, per compile, per frame or per parse frees everything together in O(1). It removes per-object `free` calls, fragmentation and most leak bugs. Name allocators for their lifetime (`gpa`, `arena`, `scratch`) and arenas for their phase (`frame_arena`, `level_arena`, `permanent`), per `zig/memory.md` and `codebase-clean-code` step 1.

```zig
var arena = std.heap.ArenaAllocator.init(gpa);
defer arena.deinit();          // frees the whole parse at once
const ast = try parse(arena.allocator(), source);
```

**Principle 7.4 — Use pools for fixed-size churn.** A pool is an array plus a free list threaded through the unused slots, so it needs no extra storage (Nystrom, _Object Pool_). Allocation and freeing are O(1) and memory stays contiguous.

**Principle 7.5 — Pass allocators explicitly.** A function that allocates takes an allocator parameter. Allocation is then visible at every call site, testable with a failing allocator, and replaceable without touching the function. Every allocation has its `defer`/`errdefer` on the next line, every owning type's `deinit` frees every owning field, and every multi-allocation function has a passing `checkAllAllocationFailures` test (`zig` skill step 3). In Rust, size containers up front (`with_capacity`, `Box<[T]>`), store graphs as a `Vec` plus indices rather than `Rc<RefCell>` (`rust/memory.md`), and prefer APIs that take a capacity or a caller-owned buffer.

**Principle 7.6 — Bound everything.** TigerStyle: "All loops and all queues must have a fixed upper bound." Every table has a capacity: a named constant with a unit, units last (`lines_max`, `queue_capacity`). An unbounded queue is a memory leak waiting for a traffic spike. A bound turns overload into an explicit, handleable error (`assertions` step 7).

**How to verify Part II:** compile-time size asserts on every hot struct; a test that records peak memory for a reference workload and fails on regression; allocation-failure tests on every allocating path (Technique 21.8); a benchmark that would show a cache-miss regression; and the `data-oriented-design` Review Checklist (transformation, layout, memory, parallel, types, compression, verify).

---

## 5. Part III — Zero-Overhead Abstraction

Skills: `codebase-clean-code` (+ `LADDER.md`), `zig` (+ `comptime.md`, `zero-cost.md`), `rust` (+ `zero-cost.md`, `types.md`), `ponytail`.

This part prunes the classic pattern literature. A pattern survives only in a form that the compiler resolves at build time, in a data form, or in a form that is exactly the hand-written minimum. Patterns whose essence is a per-element runtime vtable, a per-object function pointer, a runtime registry or a lazy runtime check are removed from hot code. The vocabulary below is `codebase-clean-code`'s: **tables** hold the data, **transforms** hold the behaviour (one per file, named as verb phrases), the **spine** calls every transform of a pipeline in order, the **owner** is the one module that writes a table, a **seam** is a place where behaviour varies without editing that place, and a **change drill** is a named likely change with its full edit list.

### Chapter 8. The Ladder and the Pruning

**Principle 8.1 — Find the variation axis before looking for a pattern.** For each place where behaviour could differ, name what varies (kind, backend, platform, dialect, policy, plugin) and the evidence: two cases exist today, or a change drill needs it. One case and no drill means no seam: the code stays concrete. Use a pattern's name to recognise a need; build its cheapest equivalent (`codebase-clean-code` step 4).

**Principle 8.2 — Put each seam on the cheapest rung that handles its axis, inside the project budget.** The ladder (`codebase-clean-code/LADDER.md`) is priced on three axes: **residue** (work left in the hot path next to concrete code), **change radius** (existing function bodies edited to add one more case), **interface weight** (concepts a caller must learn). The hot-path budget per rung is §2.1. In summary:

1. **Concrete code.** No residue. The default answer to "should this be abstracted?"
2. **Free function over plain data.** No residue (FOLDED/IDENTICAL with the hand loop). Extract at the second real use when it meets the extraction rule.
3. **Table + transform.** Variation by data rows. If kinds differ only in numbers, a value table indexed by kind (`gravity_scale[kind]`, one indexed load per element; Muratori's shape-area coefficients). If kinds differ in data and behaviour, a separate table per kind, existence-based, with no branch on kind anywhere. Measured NEGATIVE against a per-element switch in both languages.
4. **Closed enum + exhaustive switch.** For a few kinds owned by this module that differ a little in behaviour. Cheap arms become selects with every arm computed; heavier arms a branch per element.
5. **Comptime or generic parameter.** Strategy resolved at build time. Zero residue (FOLDED), costs code size per instantiation, needs a probe.
6. **Request table or command queue.** One write and one read per request; reserve capacity at the phase boundary.
7. **Function-pointer table indexed by kind.** One indirect call per kind per pass, never per element.
8. **`dyn` / vtable.** One indirect call per call, plus a vtable pointer per object and usually a heap object per item; in an element loop it blocks inlining and vectorization and scatters the data. Cold boundaries only. _Runtime lookup_ (hash maps of handlers, reflection, service locators, dependency-injection containers, string-keyed dispatch) adds a lookup on top of the indirect call; it is never used in a hot path and is replaced by explicit parameters or comptime registration everywhere else.
9. **Process, wasm or ABI plugin boundary.** Serialization and a crossing per call. Untrusted or foreign code only.

Note the ordering: rung 5 is zero residue but sits above rungs 1–4 because it adds interface weight and code size. Prefer the lowest rung that handles the axis; reach for comptime when a lower rung cannot express the variation.

**Principle 8.3 — Climb one rung only when a drill fails, and restructure first.** A failed drill is fixed by splitting the transform so the new behaviour is a new transform after it, which usually costs nothing at runtime. Climb a rung only if restructuring cannot bring the radius down (`codebase-clean-code` step 6).

**Principle 8.4 — The pruned catalog.** The full table is Appendix A. In summary:

| Pattern                                  | Verdict     | Cheapest equivalent                                                                                         | Rung                  |
| ---------------------------------------- | ----------- | ----------------------------------------------------------------------------------------------------------- | --------------------- |
| Strategy                                 | Converted   | Comptime parameter or closure passed to a generic (Ch. 9)                                                   | 5 (2 if one strategy) |
| Template Method                          | Converted   | The spine, with the varying steps as comptime parameters                                                    | 5                     |
| Bridge                                   | Converted   | Comptime or build-option implementation (Ch. 9)                                                             | 5                     |
| Abstract Factory, Factory Method         | Converted   | A constructor function; one table per kind when kinds differ; a comptime function returning a type          | 2, 3 or 5             |
| Builder                                  | Converted   | Const config struct with defaults, validated at comptime                                                    | 2 / 5                 |
| Adapter                                  | Kept        | A newtype or thin wrapper (`repr(transparent)` folds); an inlined forwarding function                       | 5 / 2                 |
| Facade                                   | Kept        | A small module API (a deep module, Ch. 13)                                                                  | 2                     |
| Iterator                                 | Converted   | The language's `for` over a slice or index range; stdpp pipelines or `@Vector` for vector loops (Ch. 12)    | 1                     |
| Pipes and Filters                        | Converted   | Transforms in the spine; a comptime-fused pipeline                                                          | 3 / 5                 |
| Composite                                | Converted   | Flat arrays with parent/child indices, walked in index order (Ch. 5)                                        | 3                     |
| Flyweight, Type Object                   | Kept        | Shared table indexed by a small integer (Ch. 6)                                                             | 3                     |
| Visitor                                  | Converted   | Enum + exhaustive `switch`/`match`                                                                          | 4                     |
| Interpreter (on trees)                   | Converted   | Tagged-union AST in SoA; bytecode arrays                                                                    | 3 / 4                 |
| State                                    | Converted   | Enum for the state + transition table `next[state][event]`; one table per state                             | 3 + 4                 |
| Command                                  | Converted   | Command enum as data; undo and replay walk the rows                                                         | 4 + 6                 |
| Observer, Publish-Subscribe              | Converted   | Request table: subscribers append, the owner drains in spine order; comptime-registered handlers when fixed | 6 (5)                 |
| Decorator                                | Converted   | A transform inserted in the spine before or after the existing one; a comptime wrapper type                 | 3 / 5                 |
| Chain of Responsibility, middleware      | Converted   | Spine lines, or a comptime tuple of stages with `inline for`                                                | 3 / 5                 |
| Layers, Clean/Hexagonal Architecture     | Converted   | Modules enforced by the build graph, with comptime ports (Ch. 14)                                           | 5                     |
| Repository, Data Mapper                  | Converted   | Comptime-generic storage behind a module interface; translation at the edge                                 | 5 / 2                 |
| Value Object (DDD)                       | Kept        | Distinct zero-cost types (Ch. 5)                                                                            | 5                     |
| Singleton, Service Locator, DI container | **Removed** | Pass the context explicitly as a parameter; one owner created in `main`                                     | 2                     |
| Prototype (runtime cloning)              | **Removed** | Copy a const template value                                                                                 | 1                     |
| Proxy, Lazy Load, Identity Map           | **Removed** | Explicit load phases; indices into loaded tables                                                            | 3                     |
| Mediator, Blackboard, Broker             | **Removed** | Explicit data flow between tables via owners and request tables                                             | 3 / 6                 |
| Active Record, Unit of Work              | **Removed** | Plain data tables plus explicit transforms; fallible-first commit                                           | 3                     |
| Microkernel with runtime plugins         | Restricted  | Comptime plugin list; runtime plugins only at an ABI boundary, batched                                      | 5 / 9                 |

### Chapter 9. Compile-Time Interfaces

**Principle 9.1 — An interface is a contract checked by the compiler, not an object with a vtable.** In Zig, pass the implementation as a `comptime` type and check its shape at comptime. In 0.17, `@hasDecl` sees only `pub` declarations, so every method a duck-typed interface needs is `pub` (`zig/comptime.md`). In Rust, use generic parameters with trait bounds or `impl Trait`, a trait used only as a generic bound, never `dyn Trait` on a hot path. Both monomorphize: each use gets a direct, inlinable call (FOLDED). A context pointer plus a function pointer is acceptable only where calls are per batch.

```zig
fn Simulator(comptime Solver: type) type {
    comptime {
        if (!@hasDecl(Solver, "solve"))
            @compileError(@typeName(Solver) ++ " must declare pub fn solve()");
    }
    return struct {
        solver: Solver,
        pub fn step(self: *@This(), sys: *System) !void {
            try self.solver.solve(sys); // direct call, inlinable
        }
    };
}

const Sim = Simulator(SparseLu); // Strategy chosen at build time
```

```rust
fn step<S: Solver>(solver: &mut S, sys: &mut System) -> Result<(), SolveError> {
    solver.solve(sys) // static dispatch
}
```

**Principle 9.2 — Strategy, Template Method and Bridge are all "a comptime parameter."** Strategy passes an algorithm type. Template Method is the spine with the varying step as a comptime function. Bridge passes an implementation type, often selected by a build option such as the target backend.

```zig
const Backend = enum { cpu, cuda, hip };
const backend: Backend = @import("build_options").backend; // set in build.zig

const Device = switch (backend) {
    .cpu => @import("device/cpu.zig"),
    .cuda => @import("device/cuda.zig"),
    .hip => @import("device/hip.zig"),
};
```

The unused backends are not compiled into the binary at all.

**Principle 9.3 — Factories are functions; type factories run in the compiler.** A constructor function is the cheapest Factory (rung 2); a table per kind when kinds differ (rung 3). `fn Matrix(comptime T: type, comptime n: usize) type` is an Abstract Factory that runs in the compiler. A Builder becomes a const config struct with defaults, validated in a `comptime` block so a bad configuration is a build error. Zig decl literals (`pub const empty: Foo = ...`, `pub fn init(...) Foo`, used as `.empty`, `.init(...)`) keep construction terse.

**Principle 9.4 — Test doubles come free with comptime interfaces.** Because the dependency is a type parameter, a test can pass a fake clock, a fake I/O layer or a deterministic scheduler, and production pays nothing (Chapter 20). This is `legacy-code`'s "Parameterize Constructor/Function" at zero cost; never scatter trait objects through hot loops to get a seam.

### Chapter 10. Closed Sets: Tagged Unions and Exhaustive Switches

**Principle 10.1 — Most variant sets are closed. Model them as tagged unions or enums.** A shape, an AST node, a device model, a command: the program knows every variant. A tagged union stores the data inline, needs no heap object and no vtable pointer, and lets the compiler check every `switch`. Zig's `union(enum)` with an exhaustive `switch` is IDENTICAL to a hand-written tag and payload (`zig/zero-cost.md`).

```zig
const Shape = union(enum) {
    square: struct { side: f32 },
    rect: struct { w: f32, h: f32 },
    circle: struct { r: f32 },

    pub fn area(s: Shape) f32 {
        return switch (s) {
            .square => |q| q.side * q.side,
            .rect => |r| r.w * r.h,
            .circle => |c| std.math.pi * c.r * c.r,
        };
    }
};
```

**Principle 10.2 — Never write a catch-all branch over a boundary enum.** An exhaustive `switch` turns "add a variant" into a compile error at every place that must handle it. That is the compiler doing your change-impact analysis. An `else =>` (Zig) or `_ =>` (Rust) silently swallows the new variant. The only exception is a line carrying `// else: <why this is right for every present and future variant>`, and a test parses the tree and fails on any unannotated catch-all over a boundary enum (VerA's rule, adopted in `codebase-clean-code/HIERARCHY.md`).

**Principle 10.3 — Visitor becomes a switch.** The Visitor pattern exists because classic OOP cannot add operations to a closed hierarchy without double dispatch. A tagged union makes adding an operation trivial: write a new function containing a `switch`. Zig's `inline else` handles the case where every variant has a method of the same name; it instantiates one body per tag with the tag comptime-known.

```zig
pub fn bounds(s: Shape) Rect {
    return switch (s) {
        inline else => |payload| payload.bounds(), // resolved per variant at compile time
    };
}
```

**Principle 10.4 — Prefer partitioning or tables over the switch when volume is high.** For millions of items, a switch per item is still per-element dispatch. If variants differ only in constants, use a value table (rung 3). If they differ in logic, keep one table per variant and run one tight loop per table (rung 3). When the same switch appears in several transforms, the kind is being dispatched per element in the wrong place: sort or bucket by kind and move to rung 3 (`LADDER.md` rung 4 note).

**Principle 10.5 — State machines are enums plus transitions.** Encode states as an enum and transitions as a table `next[state][event]` or one function containing a `switch` over `(state, event)`. For large machines, generate the table at comptime. In Zig 0.17, a labeled `switch` with `continue :state next` gives the same dispatch as `while` + `switch` with explicit transitions (`zig/zero-cost.md`). Hierarchical and pushdown variants (Nystrom, _State_) are an enum stack, not a class hierarchy.

**Principle 10.6 — When runtime dispatch is unavoidable, hoist it out of the loop.** Dispatch once to choose a specialized loop, then run that loop over the whole batch. This is McConnell's loop unswitching applied to design, and it is what keeps rungs 6 and 7 within §2.1: once per kind per pass, never per element.

```zig
switch (kind) { // one decision per batch
    inline else => |k| for (items) |*it| process(k, it), // k is comptime inside
}
```

### Chapter 11. Compile-Time and Build-Time Generation

**Principle 11.1 — Compute constants at compile time.** Lookup tables, parsed specs, precomputed coefficients and perfect hashes are built by the compiler, not at startup. Use `std.StaticStringMap(V).initComptime(...)` for fixed string sets and `std.enums.EnumArray(E, V)` for enum-keyed arrays; the latter refuses a table that lacks a row (`error: missing struct field`). In Rust, pin a kind-indexed array's length next to it: `const _: () = assert!(GRAVITY.len() == Kind::Feather as usize + 1);`.

```zig
const crc_table: [256]u32 = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*e, i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| c = if (c & 1 != 0) 0xEDB88320 ^ (c >> 1) else c >> 1;
        e.* = c;
    }
    break :blk t;
};
```

**Principle 11.2 — Generate code at build time from a specification.** When a domain has its own language (Verilog-A models, instruction tables, protocol schemas), write a generator that runs as a build step and emits specialized source. ARPice compiles 39 Verilog-A device models through VerA at build time; the simulator then calls plain functions. In Rust, use `build.rs` or procedural macros.

**Principle 11.3 — Snapshot-test generated code.** Generated code is code. Check a golden copy into the repository or assert its shape (FileCheck-style), so a generator change shows up as a reviewable diff.

**Principle 11.4 — Make configuration a build option, not a runtime flag.** Feature toggles, backends, logging levels and debug instrumentation are `build_options` that remove the code entirely when off. Runtime flags checked inside hot loops are residue. Expensive verification asserts sit behind a comptime verification flag (TigerBeetle's `constants.verify`, per `assertions` step 2). Swarm testing (Part VI) still works: it varies build options across test runs.

**Principle 11.5 — Specialize on sizes and targets known at build time.** A `comptime n` lets the compiler unroll. `std.simd.suggestVectorLength(T)` picks the SIMD width for the target CPU at compile time. A kernel over many independent problems is designed lane-first: one kernel generic over `W`, `W == 1` as the oracle, a failure mask, a differential test (`zig/simd-first.md`, `rust/simd-first.md`).

### Chapter 12. Zero-Cost Composition

**Principle 12.1 — Compose stages in the spine, or at compile time.** Pipes and Filters, middleware chains, Decorators and Chain of Responsibility become transforms listed in the spine (rung 3), or a comptime list of stages that the compiler inlines into one function (rung 5). There is no chain of objects at runtime. Transforms never call other transforms; the spine does (`codebase-clean-code` step 3).

```zig
fn Pipeline(comptime stages: anytype) type {
    return struct {
        pub fn run(input: Sample) Sample {
            var v = input;
            inline for (stages) |Stage| v = Stage.apply(v);
            return v;
        }
    };
}

const Chain = Pipeline(.{ Highpass, Gain, Clip }); // one fused function
```

**Principle 12.2 — Fuse iterator chains into vector loops, explicitly in Zig.** A `map → filter → sum` chain should compile to one loop over SIMD blocks, not three passes or a chain of virtual `next()` calls. ZvsRust's stdpp does exactly this for Zig, and it is required there because 0.17's loop vectorizer is off. Before vectorizing: remove data-dependent branches (`branchless`), then triage the loop (`simd-loops`: element type, count, dependency none / accumulator / chain). A chain or a data-dependent output length is a wall: look for a lane axis across independent instances (`simd-first`). Keep the scalar version as the oracle, and keep it as the shipped version if the vector one benchmarks slower.

**Principle 12.3 — Replace Observer with request tables.** Instead of each subject holding a list of callbacks, producers append rows to a request table and the owner drains it at a defined point in the spine. This has no per-subject list, runs in a predictable order, is serializable (undo, logging, replay), and is deterministic, which helps testing. Reserve capacity at the phase boundary and bound the queue. If the set of handlers is fixed, register them at comptime and call them directly.

**Principle 12.4 — Keep wrappers thin enough to inline.** An Adapter or Facade is a small function or newtype that forwards to the real implementation with renamed or reshaped arguments. Because it does no work, the optimizer removes it; the probe confirms it.

**Principle 12.5 — Generic shell, concrete core.** To limit code bloat (Principle 1.3), make only the hot, type-dependent part generic. Convert to a concrete representation (a byte slice, an index, a size) and call one shared, non-generic function for everything else: formatting, error reporting, slow paths. Runtime constants go through a parameter, not a comptime value, so they do not multiply instantiations (`zig/comptime.md`).

- **Example:** A generic `Store(T)` specializes `get` and `iterate` per `T`, but its growth and error-reporting path takes `elem_size: usize` and raw bytes, so it is compiled once.

**Principle 12.6 — Cold paths are marked.** The rare branch carries `@branchHint(.cold)` as the first statement of its block in Zig, or `std::hint::cold_path()` in Rust 1.95, so the hot path stays compact.

**How to verify Part III:** a codegen probe for every abstraction on a hot path and every seam at rung ≥5, wired into `zig build test` or the Rust residue script so a regression fails the build (`zig/zero-cost.md` build wiring; Gompute's `codegen_check` is the origin of the method); benchmarks against a hand-written baseline; code-size tracking per instantiation; and the exhaustive-switch test from Principle 10.2.

---

## 6. Part IV — Easy to Modify

Skills: `codebase-design` (+ `DEEPENING.md`, `DESIGN-IT-TWICE.md`), `codebase-clean-code` (+ `HIERARCHY.md`, `DECISIONS.md`), `doc-comments`, `domain-modeling`, `refactoring-patterns` _(explicit)_, `pragmatic-programmer` _(explicit)_, `legacy-code`, `engineering-at-scale` _(explicit)_.

Code is easy to modify when a likely change touches one module, the compiler lists every other place that must change, and tests confirm nothing else broke. The tools are deep modules, owners and compile-time boundaries, and disciplined change. The measure is the change drill: a change radius that is a number.

### Chapter 13. Deep Modules

**Principle 13.1 — Complexity is what makes code hard to understand and change.** Ousterhout names its symptoms: change amplification (one change, many edits), cognitive load (how much you must hold in your head) and unknown unknowns (not knowing what you must change). Its causes are dependencies and obscurity. Every design choice in this part reduces one of these.

**Principle 13.2 — Make modules deep: a small interface hiding a lot of work.** Use `codebase-design`'s terms exactly: a **module** has an **interface** (everything a caller must know: signature, invariants, ordering, error modes, configuration, performance) and an **implementation**; **depth** is behaviour per unit of interface; **leverage** is what callers get from depth and **locality** is what maintainers get. Unix file I/O is the model: five calls hide disks, caches, permissions and devices. A shallow module, whose interface is nearly as complex as its implementation, adds cost without hiding anything. Apply the **deletion test**: imagine deleting the module; if complexity vanishes, it was a pass-through; if it reappears across N callers, it earned its keep.

**Principle 13.3 — Function size follows cohesion, not line count.** _Clean Code_ advises very small functions. Ousterhout disagrees, and this project sides with him and with `codebase-clean-code/HIERARCHY.md`: a 200-line function that does one thing in order is cohesive; a 20-line function that branches between three unrelated jobs is not. A spine or run-once sequence stays one function with labelled blocks (Carmack). Extract a function only when it is used in three or more places, defines an interface worth documenting, is named by the test plan, or has a table of input → expected-output cases (§2.2). In hot code, the data layout wins over the small-function instinct (`codebase-rules`). Elsewhere, Clean Code's naming guidance is cheaper to follow than to argue with.

**Principle 13.4 — Hide decisions, not just data.** Information hiding means a design decision lives in exactly one module. The red flag is _information leakage_: two modules that both know a file format, an index encoding or a protocol detail. Merge them or give the knowledge one owner. Temporal decomposition (one module per execution phase) is a common cause.

**Principle 13.5 — DRY is about knowledge, not text.** Hunt and Thomas: every piece of knowledge has one authoritative representation. Two loops that look alike but encode different rules are not duplication, and merging them is false DRY (`pragmatic-programmer`). Two places that both know "the tolerance is 1e-3" are duplication.

**Principle 13.6 — One module answers to one actor, and owns one set of tables.** Martin's Single Responsibility Principle, stated correctly: a module changes for one reason, meaning one source of requirements. `codebase-clean-code` makes it structural: group transforms by the table they **write**; those groups are the modules. Code serving the solver and the report writer does not share a function just because today they compute the same thing.

**Principle 13.7 — Pull complexity downward.** It is better for a module's implementer to handle a hard case than to push it onto every caller. Do not export configuration knobs the module could decide itself.

**Principle 13.8 — Names and comments carry what code cannot.** Use intention-revealing, searchable names, one word per concept, the project's domain terms from `GLOSSARY.md` (`domain-modeling`), and units last in descending significance (`latency_ms_max`, `lines_max`). Name a module or file for the data it owns (`physics.zig` owns `bodies` and `contacts`), never for a pattern. Doc comments follow `doc-comments`: a `///` earns its place by carrying a fact the signature cannot, ranked precondition, invalidation, ownership, failure, cost, reason. Every file opens with a `//!` header stating its transformation (in → out) and what it cites (spec clauses, decision records, papers). Implementation notes go in `//` comments inside the body. Writing the interface comment first is a design test: if it is hard to write, the abstraction is wrong.

**Principle 13.9 — Design it twice.** Sketch two genuinely different designs for any important module before choosing (`codebase-design/DESIGN-IT-TWICE.md`). The comparison exposes trade-offs a single design hides.

### Chapter 14. Owners, Spines and Compile-Time Boundaries

**Principle 14.1 — Dependencies point toward policy.** Martin's Dependency Rule: the core rules of the system (physics, solvers, geometry, business rules) import nothing about I/O, file formats, GPUs, frameworks or UIs. Those are details that plug into the core. Here the plug is a comptime parameter (rung 5), not a runtime interface.

**Principle 14.2 — One owner per table; outside writes go through request tables.** Each table has exactly one owner, the module that writes it. Everyone else reads it or appends to a request table the owner drains (`damage_events` → `applyDamage`). A module depends only on the owners of the tables it reads, and the arrows form a DAG.

**Principle 14.3 — One spine per pipeline.** Write one function per pipeline (a frame, a request, a compiler pass, a Newton step) that calls every transform in order, one line each, before any transform body exists. Every branch that chooses _which_ work happens lives in the spine; transforms are straight loops ("push ifs up, fors down"). A transform's signature takes every table it reads as `const` and every table it writes as mutable, so the spine's signatures are the data-flow graph. No globals, no stored back-pointers, no context struct carrying more than the function touches.

**Principle 14.4 — Let the build graph enforce the DAG.** Review does not keep a dependency graph acyclic; the build does. Make the core a separate module or crate whose import list excludes I/O, so a forbidden import is a compile error.

```zig
// build.zig — modules in dependency order; each import resolves only against modules above it
const core = b.addModule("core", .{
    .root_source_file = b.path("src/core/root.zig"),
    // no imports: core cannot reach io, gpu or cli
});
const io_mod = b.addModule("io", .{
    .root_source_file = b.path("src/io/root.zig"),
    .imports = &.{.{ .name = "core", .module = core }},
});
```

What the toolchains check, and the gap to close (`HIERARCHY.md`): Cargo rejects crate cycles but not module cycles inside a crate; Zig's `build.zig` hides unwired modules but accepts two modules handed to each other. Close the gap with a `module_specs` array in dependency order whose resolver panics on a forward import (VerA's pattern), crates for owners whose direction matters, or a test over `cargo tree`. Inside a module: leaves never import their module's root; the root aliases only what other modules call (that alias list is the API); stage outputs are narrow values passed as `*const`.

**Principle 14.5 — Ports are comptime parameters.** Hexagonal architecture's "ports and adapters" become generic parameters on the core: `fn Engine(comptime Clock: type, comptime Storage: type) type`. Production passes the real adapters. Tests pass fakes. The binary contains direct calls only. `codebase-design`: one adapter means a hypothetical seam, two adapters a real one.

**Principle 14.6 — Group by owner and dependency direction, never by topic.** A directory tree says "solver, netlist, devices, analysis", not "models, controllers, utils" (Martin's _Screaming Architecture_). Topic folders (`utils/`, `common/`, `models/`, `managers/`, `helpers.rs`) collect code touching several owners and close import cycles through themselves. A helper touching one owner's tables goes into that owner; a type shared by several owners goes into a leaf with no internal dependencies; a file goes in the lowest module that can import everything it needs. A crate or package boundary exists only to enforce single ownership, gate a heavy dependency, or split by platform (`HIERARCHY.md`). Each file holds one transformation and reads top-down: types, then the spine, then transforms in the order the spine calls them.

**Principle 14.7 — Translate at the boundary.** Data from outside (files, network, a foreign API, a C caller) is parsed and validated once, at the edge, into the core's own types ("parse, don't validate"). Evans calls this an anticorruption layer; McConnell calls it a barricade; the `rust` skill calls it the boundary. Inside, code trusts its types and checks nothing again. This is also the main failure-containment boundary (Chapter 18). Library and FFI boundaries are designed with `api-design`: write the usage code first, and give every high tier a path down to a low one.

**Principle 14.8 — Bounded contexts get their own types.** The netlist parser's `Device` and the solver's device table need not be the same type. Two models connected by an explicit conversion are easier to change than one model stretched to serve both. `GLOSSARY.md` (or `GLOSSARY-MAP.md` for several contexts) records the terms (`domain-modeling`).

**Principle 14.9 — Check the architecture in CI.** Richards and Ford call these fitness functions: tests that fail when the architecture degrades. Required here: the core compiles without I/O imports; the module graph is acyclic; no unannotated `else =>`/`_ =>` over boundary enums; probe verdicts for every rung ≥5 seam; hot structs at their asserted sizes; binary size under a budget.

### Chapter 15. Changing Code Safely

**Principle 15.1 — Make the compiler find the change.** The zero-overhead tools in this file double as change-impact analysis. Add a variant to a tagged union and every unhandled `switch` fails to compile. Change an ID type and every misuse fails to compile. Change a size and the size assert fails. Miss a row in an `EnumArray` and the build fails. Design so that the compiler, not memory, finds what must change.

**Principle 15.2 — Drill the likely changes.** Get three likely changes from the user (or the backlog, cited). For each, list every edit and count the change radius: existing function bodies edited (new files, functions, rows, variants and spine lines count as 0; for a new variant, count the compiler-listed switch sites). A drill passes when the change lands as new tables, transforms, rows, variants or spine lines at a radius the user accepts. Record the drill table per `codebase-clean-code/DECISIONS.md`.

**Principle 15.3 — Wear one hat at a time.** Fowler: when refactoring, change structure and not behavior; when adding features, change behavior and not structure. Commit between hats. In the `tdd` loop, refactoring belongs to the review stage, after green.

**Principle 15.4 — Make the change easy, then make the easy change.** Before a feature, refactor so the feature becomes a small edit (preparatory refactoring). Each step is small, tested and committed. `refactoring-patterns` holds the smell → move catalogue, read through §2.3.

**Principle 15.5 — Abstract at the evidence, not before.** Speculative generality is a smell, and `ponytail` cuts it: no interface with one implementation, no factory for one product, no config for a value that never changes. Introduce a seam at the second real case or when a drill needs it; extract a function at the third use (§2.4). Until then, a little duplication is cheaper than the wrong abstraction. `ponytail` decides how little code to write, never what shape the data takes (`systems` rule 2).

**Principle 15.6 — Record significant decisions.** Every seam gets a seam record (axis, evidence, owner, rung and why the rung below fails, cost on three axes, drills passed, proof, revisit-when) in the format of `codebase-clean-code/DECISIONS.md`. Hard-to-reverse decisions get an ADR in `docs/adr/` (`domain-modeling/ADR-FORMAT.md`). `ARCHITECTURE.md` follows the template in `DECISIONS.md` (module DAG and what enforces it, spines, tables with owner, writers, readers, capacity and arena, seams, invariants, adding a feature, change drill), so the next person can change the code deliberately rather than by accident.

**Principle 15.7 — Test behavior, not implementation.** Tests that assert on observable results at public seams survive refactoring; tests that mock internal collaborators or test private functions break with every change (`tdd` anti-patterns). matklad: test features, not code. Khorikov: a good test protects against regressions _and_ resists refactoring.

**Principle 15.8 — Change untested code with the Legacy Code Change Algorithm.** Identify change points, find test points, break dependencies with the smallest technique (parameterize, sprout, skin and wrap, extract interface — at the outer edge, never as trait objects in hot loops), write characterization tests, then change (`legacy-code`). A rewrite keeps the old code alive as the oracle until the new slice diffs clean against it (`rewrite-clean`).

**Principle 15.9 — Leave the code a little better than you found it, and delete first.** The Boy Scout Rule keeps quality from decaying one exception at a time; broken windows invite more (Hunt and Thomas). When improving a block, delete before improving: code reachable from nothing, a wrapper whose body is one call, an abstraction never repeated (`codebase-improvement` step 4.1). Deprecations and large-scale changes follow `engineering-at-scale`.

**How to verify Part IV:** the build graph rejects forbidden imports and cycles; fitness-function tests run in CI; exhaustive switches are enforced by a test; every seam has a record and every drill a numeric radius; refactorings land with the test suite green at every commit; the `codebase-clean-code` review checklist passes with file:line evidence.

---

## 7. Part V — Contained Failure

Skills: `assertions` (+ `zig.md`, `rust.md`), `zig/memory.md`, `rust/memory.md`, `rust/types.md`, `doc-comments`, `api-design` (FFI boundaries).

A failure is contained when it cannot travel past the module where it happened, either as corrupted state or as an error nobody knows how to handle. Containment rests on one distinction and a handful of zero-cost mechanisms.

### Chapter 16. Errors Are Not Bugs

**Principle 16.1 — Separate operating errors from programmer errors, and classify every check.** They need opposite treatments.

|                         | Operating error                                                                     | Bug (programmer error)                                                                          |
| ----------------------- | ----------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Examples                | Bad input, missing file, full disk, out of memory, non-convergence, singular matrix | Violated invariant, index out of range, impossible state, wrong derivative, broken precondition |
| Source of the bad value | A file, socket, user, CLI flag, plugin or allocator                                 | The caller broke a documented precondition, or this function's own logic                        |
| Expected?               | Yes, part of the contract                                                           | No, a defect in the code                                                                        |
| Mechanism               | Returned as a value (error union, `Result`)                                         | Assertion that stops the program                                                                |
| Who handles it          | The nearest caller that can decide                                                  | Nobody; the developer fixes the code                                                            |
| Containment             | Handled or translated at the module boundary                                        | Stopping prevents corrupted state from spreading                                                |

Input from a trust boundary is validated with an error return once, at the boundary; past that point the validated property is a precondition and gets asserted. The boundary function owns the error; every function behind it owns an assert (`assertions` step 1). No assert tests a value that came straight from outside the program.

**Principle 16.2 — Return operating errors as values.** An error value travels exactly as far as the code explicitly lets it, and the compiler forces each caller to handle or forward it. In Zig an error is a small integer in the return value; in Rust a `Result` is an enum. Neither uses unwinding tables or hidden control flow, so the cost is the same branch a hand-written check would take.

**Principle 16.3 — Stop on bugs.** Continuing after an invariant fails spreads corrupted state into every later computation. Stopping keeps the damage local and leaves a precise report (Hunt and Thomas: dead programs tell no lies). A correctness bug becomes a liveness bug, and every fuzz run and test becomes a contract check (TigerStyle). Never catch a bug in order to continue, and never assert on something a user can legitimately supply.

### Chapter 17. Zero-Cost Containment Mechanisms

**Principle 17.1 — Give each module a narrow, explicit error set.** A module's public functions return its own named errors, not a catch-all. Callers can then `switch` over errors exhaustively, and adding a new error is a compile error at every handler. Every error is documented with the condition that produces it and the state the call leaves behind (`doc-comments` rank 4).

```zig
pub const ParseError = error{ UnexpectedToken, NumberTooLarge, UnknownElement };

pub const Diagnostic = struct { line: u32 = 0, column: u32 = 0 };

/// Parses one element card.
/// Returns `error.UnknownElement` when the card's first letter names no element
/// kind; `diag` then holds the line and column. Leaves no allocation behind on error.
pub fn parseElement(src: []const u8, diag: *Diagnostic) ParseError!Element {
    // On failure: fill diag with where and why, then return the error.
}
```

In Rust, library errors are `thiserror` enums, one per module, converted at the boundary with `From`. Avoid `anyerror` and `Box<dyn Error>` across module boundaries: both lose exhaustiveness, and the box adds an allocation and a vtable. `unwrap`/`expect` appear only for stated invariants, and every `expect` message names its invariant (`rust/memory.md`).

**Principle 17.2 — Carry context in a caller-owned diagnostic, not an allocated string.** The `Diagnostic` out-parameter above records line, column and cause without allocating. Error messages are formatted later, once, on the cold path. Zig's error return traces add the call path in Debug and ReleaseSafe builds. Zig 0.17 removed `errdefer |err|` capture: to log an error on the way out, move the body into a caller (`inner() catch |err| { log(err); return err; }`, per `zig/migration-0.17.md`).

**Principle 17.3 — Fallible first, infallible after.** Do everything that can fail (allocate, validate, look up) before changing any visible state. Then commit with operations that cannot fail. A failure in the first phase leaves the module exactly as it was; the second phase cannot fail.

```zig
pub fn addDevice(s: *Store, gpa: Allocator, d: DeviceSpec) error{OutOfMemory}!DeviceId {
    // Phase 1: everything that can fail. Nothing visible has changed yet.
    try s.params.ensureUnusedCapacity(gpa, 1);
    try s.nodes.ensureUnusedCapacity(gpa, d.nodes.len);
    // Phase 2: infallible commit.
    const id: DeviceId = @fromBackingInt(@as(u32, @intCast(s.params.items.len)));
    s.params.appendAssumeCapacity(d.params);
    s.nodes.appendSliceAssumeCapacity(d.nodes);
    std.debug.assert(s.params.items.len == @backingInt(id) + 1); // exit invariant
    return id;
}
```

**Principle 17.4 — Use `errdefer` to undo partial work.** When a multi-step operation cannot be split into fallible and infallible phases, register the rollback right after each step, on the next line after each allocation that crosses a `try` (`zig/memory.md`). Any later failure runs the rollbacks in reverse order, so no half-built state escapes.

**Principle 17.5 — Make invalid states unrepresentable.** Distinct ID types, tagged unions, non-optional pointers, enums instead of strings, refined types from a single `parse`/`TryFrom`, and narrow integer types remove whole classes of errors at compile time. Typestate belongs only at an API boundary (`rust/types.md`). An error that cannot be written cannot propagate.

**Principle 17.6 — Define errors out of existence.** Ousterhout: redefine an operation so the error case is normal. Deleting an absent key succeeds, because the postcondition "the key is gone" holds. Clamping a range to valid bounds can replace an error, when clamping is the correct meaning. Every error path removed is one fewer path that can propagate.

**Principle 17.7 — Own state per module, and share it read-only.** Each module owns its tables (Principle 14.2). Other modules receive read-only slices or handles, or append to a request table. There is no global mutable state, so a bug in one module cannot write into another's data. With an arena per unit of work, a failed unit is discarded wholesale.

**Principle 17.8 — Bound every resource.** Every table has a named capacity with a unit and the code asserts against it. A queue asserts `count < capacity` before a push, and the push returns an operating error when the capacity is a user-visible limit. A `while` loop that is not a `for` over a slice carries an iteration counter and asserts it stays under its bound. A loop meant never to terminate asserts that, so a fall-through is a crash. A bounded queue rejects overload at its entrance instead of exhausting memory far away; bounded loops turn "hangs forever" into a detectable failure (`assertions` step 7).

**Principle 17.9 — Assert densely, in both positive and negative space.** Follow `assertions` steps 1–6:

1. **Classify** every check (Principle 16.1).
2. **Assert the entry and the exit.** Every argument property the body relies on (lengths, ranges, non-overlap, sortedness, a handle's generation), and at least one property of the result or the state left behind. Keep each assert cheaper than the work it guards; an O(N) check of an O(1) operation goes behind a comptime verification flag. Every assert reachable from a public entry goes into the doc comment (`Asserts that ...` in Zig, `# Panics` in Rust).
3. **Pair** each enforced property across two code paths the data crosses: before a write and after the read; in `encode` and `decode`; in `push` and `pop`; in the producer and the consumer.
4. **Cover the negative space.** Assert both arms of a classification, implications as `if (a) assert(b);`, and the state that must not exist (after `free`, the slot is on the free list).
5. **Split compound asserts.** `assert(a); assert(b);`, never `assert(a and b)`, so the panic names the failed condition. The split form costs nothing in the loop.
6. **Assert constants at compile time.** Every constant another is derived from, masked with or divided by has its relationship asserted at comptime, for free.

The density target is at least **two asserts per function on average** (TigerStyle). Audit with `grep -c 'assert'` against the function count per touched file.

```zig
/// Solves one step in place.
/// Asserts that `x.len == m.n`, `b.len == m.n`, and `m.n > 0`.
fn solveStep(m: *const Matrix, x: []f64, b: []const f64) void {
    std.debug.assert(m.n == x.len); // positive space
    std.debug.assert(m.n == b.len);
    std.debug.assert(m.n > 0);      // negative space: empty systems never reach here
    // ...
}
comptime {
    std.debug.assert(max_terminals <= 8); // free: checked by the compiler
}
```

**Principle 17.10 — Budget runtime checks deliberately.** This is where "zero overhead" and "contained failure" meet, and the project resolves the tension with evidence (§2.5). Zig's `std.debug.assert` is checked in Debug and ReleaseSafe (`std.lang.Optimize.safe` in 0.17). In ReleaseFast (`.fast`) it becomes an optimizer hint with no check, so a violated assertion there is undefined behavior. One assert can have **negative** cost: in a safe build, an up-front length assert before an indexed loop that stores through several slices removes the per-iteration bounds checks and lets the loop unroll (probed in `assertions/zig.md` and `assertions/rust.md`). The policy:

1. Comptime assertions are always on, because they cost nothing.
2. Boundary and control code (parsers, the C ABI, schedulers, state machines) ships with safety on (`-O ReleaseSafe`), where the checks are cheap relative to the work.
3. Hot kernels may run without checks (`-O ReleaseFast`, or `@setRuntimeSafety(false)` in one scope) **only after** fuzzing, property tests and differential tests have exercised them with checks on.
4. Every hot indexed loop over two or more slices has its length relationship asserted up front, and any performance claim about it cites a probe verdict.
5. Every disabled check is a recorded decision in the design review, not a default.

In Rust the same split is `assert!` versus `debug_assert!`, plus the `overflow-checks` profile setting; `unsafe { std::hint::assert_unchecked(..) }` is allowed only in FFI crates after a probe shows a check a safe `assert!` cannot remove.

### Chapter 18. Trust Boundaries

**Principle 18.1 — Validate once, at the edge, into strong types.** Netlists, layouts, Touchstone files, command-line arguments and network messages are parsed at the boundary into the core's types (Principle 14.7). Errors at the edge become diagnostics for the user. Inside, the code relies on the types and asserts invariants.

**Principle 18.2 — A C ABI is a hostile boundary.** Every exported function validates handles and pointers, returns documented error codes, never panics or unwinds across the boundary, and states its thread-safety. Handles are generational (Principle 5.3), so a use-after-free by the caller becomes an error code instead of memory corruption. In Rust, `unsafe` lives only in the FFI crate, every block under a `// SAFETY:` comment, with `clippy::undocumented_unsafe_blocks = "deny"` (`rust/memory.md`). FFI design follows `api-design` (`api-design/rust.md`, `api-design/zig.md`).

**Principle 18.3 — Recover locally where a local recovery exists.** A solver that fails to converge returns an error with diagnostics. The analysis driver, which owns the step size, may retry with a smaller step (`spice-engine/NUMERICS.md`). Recovery happens at the one level that has the information to choose, and nowhere else.

**Principle 18.4 — Pay for isolation only where trust is genuinely absent.** Running untrusted third-party code may justify a separate process or sandbox (ladder rung 9). That is a real runtime cost, so it belongs at a rare, coarse boundary, never inside a hot loop, and it speaks through snapshots in and request tables out, under capabilities.

**How to verify Part V:** allocation-failure injection on every allocating path (`std.testing.checkAllAllocationFailures` detects swallowed failures); fuzzing every boundary parser, with the declared error set as part of the oracle; stateful fuzzing of the C ABI against a model of valid states; tests that inject non-convergence, singular matrices and NaN to check graceful errors (Part VI); the `assertions` file audit (two asserts per function, every step's criterion, tests passing in a safe build).

---

## 8. Part VI — Testing: Code Is Only as Good as Its Tests

Skills: `test-plan` (+ `DOMAINS.md`, `TECHNIQUES.md`, `SOURCES.md`), `tdd` (+ `tests.md`, `mocking.md`), `assertions`, `zig` (fuzzing, `checkAllAllocationFailures`, probes), `rust`, domain testing files (`spice-engine/TESTING.md`, `compiler-construction/FIXTURES.md`, `gpu-parallel-algorithm-thinking/verification.md`, `gpu-kernel-optimization/references/memory-model.md`), `engineering-at-scale` _(explicit)_.

This is the central claim of this file: **untested code is not good code, and code with weak tests is not good code either.** Every earlier part makes promises about size, speed, changeability and containment. Tests are how those promises become facts, and they are how code stays good while it changes. The `test-plan` skill's goal is total bug elimination at the source; its steps are the procedure for R7.

### Chapter 19. Why Testing Decides Quality

**Principle 19.1 — A test suite is only as strong as its oracles.** Every test needs an answer to one question: how do we know this output is wrong? An **oracle** is the independent thing that says so; every test layer names its oracle, or it is not a test. Without an oracle, a fuzzer finds only crashes and coverage measures only execution. In numerical and system code, the dominant bug is a wrong answer that does not crash.

**Principle 19.2 — Learn from SQLite's history: each "complete" stage was overtaken.** Andrew Kelley's talk at Systems Distributed '26 lists five sources of bug discovery, taken from Richard Hipp's SQLite talk: (1) whatever developers happen to hit, (2) whatever users happen to report, (3) full machine-code branch coverage, (4) fuzzing with properties checked, (5) LLM review. Rungs 1–2 are luck; the work is to move discovery to 3–4. SQLite's record shows what each stage missed:

| Year (approx.) | Stage reached          | What found bugs next                  | What was missing                                                             |
| -------------- | ---------------------- | ------------------------------------- | ---------------------------------------------------------------------------- |
| 2009           | 100% MC/DC coverage    | Coverage-guided fuzzers               | Inputs that flip branches nobody thought to reach                            |
| 2014           | Profile-guided fuzzing | Query fuzzing (Rigger's partitioning) | A semantic oracle: results that must agree                                   |
| 2019           | Query fuzzing          | LLMs                                  | Adversarial inputs, such as a million-row quicksort that overflows the stack |

Each time, the fix was a **new oracle or a new input distribution**, not more coverage. Kelley's own caveat matters as much as his list: non-trivial improvements push a project back to the top, because new code brings new bugs.

**Principle 19.3 — Coverage and fuzzing are necessary, not sufficient.** They shrink accidental and user-reported bugs dramatically. By construction they miss these classes, each of which needs its own technique:

| Bug class                           | Why coverage + fuzzing miss it                      | What catches it                                                |
| ----------------------------------- | --------------------------------------------------- | -------------------------------------------------------------- |
| Wrong output that does not crash    | Coverage measures execution, not checking           | Oracles, dense assertions, mutation testing                    |
| Missing code (faults of omission)   | Coverage only sees code that exists                 | Spec-driven tests, reference implementations                   |
| Misread specification               | Tests share the developer's wrong belief            | An independent oracle written from the spec                    |
| Value-dependent numerical error     | A covered path counts as covered with benign values | ULP/tolerance oracles, residuals, exhaustive small domains     |
| Performance and resource exhaustion | Neither measures time or stack                      | Benchmarks with thresholds, worst-case inputs, explicit bounds |
| Concurrency interleavings           | Coverage is per thread                              | Deterministic simulation, loom/shuttle, TSan                   |
| Target and build differences        | One target says nothing about another               | Run on every shipped target; CPU-vs-GPU differential           |
| Feature combinations                | One configuration suppresses behaviors              | Swarm testing, configuration matrices                          |
| Deep state                          | Fuzzers rarely reach long sequences                 | Stateful property tests, simulation                            |

**Principle 19.4 — Every bug report is evidence of a missing oracle.** When a user, a colleague or an LLM finds a bug, add the example test, then ask which oracle or generator would have found it, and add that too (§2.6). Reports from rungs 1, 2 and 5 are signals that the oracle set is incomplete.

### Chapter 20. Oracles and Testability

**Principle 20.1 — Use several independent oracles per component, and never a tautological one.** The kinds, from strongest to weakest:

1. **Analytic answers and spec examples:** closed-form results (an RC step response, Ohm's law, a parallel-plate capacitance) and hand-worked values from a standard, paper or datasheet.
2. **Certificates:** cheap checks of an expensive answer. Recompute the KCL residual of a converged circuit with a plain device evaluation. Check a linear solve with a scaled residual ‖Ax − b‖ / (‖A‖‖x‖ε). Compare a Jacobian with finite differences. Run an independent DRC/LVS on a routed layout.
3. **Reference implementations (differential):** another simulator, another compiler, a naive scalar loop, a dense solver, a bitmap rasterizer, the CPU path, the `W == 1` instantiation of a SIMD kernel.
4. **Round-trip / inverse:** parse↔print, encode↔decode, serialize↔load.
5. **Metamorphic relations:** transformations of the input with a known effect on the output.
6. **Models:** a simple data structure or state machine that defines correct behavior for a stateful API.
7. **Golden / snapshot:** stable output reviewed once by a human, with recorded provenance.
8. **Assertions in the code:** the oracle every fuzzer and simulator inherits automatically.

No oracle may recompute the answer the way the code under test does. `expect(add(a, b)) == a + b`, a snapshot derived by hand the same way, or a constant asserted equal to itself passes by construction and does not count (`tdd`, tautological tests).

**Principle 20.2 — Assertions are the fuzzer's eyes.** A fuzzer or simulator can only report what an assertion or comparison flags. Dense assertions (Principle 17.9) turn silent corruption into a crash a fuzzer can see, and multiply the value of every other technique.

**Principle 20.3 — Inject every source of nondeterminism through a comptime parameter.** Deterministic testing needs control over the allocator, I/O, the clock, randomness, iteration order and the thread scheduler. Passing them as comptime types (Principle 14.5) gives tests full control while production compiles to direct calls. Testability costs nothing at runtime. (`rewrite-clean` uses the same move to make old and new code see identical inputs.)

```zig
pub fn Executor(comptime Scheduler: type) type {
    return struct {
        sched: Scheduler,
        pub fn run(self: *@This(), dag: *const Dag, out: *Results) !void {
            while (self.sched.next(dag)) |node| try evaluate(dag, node, out);
        }
    };
}
// Production: Executor(ThreadPoolScheduler). Tests: Executor(SeededScheduler).
```

**Principle 20.4 — Make results reproducible.** The same input and seed must give the same bytes. Fix floating-point reduction order rather than accepting run-to-run drift; otherwise you lose the ability to compare runs exactly. Check it: run twice and byte-compare; run parallel and sequential and byte-compare.

**Principle 20.5 — Test at agreed seams, one vertical slice at a time.** Tests verify behavior through public interfaces at **seams**. Before writing any test, write down the seams under test, each with a one-line note on what it catches and what it misses, and confirm them with the user; no test is written at an unconfirmed seam. Then run red → green: write the failing test first, then only enough code to pass it, one seam and one slice per cycle. Never write all tests first and all implementation after (horizontal slicing tests imagined behavior). Refactoring happens after green, in review (`tdd`).

### Chapter 21. Techniques

Each technique lists what it catches, its oracle and its cost. `test-plan/TECHNIQUES.md` has the full catches/misses/oracle/cost table and Zig and Rust tooling; `test-plan/DOMAINS.md` has the bug classes and recommended stacks per domain (compiler, stateful, numerical, GPU, SIMD, geometry/EDA, parser/library). The standard build order, cheapest first, stopping when the exit criteria hold (`test-plan` step 4):

1. Asserts in production code, with safety checks on in test builds.
2. Example tests at public seams: spec examples, and every past bug as a regression test.
3. Property and differential tests with generated inputs and shrinking.
4. Coverage-guided fuzz targets at every untrusted-input boundary, using the property and differential checks as fuzz oracles.
5. Exhaustive tests for every small domain.
6. Deterministic simulation for stateful or concurrent systems.
7. Fault injection.
8. Coverage measurement to find gaps.
9. Non-functional checks: benchmarks, adversarial sizes, determinism, every shipped target and ISA.
10. Mutation testing to check that the tests above can fail.

**21.1 — Data-driven tests with one `check` function.** matklad's architecture: test features, not code, and make adding a case cost one line. A single `check(input, expected)` helper drives the component through its public interface. _Catches:_ regressions in specified behavior. _Cost:_ low.

**21.2 — Property-based and stateful testing.** Generate inputs, check properties (round-trip, idempotence, invariants). For stateful APIs, generate random operation sequences against both the real system and a simple model, compare after each step, and shrink failures (QuickCheck, Hypothesis, `proptest`). _Catches:_ edge cases and sequencing bugs. _Oracle:_ properties or a model. _Cost:_ low to moderate; good properties take skill.

**21.3 — Exhaustive small domains.** When the domain is small, test all of it: all 256 `u8` values, all `u16` values, every length from 0 to twice the vector width, every mask pattern of one vector width, all enum combinations, all 2³² `f32` inputs to an elementary function. Enumeration beats sampling when it is affordable (matklad, "Generate All the Things").

**21.4 — Coverage-guided fuzzing, the Zig way.** Zig 0.16 and 0.17 fuzz tests receive a `*std.testing.Smith`, a generator with methods such as `value`, `valueRangeAtMost`, `index`, `eos`, `bytes` and `slice`. Facts that shape how to use it:

- A plain `zig build test` replays only the given corpus plus one empty input. Real fuzzing runs with `zig build test --fuzz` (or `--fuzz=1M` for a bounded run).
- In fuzz mode, `std.testing.allocator` is reset per input and leaks fail the run, so a leak is a finding automatically. In 0.17 it is a `SafeAllocator`.
- The built-in fuzzer has no comparison-operand feedback, so it struggles to guess magic values. Build valid structure with Smith (structure-aware generation) instead of hoping random bytes parse.
- Save crashing inputs into the corpus, checked into the repo. The corpus then runs on every normal test run as a regression suite.

```zig
fn parseThenPrintRoundTrips(_: void, s: *std.testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const src = buf[0..s.slice(&buf)];
    var diag: Diagnostic = .{};
    const elem = parseElement(src, &diag) catch return; // declared errors are fine
    var out: [4096]u8 = undefined;
    const printed = try formatElement(elem, &out);
    const again = try parseElement(printed, &diag);        // must parse
    try std.testing.expectEqualDeep(elem, again);          // and mean the same
}

test "fuzz element parser" {
    try std.testing.fuzz({}, parseThenPrintRoundTrips, .{
        .corpus = &.{ "R1 a b 1k", "C1 a 0 1p", "V1 in 0 DC 1.8" },
    });
}
```

Because `parseElement` returns a closed error set, the compiler guarantees no undeclared error escapes; the fuzzer looks for panics, leaks and round-trip mismatches. In Rust, use `cargo-fuzz` with `arbitrary`.

**21.5 — Differential testing.** Run the same input through two implementations and flag disagreement within a tolerance: ngspice or VACASK for a simulator (`spice-engine/TESTING.md`), KLayout or Netgen for physical verification, the scalar loop for a SIMD kernel, the CPU backend for a GPU backend, `--jobs=1` for `--jobs=N`. _Misses:_ bugs both sides share. _Cost:_ cheap once a harness exists; triaging legitimate differences is the real work.

**21.6 — Metamorphic testing.** When no oracle exists, check relations between outputs. Examples: renumbering nodes leaves a circuit's results unchanged; scaling all impedances by k scales currents by 1/k; translating or rotating a layout leaves its DRC violations unchanged up to the same transform; inserting dead code leaves a compiled program's behavior unchanged (EMI). _Cost:_ cheap per relation; finding good relations is the intellectual work.

**21.7 — Deterministic simulation and swarm testing.** Run concurrent or stateful code single-threaded against simulated time, I/O and scheduling, all driven by one seed, so any failure replays exactly (FoundationDB, TigerBeetle's VOPR). Swarm testing randomly disables features per run and has found substantially more distinct crashes than a single hand-tuned configuration. _Cost:_ high up front, because the code must inject its nondeterminism (Principle 20.3).

**21.8 — Fault injection.** Fail the Nth allocation for every N, fail I/O after N operations, inject timeouts, singular matrices, NaN device outputs and non-convergence. Zig provides allocation-failure enumeration directly, and every multi-allocation function has this test (`zig` skill step 3):

```zig
fn loadAndSolve(allocator: std.mem.Allocator, deck: []const u8) !void {
    var sim = try Sim.init(allocator, deck);
    defer sim.deinit();
    _ = try sim.operatingPoint();
}

test "every allocation failure is handled and nothing leaks" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, loadAndSolve, .{small_deck});
}
```

It runs the function once with unlimited memory, then once per allocation with that allocation failing, and reports an error if the code swallowed an induced failure.

**21.9 — Sanitizers and safety modes.** Run tests in Debug and ReleaseSafe (Rust: debug assertions and `overflow-checks` on), so every assert executes. Use `-fsanitize-thread` for data races and `-fsanitize-c` for C code. Use NVIDIA compute-sanitizer (memcheck, racecheck, initcheck, synccheck) for GPU kernels and Miri for unsafe Rust.

**21.10 — Coverage as a gap finder, not a target.** Marick: if coverage shows a weakness, there is probably a similar weakness coverage cannot show. Every uncovered branch is either tested, proven unreachable (an assert), or deleted. Tooling today: kcov line coverage for Zig through `--test-cmd`; LLVM source-based coverage for Rust (branch coverage on nightly; rustc's MC/DC support was removed in 2025). No tool reports machine-code branch coverage for Zig, so use coverage marks (TigerBeetle, Ferrous Systems): a specific test asserts that it reached a specific line, with no tooling.

**21.11 — Mutation testing.** Deliberately break the code and check that a test fails. It measures whether tests check outputs, which coverage cannot. Use `cargo-mutants` for Rust. For Zig, a script that flips one comparison at a time and runs `zig build test` is a usable start. The codegen probe's own check (break the `gen_` body on purpose and see `zig build test` turn red) is the same idea applied to residue. _Cost:_ high CPU; run nightly or weekly on changed files.

**21.12 — Golden and snapshot tests, with provenance.** A golden file is only as good as its origin. Record where each expected value came from (analytic, a named reference tool and version, a re-derivation), and keep re-derived expectations separate from historical snapshots. Compiler goldens and conformance fixtures follow `compiler-construction/FIXTURES.md`.

**21.13 — Numerical oracles.** Compare with mixed tolerance |a − e| ≤ atol + rtol·|e|, with the tolerance justified per quantity. Use ULP distance for elementary functions and test every `f32`. Use LAPACK-style scaled residual ratios, which scale with conditioning, rather than stored answers. Verify integrators with the method of manufactured solutions: run three step sizes and check that the observed order of accuracy matches theory (backward Euler order 1, trapezoidal order 2). Circuit-simulator specifics (stamping, sparse LU replay, Newton limiting, timestep control, device derivatives) are in `spice-engine` and its `NUMERICS.md`, `LINEAR.md` and `TESTING.md`.

**21.14 — SIMD and GPU.** For SIMD, the scalar (`W == 1`) instantiation is the oracle: sweep every length from 0 past three times the lane count, every alignment offset, and injected edge values (NaN, ±0, INT_MIN), on every ISA level you ship (`zig/simd-first.md`, `rust/simd-first.md`, `simd-first`). For GPU, compare with the CPU backend, test launch sizes that are not multiples of the block size (and 0, and near 2³¹), and run memory-model litmus tests on real hardware (`gpu-kernel-optimization/references/memory-model.md`). Parallel reformulations are verified against the sequential schedule (`gpu-parallel-algorithm-thinking/verification.md`). A backend that has never run on hardware is untested, whatever its assembly checks say.

**21.15 — Performance is tested too.** A benchmark with a regression threshold is a test, and so is a codegen probe wired into the build. Without them, the zero-overhead claims in Part III decay silently. Profile first (`data-oriented-design/measurement.md`); a change that does not move the number is reverted, and reporting that is a complete result.

**21.16 — Lightweight formal methods for small kernels.** A bounded model checker such as Kani (for Rust) proves a property for all inputs up to a bound. Use it on small pure functions: geometry predicates, index arithmetic, interval math.

### Chapter 22. Process: Gating and Release

**Principle 22.1 — Main always passes all tests.** Graydon Hoare's "Not Rocket Science Rule": test the merge result before it lands, with a merge queue. First check that CI runs the tests at all: a project with no CI running its tests has no evidence its code works today.

**Principle 22.2 — Test in tiers, and keep fast tiers fast.** A slow gate gets bypassed. Budgets from `test-plan` step 5:

| Tier               | Budget    | Contents                                                                                                                                                                                                                        |
| ------------------ | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Local / pre-commit | < 10 s    | Format, compile, fast unit and property tests (small iteration count) for the touched modules                                                                                                                                   |
| Merge (required)   | < 15 min  | All example, property and differential tests; sanitizers; Debug and ReleaseSafe; every target; fuzz corpus replay; short fuzz on changed targets; determinism check; codegen probes; fitness functions; coverage must not drop  |
| Nightly            | Hours     | Long fuzzing per target, many simulation seeds, high-iteration properties, metamorphic suite, differential runs against references, GPU runners, TSan, benchmarks with regression thresholds, mutation testing on changed files |
| Release            | Unbounded | Release checklist (Principle 22.6), full target matrix, reference-tool comparison on the full fixture set, long fuzz campaigns, soak runs                                                                                       |

Every fuzz or simulation failure becomes a checked-in regression input.

**Principle 22.3 — Flaky tests are bugs.** A flaky test makes its gate meaningless: fix it or quarantine it the same day, and never retry silently in the merge gate. With seeded, deterministic tests, "flaky" becomes "reproducible from seed."

**Principle 22.4 — Ratchet, don't target.** Coverage, the count of differential agreements, conformance pass lists and benchmark baselines may only improve or hold. Compare lists of names, not counts, so a new failure cannot hide behind a new pass.

**Principle 22.5 — Expect tests to outweigh code.** Hipp's conclusions: testability must be a design objective; test cases should be at least ten times the code; 10 to 20% of the code exists only for testing; expect to spend most of your time testing.

**Principle 22.6 — Release on explicit exit criteria, each a number or a yes/no a script can check.** Before a release:

1. The corpus passes, with only annotated expected failures.
2. Every fuzz target has run for an agreed number of CPU-hours with no new crash, and corpus growth (coverage) has plateaued.
3. Differential agreement holds for 100% of fixtures within stated, justified tolerances, and every disagreement is triaged.
4. Parallel and sequential runs are byte-identical; simulation is clean on the agreed number of seeds.
5. Every supported target and backend has passed on real hardware or an emulator; anything untested is labeled unsupported.
6. No coverage, conformance, benchmark or mutation-score ratchet has regressed; every coverage exclusion is justified in a comment.
7. Zero open crash bugs and zero quarantined tests on core modules.
8. A written list of known gaps exists.

**Principle 22.7 — Write the plan down.** `TESTING.md` holds the domains, the bug class → oracle → layer table, harness sketches, the gate table and the exit criteria, and every gate runs from one command (`zig build test`, `cargo test`, CI) (`test-plan` step 7).

---

## 9. Part VII — Synthesis

### Chapter 23. One Subsystem, End to End

This chapter builds a small device store for a circuit simulator and runs it through the design review. The store holds resistors and stamps their conductances into a matrix on every Newton iteration. Domain skill: `spice-engine`.

**R0 — Scope.** New module, hot (the stamp loop runs every Newton iteration over every resistor; evidence: profile of the existing solver loop). Stages: full.

**R2 — Data.** Up to a million resistors. Each Newton iteration reads two node indices and one conductance per resistor. Resistors are added while the netlist is built, then frozen while solving. The variant set (resistor, capacitor, diode, …) is closed.

| Table       | Owner         | Fields: width (range)                                               | Layout                 | Capacity        | Lifetime                                  |
| ----------- | ------------- | ------------------------------------------------------------------- | ---------------------- | --------------- | ----------------------------------------- |
| `resistors` | `devices.zig` | `a`, `b`: `NodeId` u32 (node count ≤ 2³²−2); `g`: f64 (finite, > 0) | SoA (`MultiArrayList`) | `resistors_max` | `netlist_arena` (build → end of analysis) |

Transforms: `addResistor: netlist card → resistors` (build phase); `stampResistors: resistors (const) → matrix` (solve phase).

**R3 — Owners and spine.** `devices.zig` owns `resistors`. The Newton spine calls `stampResistors` then the solver, one line each. Mutation happens only in the build phase; the solve phase receives `*const Devices`, so no solver bug can corrupt the netlist.

**R4 — Seams.** One axis: the matrix type (dense for tests, sparse for production — two cases today). Rung 5, comptime parameter; rung 4 fails because the choice is fixed per build, not per element, and a per-element switch would be residue. Device kinds are a second axis with three kinds today: one table per kind (rung 3), so the hot loop has no kind switch.

**R5 — Drill.** D1 "add capacitors" (from the backlog): a new table, a new `addCapacitor`, a new stamp transform, one spine line. Radius 0. If a `DeviceKind` enum exists for reporting, its switch sites are compiler-listed.

**The code (Zig 0.17).**

```zig
//! Devices: netlist cards → `resistors` table (build phase); `resistors` → MNA stamps (solve phase).
//! Owner of `resistors`. Reads nothing outside its arguments. Cites: MNA stamping per `spice-engine`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const NodeId = enum(u32) { ground = 0, _ };
pub const ResistorId = enum(u32) { _ };

/// Capacity of the resistor table; a user-visible limit.
pub const resistors_max: u32 = 1 << 20;

const Resistor = struct { a: NodeId, b: NodeId, g: f64 }; // g = 1 / ohms, the form the solver uses
comptime {
    assert(@sizeOf(Resistor) == 16);
}

pub const Devices = struct {
    resistors: std.MultiArrayList(Resistor) = .empty,
    node_count: u32,

    pub const AddError = error{ OutOfMemory, InvalidValue, UnknownNode, TooManyResistors };

    /// Adds one resistor between nodes `a` and `b`.
    /// Returns `error.InvalidValue` when `ohms` is not finite and positive (NaN included),
    /// `error.UnknownNode` when a node is out of range, `error.TooManyResistors` at
    /// `resistors_max`, and `error.OutOfMemory`; on any error the table is unchanged.
    pub fn addResistor(d: *Devices, gpa: Allocator, a: NodeId, b: NodeId, ohms: f64) AddError!ResistorId {
        // Boundary: these are operating errors, validated once.
        if (!(ohms > 0) or !std.math.isFinite(ohms)) return error.InvalidValue;
        if (@backingInt(a) >= d.node_count or @backingInt(b) >= d.node_count) return error.UnknownNode;
        if (d.resistors.len >= resistors_max) return error.TooManyResistors;

        try d.resistors.ensureUnusedCapacity(gpa, 1); // fallible first
        const id: ResistorId = @fromBackingInt(@as(u32, @intCast(d.resistors.len)));
        d.resistors.appendAssumeCapacity(.{ .a = a, .b = b, .g = 1.0 / ohms }); // infallible after

        assert(d.resistors.len == @as(usize, @backingInt(id)) + 1); // exit invariant
        return id;
    }
};

/// Stamps every resistor's conductance into `m`.
/// Asserts that every stored conductance is finite and positive (set by `addResistor`).
pub fn stampResistors(comptime Matrix: type, m: *Matrix, d: *const Devices) void {
    const s = d.resistors.slice();
    assert(s.len <= resistors_max);
    for (s.items(.a), s.items(.b), s.items(.g)) |a, b, g| {
        assert(g > 0);                // split asserts: the panic names the failed one
        assert(std.math.isFinite(g));
        m.add(a, a, g);
        m.add(b, b, g);
        m.add(a, b, -g);
        m.add(b, a, -g);
    }
}
```

**R6 — Containment.** Invalid values are operating errors returned to the parser, which reports them with a line number. Allocation happens before any visible change. The solve phase is read-only on the netlist. Every table has a capacity; the stamp loop iterates a finite slice. Check budget: the build phase ships ReleaseSafe; the stamp loop is a candidate for ReleaseFast only after the fuzz and differential tests below run clean with checks on.

**R7 — Test plan.** Seams under test (confirmed with the user): `Devices.addResistor` and `stampResistors`. Six oracles, each cheap:

| Bug class                                  | Oracle                                                                                                                    | Layer           | Tier                           |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------- | --------------- | ------------------------------ |
| Wrong stamp sign or position               | Analytic: a divider of two 1 kΩ resistors from 1 V gives 0.5 V at the midpoint                                            | Example test    | Merge                          |
| Sparse format bugs                         | Differential: sparse and dense matrices are identical, exactly, because both receive the same additions in the same order | Fuzz (Smith)    | Merge (corpus), nightly (long) |
| Index mix-ups                              | Metamorphic: renumbering nodes permutes the matrix by the same permutation                                                | Property        | Merge                          |
| Leaks and swallowed OOM                    | `checkAllAllocationFailures` over building a netlist                                                                      | Fault injection | Merge                          |
| Corruption between phases                  | Assertions in `stampResistors` stop the run under every test above                                                        | Asserts         | All                            |
| Residue from the comptime matrix parameter | Codegen probe `gen_stamp=hand_stamp`                                                                                      | Probe           | Merge                          |

```zig
const max_resistors_per_input = 256; // bounded generator loop

fn sparseMatchesDense(_: void, s: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var d: Devices = .{ .node_count = s.valueRangeAtMost(u32, 2, 32) };
    defer d.resistors.deinit(gpa);

    for (0..max_resistors_per_input) |_| {
        if (s.eos()) break;
        const a: NodeId = @fromBackingInt(@as(u32, @intCast(s.index(d.node_count))));
        const b: NodeId = @fromBackingInt(@as(u32, @intCast(s.index(d.node_count))));
        const ohms: f64 = @floatFromInt(s.valueRangeAtMost(u32, 1, 1_000_000));
        _ = d.addResistor(gpa, a, b, ohms) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // The generator only makes valid input, so these are bugs in this test or the code.
            error.InvalidValue, error.UnknownNode, error.TooManyResistors => unreachable,
        };
    }

    var dense = try Dense.init(gpa, d.node_count);
    defer dense.deinit(gpa);
    var sparse = try Sparse.init(gpa, d.node_count);
    defer sparse.deinit(gpa);

    stampResistors(Dense, &dense, &d);
    stampResistors(Sparse, &sparse, &d);
    try expectSameMatrix(&dense, &sparse);
}

test "sparse stamping matches dense stamping" {
    try std.testing.fuzz({}, sparseMatchesDense, .{});
}
```

**R8 — Proof.** `gen_stamp` (through `stampResistors(Sparse, …)`) against `hand_stamp` (the same loop written against `Sparse` directly): expected FOLDED. Data size: 16 B per resistor, asserted. Code size: two instantiations (Dense in tests only).

**R9 — Record.**

```markdown
### S1: matrix storage for stamping

- **Axis**: backend — dense (tests), sparse (production)
- **Evidence**: two cases today: Dense, Sparse
- **Owner**: devices (src/devices.zig)
- **Rung**: 5 comptime parameter. Rung 4 fails because the choice is fixed per build; a per-element switch would be residue.
- **Cost**:
  - residue: none (probe FOLDED)
  - change radius for one more case: 0 bodies (a new Matrix type)
  - interface weight: one contract: `pub fn add(*Matrix, NodeId, NodeId, f64) void`
- **Drills passed**: D1
- **Proof**: FOLDED — tests/codegen.zig, Zig 0.17.0 -O ReleaseFast -mcpu=x86_64_v3
- **Revisit when**: the matrix type must be chosen at runtime
```

The result: 16 bytes per resistor, no residue, a radius of 0 for a new device kind, failures stopped at the parser or by an assertion, and six independent oracles.

### Chapter 24. Checklists

The design review in §1 is the procedure; these lists are what its Checklist table carries.

**Design review.**

- [ ] The data is written down: the Six Questions answered; counts, widths with stated ranges, access frequency, which transform reads each field.
- [ ] Every table has one owner, a producer, a consumer, a capacity with a unit, and a lifetime (arena named for its phase).
- [ ] Every transform is written `name: reads → writes`; one spine per pipeline lists every transform; no transform calls another or branches on which work to do.
- [ ] Bulk data is SoA (AoS justified), hot and cold fields are split, and sizes are asserted at compile time.
- [ ] References are typed indices or generational handles; no pointer is stored in a struct field.
- [ ] Booleans, `Option`s and rare fields in bulk data are replaced by table membership or side tables.
- [ ] Every seam names its axis, evidence (two cases or a drill), rung, and why the rung below fails; it is within the §2.1 budget.
- [ ] Every rung ≥5 seam and every hot-path abstraction has a probe verdict of FOLDED, IDENTICAL, EQUIVALENT or NEGATIVE wired into the build.
- [ ] Three change drills have complete edit lists and numeric radii; failures are fixed or accepted.
- [ ] The module graph is a DAG enforced by the build; the core cannot import I/O; no topic folders.
- [ ] Each module has a narrow, documented error set; external data is validated once, at the edge, into refined types.
- [ ] Every state change is fallible-first or `errdefer`-rolled-back; no global mutable state exists.
- [ ] Every loop, queue and buffer has a bound; asserts average two per function, entry and exit, positive and negative space, split, paired.
- [ ] The runtime-check budget is recorded per module (Principle 17.10).
- [ ] Each component has at least two independent, non-tautological oracles; tested seams are confirmed with the user; nondeterminism is injected through comptime parameters.
- [ ] Every test layer has a tier, the merge tier fits its budget, and exit criteria are numbers or yes/no.
- [ ] `ARCHITECTURE.md`, seam records, the drill table, `GLOSSARY.md`, ADRs and `TESTING.md` are current.

**Code review red flags** (the Standards axis of `code-review`, beside its smell baseline as overridden in §2.3):

- [ ] `dyn`, function pointers or vtables on a per-element hot path (§2.1)
- [ ] `else =>` or `_ =>` over a boundary enum without a `// else: <why>` annotation
- [ ] A `bool`, `Option` or pointer field in a struct that exists millions of times
- [ ] A field wider than its stated range, or a range nobody stated
- [ ] Allocation inside a hot loop; a container growing element-wise in a loop
- [ ] Global mutable state, singletons or service locators
- [ ] A topic folder (`utils`, `common`, `models`, `managers`) or a module cycle
- [ ] A transform that calls another transform, or branches on which work to do
- [ ] A table written by more than one module
- [ ] `anyerror` or `Box<dyn Error>` across a module boundary
- [ ] A function with no assertions; a compound `assert(a and b)`; an unbounded `while`
- [ ] An allocation without its `defer`/`errdefer` on the next line
- [ ] A `pub` item whose doc comment restates the signature, or misses a reachable assert
- [ ] A file without its `//!` in → out header
- [ ] A shallow module, a pass-through function, or two modules sharing one piece of knowledge
- [ ] A seam with one adapter and no drill (speculative), or code `ponytail-review` would delete
- [ ] A test with no oracle beyond "it didn't crash", or a tautological expected value
- [ ] A golden file with no recorded provenance
- [ ] A speed claim without a benchmark number; a hot-path abstraction without a probe verdict
- [ ] A safety check disabled without fuzz and differential evidence
- [ ] Zig 0.16 forms in touched files (`zig/migration-0.17.md`'s `rg` line prints anything)

**Release.** Apply the exit criteria in Principle 22.6, and record which ones were waived, by whom, and why.

---

## 10. Appendices

### Appendix A. Pattern Pruning Reference

Every pattern from the source books, with its runtime cost in the classic form, its verdict, its cheapest equivalent and its ladder rung (`codebase-clean-code/LADDER.md`; budget per §2.1). "Converted" means the intent survives in a compile-time or data form. "Removed" means the pattern's essence is runtime indirection, so it is replaced by a different approach.

| Pattern                          | Source             | Classic runtime cost                      | Verdict                 | Cheapest equivalent                                                                     | Rung         |
| -------------------------------- | ------------------ | ----------------------------------------- | ----------------------- | --------------------------------------------------------------------------------------- | ------------ |
| Abstract Factory                 | GoF                | Factory object, vtable                    | Converted               | Comptime function returning types; build option                                         | 5            |
| Builder                          | GoF                | Builder object, runtime validation        | Converted               | Const config struct, validated at comptime                                              | 2 / 5        |
| Factory Method                   | GoF                | Virtual creation                          | Converted               | Constructor function; table per kind when kinds differ; comptime type parameter         | 2 / 3 / 5    |
| Prototype                        | GoF                | Runtime clone through vtable              | Removed                 | Copy a const template value                                                             | 1            |
| Singleton                        | GoF                | Global state, lazy-init check             | Removed                 | One instance made in `main`, passed explicitly as a parameter                           | 2            |
| Adapter                          | GoF                | Wrapper object                            | Kept                    | Newtype or wrapper struct (`repr(transparent)` folds); inlined forwarding function      | 5 / 2        |
| Bridge                           | GoF                | Implementation pointer                    | Converted               | Comptime or build-option implementation                                                 | 5            |
| Composite                        | GoF                | Heap nodes, child pointers, virtual calls | Converted               | Flat arrays with parent/child indices, walked in index order                            | 3            |
| Decorator                        | GoF                | Wrapper chain, indirect calls             | Converted               | A transform inserted in the spine; a comptime wrapper type                              | 3 / 5        |
| Facade                           | GoF                | None if thin                              | Kept                    | Small module API (deep module)                                                          | 2            |
| Flyweight                        | GoF                | None (saves memory)                       | Kept                    | Shared table plus small index                                                           | 3            |
| Proxy                            | GoF                | Indirection, lazy checks                  | Removed                 | Explicit load phase; handles                                                            | 3            |
| Chain of Responsibility          | GoF                | Linked handler objects                    | Converted               | Spine lines; comptime tuple of stages, `inline for`                                     | 3 / 5        |
| Command                          | GoF                | Heap objects with vtable                  | Converted               | Command enum as data in a queue; undo and replay walk the rows                          | 4 + 6        |
| Interpreter                      | GoF                | Object tree, virtual `eval`               | Converted               | SoA tagged-union AST, bytecode; comptime when the program is known                      | 3 / 4        |
| Iterator                         | GoF                | Virtual `next`                            | Converted               | `for` over a slice or range; stdpp pipelines or `@Vector` for vector loops              | 1            |
| Mediator                         | GoF                | Central runtime router                    | Removed                 | Explicit data flow between owners via request tables                                    | 3 / 6        |
| Memento                          | GoF                | Opaque heap snapshot                      | Kept as data            | Copy of plain table rows                                                                | 1            |
| Observer                         | GoF                | Subscriber lists, callback per event      | Converted               | Request table drained by the owner in spine order; comptime handlers when fixed         | 6 (5)        |
| State                            | GoF                | State objects with vtable                 | Converted               | Enum + transition table `next[state][event]`; one table per state                       | 3 + 4        |
| Strategy                         | GoF                | Strategy pointer plus vtable              | Converted               | Comptime parameter or closure passed to a generic                                       | 5 (2 if one) |
| Template Method                  | GoF                | Virtual hooks                             | Converted               | The spine, with varying steps as comptime parameters                                    | 5            |
| Visitor                          | GoF                | Double dispatch                           | Converted               | Exhaustive `switch`/`match`, `inline else`                                              | 4            |
| Layers                           | POSA               | Calls through each layer                  | Converted               | Modules enforced by the build graph; inlined calls                                      | 2 / 5        |
| Pipes and Filters                | POSA               | Buffers between stages                    | Converted               | Transforms in the spine; fused comptime pipeline                                        | 3 / 5        |
| Blackboard                       | POSA               | Shared runtime store, control loop        | Removed                 | Explicit transforms over owned tables                                                   | 3            |
| Broker                           | POSA               | Runtime routing, marshaling               | Removed in-process      | Direct calls; a broker only between processes                                           | 2 / 9        |
| Model-View-Controller            | POSA               | Observer wiring                           | Kept as data separation | Model tables; views as transforms; a humble view over owned tables (`gui-architecture`) | 3            |
| Presentation-Abstraction-Control | POSA               | Agent hierarchy                           | Removed                 | Module hierarchy                                                                        | 2            |
| Microkernel                      | POSA               | Runtime plugin loading                    | Restricted              | Comptime plugin list; ABI plugins at a batched boundary                                 | 5 / 9        |
| Reflection                       | POSA               | Runtime metaobjects                       | Converted               | Comptime reflection (`@typeInfo(T).@"struct".field_names`, `@FieldType`)                | 5            |
| Whole-Part                       | POSA               | None                                      | Kept                    | Ownership boundary                                                                      | 2            |
| Master-Worker                    | POSA               | Thread coordination (the work itself)     | Kept                    | Job system over table chunks                                                            | 3            |
| Command Processor                | POSA               | Command objects                           | Converted               | Command enum queue drained by the owner                                                 | 4 + 6        |
| Publisher-Subscriber             | POSA               | Runtime subscription                      | Converted               | Request tables                                                                          | 6            |
| Counted Pointer                  | POSA               | Count per object, indirection             | Removed                 | Arenas and single ownership                                                             | 1            |
| Transaction Script               | PoEAA              | None                                      | Kept                    | Plain functions over data                                                               | 2            |
| Domain Model                     | PoEAA              | Object graph                              | Converted               | Tables plus transforms                                                                  | 3            |
| Table Module                     | PoEAA              | None                                      | Kept                    | Closest PoEAA pattern to DOD                                                            | 3            |
| Service Layer                    | PoEAA              | None                                      | Kept                    | Module API                                                                              | 2            |
| Active Record                    | PoEAA              | Per-row objects with I/O                  | Removed                 | Plain tables; explicit load and store                                                   | 3            |
| Data Mapper                      | PoEAA              | Mapping layer                             | Kept at the edge        | Translation at the boundary                                                             | 2            |
| Unit of Work                     | PoEAA              | Change tracking                           | Removed                 | Fallible-first commit                                                                   | 2            |
| Identity Map                     | PoEAA              | Runtime hash lookup                       | Removed                 | Indices into loaded tables                                                              | 3            |
| Lazy Load                        | PoEAA              | Check on every access                     | Removed                 | Explicit load phases                                                                    | 3            |
| Repository                       | PoEAA, DDD         | Interface object                          | Converted               | Comptime-generic storage module                                                         | 5            |
| Value Object, Money              | PoEAA, DDD         | None                                      | Kept                    | Distinct zero-cost types                                                                | 5            |
| Special Case                     | PoEAA              | Subclass per case                         | Converted               | Tagged-union variant; define errors out of existence                                    | 4            |
| Registry, Plugin                 | PoEAA              | Runtime lookup                            | Removed or restricted   | Explicit parameters; comptime registration                                              | 2 / 5        |
| Service Stub                     | PoEAA              | Runtime substitution                      | Converted               | Comptime test double                                                                    | 5            |
| Gateway                          | PoEAA              | None                                      | Kept at the edge        | Boundary module                                                                         | 2            |
| Separated Interface              | PoEAA              | Interface dispatch                        | Converted               | Comptime port                                                                           | 5            |
| Entity                           | DDD                | Identity object                           | Converted               | ID plus table rows                                                                      | 3            |
| Aggregate                        | DDD                | None                                      | Kept                    | Ownership and consistency boundary (one owner)                                          | 2            |
| Bounded Context                  | DDD                | None                                      | Kept                    | Module with its own types and glossary                                                  | 2            |
| Anticorruption Layer             | DDD                | Translation (the work itself)             | Kept                    | Edge translation, once                                                                  | 2            |
| Specification                    | DDD                | Predicate objects                         | Converted               | Comptime predicate or filter transform                                                  | 3 / 5        |
| Dependency Inversion             | Clean Architecture | Interface dispatch                        | Converted               | Comptime ports                                                                          | 5            |
| Humble Object                    | Clean Architecture | None                                      | Kept                    | Thin I/O shell around a testable core                                                   | 2            |
| Entity Component System          | Community          | None (data-oriented)                      | Kept                    | Archetype or sparse-set tables, queries as loops                                        | 3            |

### Appendix B. Applying the Testing Plan to the Six Projects

The testing research supplied with this file examined six projects. The single highest-value change for three of them is the same: ARPice, Gompute and ZvsRust have no CI that runs their tests (Principle 22.1).

| Project                               | First step                                                  | Key oracles to add                                                                                                                                                                                                                                                           | Release gate highlights                                                                                                          |
| ------------------------------------- | ----------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| ARPice (SPICE, Zig)                   | CI running `zig build test` in Debug and ReleaseSafe        | KCL residual and scaled LU residual certificates; Jacobian vs finite difference for all 39 models; structured netlist fuzzing; metamorphic relations; `--jobs=1` vs `--jobs=N` byte identity; integrator order (MMS); automated ngspice/VACASK differential (`spice-engine`) | Corpus 100% with annotated XFAILs; ≥24 CPU-h fuzz per target; CPU vs CUDA within tolerance; HIP labeled unsupported until tested |
| Gompute (GPU kernels, Zig)            | CPU CI plus a nightly NVIDIA runner                         | CPU-vs-GPU backend differential; exhaustive `f32` math against f128; memory-model litmus tests on hardware; compute-sanitizer (`gpu-kernel-optimization`)                                                                                                                    | Only hardware-tested backends claimed                                                                                            |
| VerA (Verilog-AMS compiler, Zig)      | Conformance name-list ratchet as a CI gate                  | AD vs finite difference on every fixture; a Verilog-A program smith with three-way target differential; EMI-style mutation; OpenVAF and Verilator differential; automatic test-case reduction (`compiler-construction`)                                                      | ≥24 CPU-h smith with no unexplained divergence; zero PASS→FAIL                                                                   |
| ZvsRust / stdpp (SIMD iterators, Zig) | CI matrix across `-Dcpu` levels and aarch64                 | Pipeline smith against a scalar interpreter; exhaustive `u8` domains (`simd-loops`, `simd-first`)                                                                                                                                                                            | ≥8 CPU-h smith; no benchmark regression beyond 5%                                                                                |
| Philis (analog P&R, Rust)             | Repair and gate the independent KLayout/Magic/Netgen checks | W/L-aware LVS; exact-symmetry, grid and connectivity properties; multi-seed runs; generated netlists; QoR distribution gate                                                                                                                                                  | Independent DRC/LVS clean across seeds 1–5; ≥10⁴ generated circuits                                                              |
| GPurify (DRC/LVS/PEX, Rust)           | Determinism gate in CI                                      | Boolean laws via `proptest`; bitmap reference DRC; geometric metamorphic relations; automated KLayout differential; planted-fault LVS; PEX convergence; `cargo mutants`                                                                                                      | ≥10⁶ property cases; ≥10⁵ bitmap-differential layouts; mutation score floor                                                      |

### Appendix C. Sources

**The skill bundle.** `coding-skills-combined.md` (generated 2026-10-16), 33 skills: `pragmatic-programmer`, `refactoring-patterns`, `codebase-design`, `codebase-clean-code`, `codebase-rules`, `codebase-improvement`, `improve-codebase-architecture`, `api-design`, `engineering-at-scale`, `legacy-code`, `rewrite-clean`, `ponytail`, `ponytail-review`, `ponytail-audit`, `rust`, `zig`, `assertions`, `doc-comments`, `writing-perfect-verilog`, `data-oriented-design`, `branchless`, `simd-loops`, `simd-first`, `gpu-kernel-optimization`, `gpu-parallel-algorithm-thinking`, `gui-architecture`, `compiler-construction`, `spice-engine`, `tdd`, `test-plan`, `code-review`, `domain-modeling`, `systems`. Each skill's own Sources section lists its references; the measured residue numbers, probe verdicts and toolchain behaviour quoted in this file come from those skills.

**Books.** Martin, _Clean Code_ (2008) and _Clean Architecture_ (2017). Fowler, _Refactoring_ 2nd ed. (2018) and _Patterns of Enterprise Application Architecture_ (2002). McConnell, _Code Complete_ 2nd ed. (2004). Hunt and Thomas, _The Pragmatic Programmer_ 20th anniversary ed. (2019). Ousterhout, _A Philosophy of Software Design_ 2nd ed. (2021). Gamma, Helm, Johnson and Vlissides, _Design Patterns_ (1994). Buschmann et al., _Pattern-Oriented Software Architecture_ Vol. 1 (1996). Evans, _Domain-Driven Design_ (2003). Richards and Ford, _Fundamentals of Software Architecture_ (2020). Bass, Clements and Kazman, _Software Architecture in Practice_ 4th ed. (2021). Fabian, _Data-Oriented Design_ (2018). Nystrom, _Game Programming Patterns_ (2014). Gregory, _Game Engine Architecture_ 3rd ed. (2018). Bryant and O'Hallaron, _Computer Systems: A Programmer's Perspective_ 3rd ed. (2015). Beck, _Test-Driven Development: By Example_ (2002). Khorikov, _Unit Testing Principles, Practices, and Patterns_ (2020). Feathers, _Working Effectively with Legacy Code_ (2004).

**Talks, papers and documents.**

- Drepper, "What Every Programmer Should Know About Memory" (2007)
- Acton, "Data-Oriented Design and C++", CppCon 2014
- Kelley, "Practical Data-Oriented Design", Handmade Seattle 2021
- Muratori, "Clean Code, Horrible Performance" (2023); _Semantic Compression_; _Designing and Evaluating Reusable Components_ (2004)
- Kelley, [State of the (Tagged) Union Address](https://www.youtube.com/watch?v=zwi5b5xSsKA), Systems Distributed '26
- Hipp, [Reliability Lessons From SQLite](https://www.youtube.com/watch?v=V_qzqY1bb7I), Software Should Work 2026 ([slides](https://sqlite.org/talks/shouldwork-20260716.pdf))
- [How SQLite Is Tested](https://sqlite.org/testing.html)
- [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md) and [the VOPR](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/internals/vopr.md)
- matklad, [How to Test](https://matklad.github.io/2021/05/31/how-to-test.html), [Generate All the Things](https://matklad.github.io/2021/11/07/generate-all-the-things.html), _Push Ifs Up And Fors Down_, _ARCHITECTURE.md_
- Wilson, [Testing Distributed Systems w/ Deterministic Simulation](https://www.youtube.com/watch?v=4fFDFbi3toc), Strange Loop 2014
- Yang et al., [Finding and Understanding Bugs in C Compilers](https://users.cs.utah.edu/~regehr/papers/pldi11-preprint.pdf), PLDI 2011
- Groce et al., [Swarm Testing](https://users.cs.utah.edu/~regehr/papers/swarm12.pdf), ISSTA 2012
- Le, Afshari and Su, [Equivalence Modulo Inputs](https://web.cs.ucdavis.edu/~su/emi-project/), PLDI 2014
- Chen et al., [Metamorphic Testing: A Review](https://doi.org/10.1145/3143561), ACM CSUR 2018
- Rigger and Su, [Finding Bugs in Database Systems via Query Partitioning](https://dl.acm.org/doi/10.1145/3428279), OOPSLA 2020
- Marick, [How to Misuse Code Coverage](http://www.exampler.com/testing-com/writings/coverage.pdf)
- Claessen and Hughes, [QuickCheck](https://www.cs.tufts.edu/~nr/cs257/archive/john-hughes/quick.pdf), ICFP 2000
- [LAPACK Working Note 41](https://www.netlib.org/lapack/lawnspdf/lawn41.pdf) (residual-ratio testing)
- Salari and Knupp, _Code Verification by the Method of Manufactured Solutions_, SAND2000-1444
- [Wasmtime fuzzing](https://docs.wasmtime.dev/contributing-fuzzing.html)
- Lopes et al., [Alive2](https://users.cs.utah.edu/~regehr/alive2-pldi21.pdf), PLDI 2021
- Hoare, [not rocket science](https://graydon2.dreamwidth.org/1597.html) (2014)
- [Software Engineering at Google](https://abseil.io/resources/swe-book), chapters 11–14 and 23
- [Zig 0.16.0](https://ziglang.org/download/0.16.0/release-notes.html) and [0.17.0](https://ziglang.org/download/0.17.0/release-notes.html) release notes

Zig API details (the fuzz `Smith` interface, corpus replay behavior, `checkAllAllocationFailures`, `SafeAllocator`) follow the supplied testing research, which verified them against the installed 0.16.0 and 0.17.0 standard libraries; Zig 0.17 forms (`@backingInt`, `@fromBackingInt`, `std.lang.Optimize`, `pub`-only `@hasDecl`) follow `zig/migration-0.17.md`. The code examples in this file were written for it and have not been compiled; before relying on one, compile it under the pinned toolchain (the `zig` skill's `scripts/check_snippets.py` does this for Zig blocks).
