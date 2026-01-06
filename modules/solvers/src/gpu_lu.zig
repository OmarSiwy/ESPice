//! Level-scheduled sparse LU factorization — CPU-side infrastructure for GPU
//! sparse LU (GLU 3.0 style). Computes dependency DAGs, levelization with
//! relaxed double-U detection, kernel-mode classification, and a
//! level-scheduled numeric factorization that processes each level's columns
//! independently.
//!
//! This is the CPU simulation of the GPU flow: the level structure and
//! classification are the same data a GPU launcher would consume. The
//! numeric factorization runs sequentially within each level (the GPU would
//! parallelize across columns within a level).
//!
//! Requires the FILLED pattern (after symbolic factorization): up/ui give
//! the U pattern in topological order, lp/li give L. The caller supplies
//! these from `direct.zig`'s Lu after a full factor.

const std = @import("std");
const Allocator = std.mem.Allocator;

const NONE: u32 = std.math.maxInt(u32);

pub fn GpuLu(comptime T: type) type {
    return struct {
        const Self = @This();

        const WT = std.simd.suggestVectorLength(T) orelse 1;
        const VecT = @Vector(WT, T);
        const W32 = std.simd.suggestVectorLength(u32) orelse 1;
        const V32 = @Vector(W32, u32);

        /// SIMD zero-fill a contiguous T buffer.
        inline fn simdZero(buf: []T) void {
            const zero: VecT = @splat(0);
            var i: usize = 0;
            while (i + WT <= buf.len) : (i += WT) {
                buf[i..][0..WT].* = zero;
            }
            for (buf[i..]) |*v| v.* = 0;
        }

        /// SIMD copy contiguous T buffers.
        inline fn simdCopy(dst: []T, src: []const T) void {
            var i: usize = 0;
            while (i + WT <= dst.len) : (i += WT) {
                dst[i..][0..WT].* = src[i..][0..WT].*;
            }
            for (dst[i..], src[i..]) |*d, s| d.* = s;
        }

        /// SIMD copy contiguous u32 buffers.
        inline fn simdCopyU32(dst: []u32, src: []const u32) void {
            var i: usize = 0;
            while (i + W32 <= dst.len) : (i += W32) {
                dst[i..][0..W32].* = src[i..][0..W32].*;
            }
            for (dst[i..], src[i..]) |*d, s| d.* = s;
        }

        pub const KernelMode = enum { small_block, large_block, stream };

        pub const LevelInfo = struct {
            start: u32, // index into level_cols
            count: u32, // columns in this level
            mode: KernelMode, // classification
        };

        // --- SoA fields ---
        n: u32,
        q: []const u32, // column permutation (borrowed, not owned)

        // Levelization output (owned)
        level_of: []u32, // [n] level assignment per column (pivot step)
        level_cols: []u32, // [n] columns grouped by level, contiguous
        level_info: []LevelInfo, // [depth] per-level metadata
        depth: u32, // total number of levels

        // Filled L/U pattern (owned copies for factor)
        lp: []u32, // L column pointers [n+1]
        li: []u32, // L row indices
        lx: []T, // L values (workspace for factor)
        up: []u32, // U column pointers [n+1]
        ui: []u32, // U row indices (topo order)
        ux: []T, // U values (workspace for factor)
        udiag: []T, // [n] diagonal of U

        // Factor workspace
        w: []T, // [n] dense scatter workspace

        /// Initialize from the frozen LU pattern. `q` is the column
        /// permutation from ordering, `col_ptr`/`row_idx` are the original
        /// matrix pattern (for prow computation — not used here, reserved).
        /// The filled pattern (up/ui, lp/li) is provided via `levelize`.
        pub fn init(
            gpa: Allocator,
            n: u32,
            col_ptr: []const u32,
            row_idx: []const u32,
            q: []const u32,
        ) !Self {
            _ = col_ptr;
            _ = row_idx;
            return Self{
                .n = n,
                .q = q,
                .level_of = try gpa.alloc(u32, n),
                .level_cols = try gpa.alloc(u32, n),
                .level_info = try gpa.alloc(LevelInfo, n), // upper bound; shrunk after levelize
                .depth = 0,
                .lp = &.{},
                .li = &.{},
                .lx = &.{},
                .up = &.{},
                .ui = &.{},
                .ux = &.{},
                .udiag = try gpa.alloc(T, n),
                .w = try gpa.alloc(T, n),
            };
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.level_of);
            gpa.free(self.level_cols);
            gpa.free(self.level_info);
            gpa.free(self.udiag);
            gpa.free(self.w);
            if (self.lp.len > 0) gpa.free(self.lp);
            if (self.li.len > 0) gpa.free(self.li);
            if (self.lx.len > 0) gpa.free(self.lx);
            if (self.up.len > 0) gpa.free(self.up);
            if (self.ui.len > 0) gpa.free(self.ui);
            if (self.ux.len > 0) gpa.free(self.ux);
            self.* = undefined;
        }

        /// Compute level sets from the filled U and L patterns (GLU 3.0
        /// Algorithm 4: relaxed double-U dependency detection).
        ///
        /// `u_ptr`/`u_idx`: filled U column pointers and row indices.
        ///   U(i,k) != 0 means column k depends on column i ("look up").
        /// `l_ptr`/`l_idx`: filled L column pointers and row indices.
        ///   L(k,i) != 0 means column k depends on column i ("look left",
        ///   relaxed double-U detection — superset of exact, same level count).
        ///
        /// After this call: level_of, level_cols, level_info, depth are valid.
        pub fn levelize(
            self: *Self,
            u_ptr: []const u32,
            u_idx: []const u32,
            l_ptr: []const u32,
            l_idx: []const u32,
        ) void {
            const n = self.n;
            std.debug.assert(u_ptr.len == n + 1);
            std.debug.assert(l_ptr.len == n + 1);

            // --- Pass 1: compute level_of[k] from U pattern ("look up") ---
            for (0..n) |k| {
                var max_dep_level: u32 = 0;

                // U(i,k) != 0, i < k => column k depends on column i
                for (u_ptr[k]..u_ptr[k + 1]) |p| {
                    const i = u_idx[p];
                    if (i < k) {
                        max_dep_level = @max(max_dep_level, self.level_of[i] + 1);
                    }
                }
                self.level_of[k] = max_dep_level;
            }

            // --- Pass 2: relaxed double-U ("look left") via L pattern ---
            // L(r, c) != 0 with r > c means column r depends on column c
            // (GLU 3.0 Algorithm 4). CSC natural order: scan L[:,c] and
            // propagate. Fixed-point iteration handles transitive raises.
            // ponytail: O(iterations * nnz_L); iterations <= depth, typically 1-2.
            var changed = true;
            while (changed) {
                changed = false;
                for (0..n) |c| {
                    for (l_ptr[c]..l_ptr[c + 1]) |p| {
                        const r = l_idx[p];
                        if (r > c) {
                            const needed = self.level_of[c] + 1;
                            if (needed > self.level_of[r]) {
                                self.level_of[r] = needed;
                                changed = true;
                            }
                        }
                    }
                }
            }

            // --- Pass 2: find depth ---
            var max_level: u32 = 0;
            for (self.level_of[0..n]) |lv| max_level = @max(max_level, lv);
            self.depth = if (n > 0) max_level + 1 else 0;

            // --- Pass 3: bucket sort columns by level ---
            // Count per level
            // ponytail: struct array — not worth SIMD, iterate directly
            for (self.level_info[0..self.depth]) |*info| info.* = .{ .start = 0, .count = 0, .mode = .small_block };
            for (self.level_of[0..n]) |lv| self.level_info[lv].count += 1;

            // Prefix sum for starts
            var offset: u32 = 0;
            for (self.level_info[0..self.depth]) |*info| {
                info.start = offset;
                offset += info.count;
            }

            // Place columns (use a temp copy of starts as write cursors)
            // Reuse w as temp storage (cast to u32 — same size for f32/f64)
            // ponytail: just use level_cols directly with a cursor array
            // backed by the first `depth` entries of w (depth <= n).
            var cursors: [*]u32 = @ptrCast(@alignCast(self.w.ptr));
            for (0..self.depth) |lv| cursors[lv] = self.level_info[lv].start;
            for (0..n) |k| {
                const lv = self.level_of[k];
                self.level_cols[cursors[lv]] = @intCast(k);
                cursors[lv] += 1;
            }

            // --- Pass 4: classify kernel modes ---
            for (self.level_info[0..self.depth]) |*info| {
                info.mode = classifyMode(info.count);
            }

            // Clear w (we borrowed it for cursors)
            simdZero(self.w);
        }

        fn classifyMode(level_size: u32) KernelMode {
            // GLU 3.0 §III-B thresholds
            if (level_size > 16) return .small_block; // type A: many cols
            if (level_size > 4) return .large_block; // type B: transition
            return .stream; // type C: few cols, huge subcols
        }

        /// Level-scheduled numeric factorization. Processes levels in order;
        /// within each level, columns are independent (the GPU parallelism).
        ///
        /// Uses the hybrid right-looking reformulation from GLU:
        ///   1. Normalize L column: L(i,k) = A(i,k) / A(k,k)
        ///   2. Right-looking subcolumn updates: for each U(k,j) != 0,
        ///      A(i,j) -= L(i,k) * U(k,j) for all L(i,k) != 0
        ///
        /// `a_ptr`/`a_vals`: the filled matrix values in CSC. This is the
        /// combined L+U storage — `a_ptr` matches the filled pattern.
        /// The caller must ensure the filled pattern matches up/ui and lp/li.
        ///
        /// Actually, for the CPU simulation we use the left-looking approach
        /// matching direct.zig's refactor: scatter, triangular solve in topo
        /// order, normalize. This is equivalent and reuses the existing
        /// up/ui topo-order convention.
        pub fn factor(self: *Self, vals: []const T, prow: []const u32, col_ptr: []const u32) error{SingularMatrix}!void {
            const li = self.li;
            const lx = self.lx;
            const ui = self.ui;
            const ux = self.ux;
            const lp = self.lp;
            const up = self.up;

            // Process levels in order
            for (0..self.depth) |lv| {
                const info = self.level_info[lv];
                const cols = self.level_cols[info.start .. info.start + info.count];

                // Within a level, columns are independent — on GPU these
                // would run in parallel. On CPU we process sequentially.
                for (cols) |k| {
                    const c = self.q[k];

                    // Zero stored pattern in workspace
                    for (ui[up[k]..up[k + 1]]) |i| self.w[i] = 0;
                    for (li[lp[k]..lp[k + 1]]) |i| self.w[i] = 0;
                    self.w[k] = 0;

                    // Scatter original values through prow
                    for (col_ptr[c]..col_ptr[c + 1]) |p| self.w[prow[p]] = vals[p];

                    // Triangular solve in stored topological order
                    for (up[k]..up[k + 1]) |p| {
                        const i = ui[p];
                        const uki = self.w[i];
                        ux[p] = uki;
                        for (lp[i]..lp[i + 1]) |pl| self.w[li[pl]] -= lx[pl] * uki;
                    }

                    // Diagonal
                    const d = self.w[k];
                    if (d == 0 or !std.math.isFinite(d)) return error.SingularMatrix;
                    self.udiag[k] = d;

                    // Normalize L column
                    for (lp[k]..lp[k + 1]) |p| lx[p] = self.w[li[p]] / d;
                }
            }
        }

        /// Copy the filled LU pattern into owned storage for factorization.
        /// Call once after symbolic factorization (direct.zig factor), before
        /// using `factor` for numeric refactorization.
        pub fn setPattern(
            self: *Self,
            gpa: Allocator,
            src_lp: []const u32,
            src_li: []const u32,
            src_lx: []const T,
            src_up: []const u32,
            src_ui: []const u32,
            src_ux: []const T,
        ) !void {
            // Free old if any
            if (self.lp.len > 0) gpa.free(self.lp);
            if (self.li.len > 0) gpa.free(self.li);
            if (self.lx.len > 0) gpa.free(self.lx);
            if (self.up.len > 0) gpa.free(self.up);
            if (self.ui.len > 0) gpa.free(self.ui);
            if (self.ux.len > 0) gpa.free(self.ux);

            self.lp = try gpa.alloc(u32, src_lp.len);
            self.li = try gpa.alloc(u32, src_li.len);
            self.lx = try gpa.alloc(T, src_lx.len);
            self.up = try gpa.alloc(u32, src_up.len);
            self.ui = try gpa.alloc(u32, src_ui.len);
            self.ux = try gpa.alloc(T, src_ux.len);

            simdCopyU32(self.lp, src_lp);
            simdCopyU32(self.li, src_li);
            simdCopy(self.lx, src_lx);
            simdCopyU32(self.up, src_up);
            simdCopyU32(self.ui, src_ui);
            simdCopy(self.ux, src_ux);
        }

        // --- Accessors ---

        pub fn levelCount(self: *const Self) u32 {
            return self.depth;
        }

        pub fn levels(self: *const Self) []const LevelInfo {
            return self.level_info[0..self.depth];
        }

        pub fn levelCols(self: *const Self) []const u32 {
            return self.level_cols[0..self.n];
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn DenseCsc(comptime n: usize) type {
    return struct {
        col_ptr: [n + 1]u32,
        row_idx: [n * n]u32,
        vals: [n * n]f64,
        nnz_count: u32,

        fn from(a: [n][n]f64) @This() {
            var s: @This() = undefined;
            var m: u32 = 0;
            s.col_ptr[0] = 0;
            for (0..n) |j| {
                for (0..n) |i| {
                    if (a[i][j] != 0) {
                        s.row_idx[m] = @intCast(i);
                        s.vals[m] = a[i][j];
                        m += 1;
                    }
                }
                s.col_ptr[j + 1] = m;
            }
            s.nnz_count = m;
            return s;
        }

        fn nnz(s: *const @This()) u32 {
            return s.nnz_count;
        }
    };
}

test "levelize: chain graph (tridiagonal) — fully serial, depth = n" {
    // Chain: col 0 is a leaf, col k depends on col k-1.
    // U pattern: U(k-1, k) != 0 for k = 1..n-1
    // Expected: level(0) = 0, level(1) = 1, ..., level(n-1) = n-1
    const n = 5;
    const gpa = testing.allocator;

    // U: column k has one entry: row k-1 (for k > 0)
    var u_ptr: [n + 1]u32 = undefined;
    var u_idx: [n - 1]u32 = undefined; // n-1 entries total
    u_ptr[0] = 0;
    u_ptr[1] = 0; // col 0 has no U deps
    for (1..n) |k| {
        u_idx[k - 1] = @intCast(k - 1);
        u_ptr[k + 1] = @intCast(k);
    }

    // L: empty (no look-left deps needed for this test)
    var l_ptr: [n + 1]u32 = undefined;
    for (0..n + 1) |i| l_ptr[i] = 0;

    var q: [n]u32 = undefined;
    for (0..n) |i| q[i] = @intCast(i);

    var gpu = try GpuLu(f64).init(gpa, n, &.{ 0, 0, 0, 0, 0, 0 }, &.{}, &q);
    defer gpu.deinit(gpa);

    gpu.levelize(&u_ptr, &u_idx, &l_ptr, &.{});

    try testing.expectEqual(@as(u32, n), gpu.depth);
    for (0..n) |k| try testing.expectEqual(@as(u32, @intCast(k)), gpu.level_of[k]);
}

test "levelize: star graph — depth = 2" {
    // Star: col 0 is the hub (leaf, level 0).
    // Cols 1..n-1 all depend only on col 0 via U(0, k) != 0.
    // Expected: level(0) = 0, level(1..n-1) = 1. Depth = 2.
    const n = 6;
    const gpa = testing.allocator;

    // U: columns 1..5 each have one entry: row 0
    var u_ptr: [n + 1]u32 = undefined;
    u_ptr[0] = 0;
    u_ptr[1] = 0; // col 0 has no deps
    var u_idx: [n - 1]u32 = undefined;
    for (1..n) |k| {
        u_idx[k - 1] = 0; // depends on col 0
        u_ptr[k + 1] = @intCast(k);
    }

    var l_ptr: [n + 1]u32 = undefined;
    for (0..n + 1) |i| l_ptr[i] = 0;

    var q: [n]u32 = undefined;
    for (0..n) |i| q[i] = @intCast(i);

    var gpu = try GpuLu(f64).init(gpa, n, &.{ 0, 0, 0, 0, 0, 0, 0 }, &.{}, &q);
    defer gpu.deinit(gpa);

    gpu.levelize(&u_ptr, &u_idx, &l_ptr, &.{});

    try testing.expectEqual(@as(u32, 2), gpu.depth);
    try testing.expectEqual(@as(u32, 0), gpu.level_of[0]);
    for (1..n) |k| try testing.expectEqual(@as(u32, 1), gpu.level_of[k]);

    // All cols 1..5 should be in the same level bucket
    const info = gpu.levels();
    try testing.expectEqual(@as(u32, 1), info[0].count); // level 0: just hub
    try testing.expectEqual(@as(u32, n - 1), info[1].count); // level 1: all spokes
}

test "levelize: independent columns — all level 0" {
    // Diagonal matrix: no off-diagonal U entries => no deps => all level 0
    const n = 4;
    const gpa = testing.allocator;

    var u_ptr: [n + 1]u32 = undefined;
    for (0..n + 1) |i| u_ptr[i] = 0; // no U entries

    var l_ptr: [n + 1]u32 = undefined;
    for (0..n + 1) |i| l_ptr[i] = 0;

    var q: [n]u32 = undefined;
    for (0..n) |i| q[i] = @intCast(i);

    var gpu = try GpuLu(f64).init(gpa, n, &.{ 0, 0, 0, 0, 0 }, &.{}, &q);
    defer gpu.deinit(gpa);

    gpu.levelize(&u_ptr, &.{}, &l_ptr, &.{});

    try testing.expectEqual(@as(u32, 1), gpu.depth);
    for (0..n) |k| try testing.expectEqual(@as(u32, 0), gpu.level_of[k]);

    // All 4 columns in level 0
    try testing.expectEqual(@as(u32, n), gpu.levels()[0].count);
}

test "levelize: relaxed double-U adds extra edges" {
    // 4 columns. U pattern: col 2 depends on col 0 (U(0,2) != 0).
    // L pattern: L(3, 1) != 0 => col 3 depends on col 1 (look-left).
    // Without look-left: level(0)=0, level(1)=0, level(2)=1, level(3)=0
    // With look-left:    level(0)=0, level(1)=0, level(2)=1, level(3)=1
    const n = 4;
    const gpa = testing.allocator;

    // U: col 2 has entry at row 0
    const u_ptr = [_]u32{ 0, 0, 0, 1, 1 };
    const u_idx = [_]u32{0};

    // L: col 1 has entry at row 3 (L(3,1) != 0 => dep 1 -> 3)
    const l_ptr = [_]u32{ 0, 0, 1, 1, 1 };
    const l_idx = [_]u32{3};

    var q: [n]u32 = undefined;
    for (0..n) |i| q[i] = @intCast(i);

    var gpu = try GpuLu(f64).init(gpa, n, &.{ 0, 0, 0, 0, 0 }, &.{}, &q);
    defer gpu.deinit(gpa);

    gpu.levelize(&u_ptr, &u_idx, &l_ptr, &l_idx);

    try testing.expectEqual(@as(u32, 0), gpu.level_of[0]);
    try testing.expectEqual(@as(u32, 0), gpu.level_of[1]);
    try testing.expectEqual(@as(u32, 1), gpu.level_of[2]);
    // This is the key: look-left promotes col 3 from level 0 to level 1
    try testing.expectEqual(@as(u32, 1), gpu.level_of[3]);
    try testing.expectEqual(@as(u32, 2), gpu.depth);
}

test "kernel mode classification thresholds" {
    const classify = GpuLu(f64).classifyMode;
    // > 16 => small_block
    try testing.expectEqual(GpuLu(f64).KernelMode.small_block, classify(17));
    try testing.expectEqual(GpuLu(f64).KernelMode.small_block, classify(100));
    // 5..16 => large_block
    try testing.expectEqual(GpuLu(f64).KernelMode.large_block, classify(16));
    try testing.expectEqual(GpuLu(f64).KernelMode.large_block, classify(5));
    // <= 4 => stream
    try testing.expectEqual(GpuLu(f64).KernelMode.stream, classify(4));
    try testing.expectEqual(GpuLu(f64).KernelMode.stream, classify(1));
}

test "level-scheduled factor matches sequential factor on small matrix" {
    // 3x3 matrix:
    //   [4 1 0]
    //   [1 5 2]
    //   [0 2 6]
    //
    // Natural ordering, no pivoting (diagonal dominant => diagonal pivots).
    // We manually build the L/U pattern as if from a full symbolic factor
    // with natural ordering (identity permutation), then verify that
    // level-scheduled factor produces the same L/U values.

    const gpa = testing.allocator;
    const n = 3;

    // Dense matrix in CSC
    const a = [n][n]f64{
        .{ 4, 1, 0 },
        .{ 1, 5, 2 },
        .{ 0, 2, 6 },
    };
    const csc = DenseCsc(n).from(a);

    // Compute reference LU manually (left-looking, no pivoting):
    // Step 0 (col 0): diag=4, L(1,0)=1/4=0.25
    // Step 1 (col 1): A(1,1) -= L(1,0)*U(0,1) = 5 - 0.25*1 = 4.75
    //                  A(2,1) -= L(2,0)*U(0,1) = 2 - 0*1 = 2
    //                  diag=4.75, L(2,1)=2/4.75
    // Step 2 (col 2): A(2,2) -= L(2,1)*U(1,2) = 6 - (2/4.75)*2 = 6-4/4.75

    // Build filled L/U pattern (identity permutation):
    // U: col 0 has no deps, col 1 depends on col 0 (U(0,1)!=0),
    //    col 2 depends on col 1 (U(1,2)!=0)
    // L: col 0 has L(1,0), col 1 has L(2,1), col 2 has nothing
    const q = [n]u32{ 0, 1, 2 };

    // prow = identity (no row permutation)
    const prow = [_]u32{ 0, 1, 1, 0, 2, 1, 2 };
    // Wait — prow maps original matrix positions to permuted rows.
    // With identity permutation, prow[p] = row_idx[p].
    // Let's use the actual row_idx from the CSC.
    _ = prow;

    // Build prow from CSC row_idx with identity permutation
    const nnz_val = csc.nnz();
    var prow_arr: [7]u32 = undefined; // max possible
    for (0..nnz_val) |p| prow_arr[p] = csc.row_idx[p]; // identity perm

    // L pattern (permuted row indices, strictly lower):
    // col 0: L(1,0) => row 1
    // col 1: L(2,1) => row 2
    // col 2: (empty)
    const lp = [_]u32{ 0, 1, 2, 2 };
    const li = [_]u32{ 1, 2 };
    var lx_buf = [_]f64{ 0, 0 }; // filled by factor

    // U pattern (topo order, strictly upper, row indices < col):
    // col 0: (empty, no deps)
    // col 1: U(0,1) => row 0
    // col 2: U(1,2) => row 1
    const up = [_]u32{ 0, 0, 1, 2 };
    const ui = [_]u32{ 0, 1 };
    var ux_buf = [_]f64{ 0, 0 };

    var gpu = try GpuLu(f64).init(gpa, n, &csc.col_ptr, csc.row_idx[0..nnz_val], &q);
    defer gpu.deinit(gpa);

    // Set pattern (copies into owned storage)
    try gpu.setPattern(gpa, &lp, &li, &lx_buf, &up, &ui, &ux_buf);

    // Levelize: chain graph, depth = 3
    // U deps: col 1 depends on col 0, col 2 depends on col 1
    // No L look-left deps needed (empty L columns for look-left)
    var empty_l_ptr: [n + 1]u32 = undefined;
    for (0..n + 1) |i| empty_l_ptr[i] = 0;
    gpu.levelize(&up, &ui, &empty_l_ptr, &.{});

    try testing.expectEqual(@as(u32, 3), gpu.depth);

    // Factor
    try gpu.factor(csc.vals[0..nnz_val], prow_arr[0..nnz_val], &csc.col_ptr);

    // Check results against manual computation:
    // udiag[0] = 4
    try testing.expectApproxEqAbs(@as(f64, 4.0), gpu.udiag[0], 1e-12);
    // L(1,0) = 1/4 = 0.25
    try testing.expectApproxEqAbs(@as(f64, 0.25), gpu.lx[0], 1e-12);
    // U(0,1) = 1 (the original value, stored by topo solve)
    try testing.expectApproxEqAbs(@as(f64, 1.0), gpu.ux[0], 1e-12);
    // udiag[1] = 5 - 0.25 * 1 = 4.75
    try testing.expectApproxEqAbs(@as(f64, 4.75), gpu.udiag[1], 1e-12);
    // L(2,1) = 2 / 4.75
    try testing.expectApproxEqAbs(@as(f64, 2.0 / 4.75), gpu.lx[1], 1e-12);
    // U(1,2) = 2 (original value)
    try testing.expectApproxEqAbs(@as(f64, 2.0), gpu.ux[1], 1e-12);
    // udiag[2] = 6 - (2/4.75) * 2 = 6 - 4/4.75
    try testing.expectApproxEqAbs(@as(f64, 6.0 - 4.0 / 4.75), gpu.udiag[2], 1e-12);
}

test "level_cols contains all columns exactly once" {
    // Build a mixed dependency graph and verify bucketing
    const n = 8;
    const gpa = testing.allocator;

    // Diamond-ish: 0,1,2,3 are leaves; 4 depends on 0,1; 5 depends on 2,3;
    //              6 depends on 4; 7 depends on 5,6
    // U entries: U(0,4), U(1,4), U(2,5), U(3,5), U(4,6), U(5,7), U(6,7)
    const u_ptr = [_]u32{ 0, 0, 0, 0, 0, 2, 4, 5, 7 };
    const u_idx = [_]u32{ 0, 1, 2, 3, 4, 5, 6 };

    var l_ptr: [n + 1]u32 = undefined;
    for (0..n + 1) |i| l_ptr[i] = 0;

    var q: [n]u32 = undefined;
    for (0..n) |i| q[i] = @intCast(i);

    var gpu = try GpuLu(f64).init(gpa, n, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &.{}, &q);
    defer gpu.deinit(gpa);

    gpu.levelize(&u_ptr, &u_idx, &l_ptr, &.{});

    // Expected levels: 0,1,2,3 -> 0; 4,5 -> 1; 6 -> 2; 7 -> 3
    try testing.expectEqual(@as(u32, 4), gpu.depth);
    try testing.expectEqual(@as(u32, 0), gpu.level_of[0]);
    try testing.expectEqual(@as(u32, 0), gpu.level_of[1]);
    try testing.expectEqual(@as(u32, 0), gpu.level_of[2]);
    try testing.expectEqual(@as(u32, 0), gpu.level_of[3]);
    try testing.expectEqual(@as(u32, 1), gpu.level_of[4]);
    try testing.expectEqual(@as(u32, 1), gpu.level_of[5]);
    try testing.expectEqual(@as(u32, 2), gpu.level_of[6]);
    try testing.expectEqual(@as(u32, 3), gpu.level_of[7]);

    // Verify all columns present exactly once in level_cols
    var seen = [_]bool{false} ** n;
    for (gpu.levelCols()) |col| {
        try testing.expect(!seen[col]);
        seen[col] = true;
    }
    for (seen) |s| try testing.expect(s);

    // Verify level_info start/count matches
    const info = gpu.levels();
    try testing.expectEqual(@as(u32, 4), info[0].count); // level 0
    try testing.expectEqual(@as(u32, 2), info[1].count); // level 1
    try testing.expectEqual(@as(u32, 1), info[2].count); // level 2
    try testing.expectEqual(@as(u32, 1), info[3].count); // level 3
}

test "GpuLu works with f32" {
    // Smoke test: f32 instantiation compiles and runs
    const n = 2;
    const gpa = testing.allocator;

    var q = [_]u32{ 0, 1 };
    var gpu = try GpuLu(f32).init(gpa, n, &.{ 0, 0, 0 }, &.{}, &q);
    defer gpu.deinit(gpa);

    // Independent columns
    var u_ptr = [_]u32{ 0, 0, 0 };
    var l_ptr = [_]u32{ 0, 0, 0 };
    gpu.levelize(&u_ptr, &.{}, &l_ptr, &.{});

    try testing.expectEqual(@as(u32, 1), gpu.depth);
    try testing.expectEqual(@as(u32, 0), gpu.level_of[0]);
    try testing.expectEqual(@as(u32, 0), gpu.level_of[1]);
}
