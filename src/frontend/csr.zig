//! Bipartite hypergraph: nets are vertices, devices are hyperedges.
//! Adapted from cktImg src/csr.zig, Copyright (c) 2026 Omar El-Sawy, MIT License.
//!
//! An edge's member list is its pin list: order is the terminal role and
//! repeats are kept (bulk tied to source). Topology is two CSR arrays, one per
//! direction; payload is SoA in `MultiArrayList`s. Every reference is a typed
//! `u32`. An append-only `Builder` freezes into an immutable `Graph`.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const VertexId = enum(u32) {
    _,
    pub inline fn from(i: usize) VertexId {
        return @enumFromInt(@as(u32, @intCast(i)));
    }
    pub inline fn index(self: VertexId) u32 {
        return @intFromEnum(self);
    }
};

pub const EdgeId = enum(u32) {
    _,
    pub inline fn from(i: usize) EdgeId {
        return @enumFromInt(@as(u32, @intCast(i)));
    }
    pub inline fn index(self: EdgeId) u32 {
        return @intFromEnum(self);
    }
};

/// One side's adjacency: row r's neighbours are cols[offsets[r]..offsets[r+1]].
pub fn Csr(comptime Row: type, comptime Col: type) type {
    return struct {
        const Self = @This();

        offsets: []u32,
        cols: []Col,

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.offsets);
            gpa.free(self.cols);
            self.* = undefined;
        }

        pub inline fn rowCount(self: Self) usize {
            return self.offsets.len - 1;
        }

        pub inline fn rowAt(self: Self, r: usize) []const Col {
            return self.cols[self.offsets[r]..self.offsets[r + 1]];
        }

        pub inline fn row(self: Self, r: Row) []const Col {
            return self.rowAt(r.index());
        }

        /// Counting-sort transpose, O(rows + cols + nnz). Rows are visited in
        /// order, so every output row comes out sorted.
        pub fn transpose(self: Self, gpa: Allocator, col_count: usize) !Csr(Col, Row) {
            const offsets = try gpa.alloc(u32, col_count + 1);
            errdefer gpa.free(offsets);
            const cols = try gpa.alloc(Row, self.cols.len);
            errdefer gpa.free(cols);
            @memset(offsets, 0);
            for (self.cols) |c| offsets[c.index()] += 1;
            var running: u32 = 0;
            for (offsets) |*o| {
                const count = o.*;
                o.* = running;
                running += count;
            }
            for (0..self.rowCount()) |r| {
                for (self.rowAt(r)) |c| {
                    const slot = &offsets[c.index()];
                    cols[slot.*] = Row.from(r);
                    slot.* += 1;
                }
            }
            std.mem.copyBackwards(u32, offsets[1..], offsets[0..col_count]);
            offsets[0] = 0;
            return .{ .offsets = offsets, .cols = cols };
        }
    };
}

pub fn BipartiteHypergraph(comptime VertexData: type, comptime EdgeData: type) type {
    return struct {
        pub const EdgeMajor = Csr(EdgeId, VertexId);
        pub const VertexMajor = Csr(VertexId, EdgeId);

        pub const Error = error{ InvalidVertex, TooManyVertices, TooManyEdges, TooManyIncidences } || Allocator.Error;

        /// Append-only. Each edge arrives with its full member list, so the
        /// edge-major CSR grows as edges are added; `finish` transposes it.
        pub const Builder = struct {
            vertices: std.MultiArrayList(VertexData) = .empty,
            edges: std.MultiArrayList(EdgeData) = .empty,
            edge_offsets: std.ArrayList(u32) = .empty,
            edge_members: std.ArrayList(VertexId) = .empty,

            pub fn init(gpa: Allocator) Allocator.Error!Builder {
                var b: Builder = .{};
                try b.edge_offsets.append(gpa, 0);
                return b;
            }

            pub fn deinit(self: *Builder, gpa: Allocator) void {
                self.vertices.deinit(gpa);
                self.edges.deinit(gpa);
                self.edge_offsets.deinit(gpa);
                self.edge_members.deinit(gpa);
                self.* = undefined;
            }

            pub fn ensureTotalCapacity(self: *Builder, gpa: Allocator, vertex_count: usize, edge_count: usize, incidence_count: usize) Allocator.Error!void {
                try self.vertices.ensureTotalCapacity(gpa, vertex_count);
                try self.edges.ensureTotalCapacity(gpa, edge_count);
                try self.edge_offsets.ensureTotalCapacity(gpa, edge_count + 1);
                try self.edge_members.ensureTotalCapacity(gpa, incidence_count);
            }

            pub fn addVertex(self: *Builder, gpa: Allocator, data: VertexData) Error!VertexId {
                if (self.vertices.len >= std.math.maxInt(u32)) return error.TooManyVertices;
                const id = VertexId.from(self.vertices.len);
                try self.vertices.append(gpa, data);
                return id;
            }

            /// Members are stored in the given order, repeats included.
            /// All-or-nothing: on error the builder is unchanged.
            pub fn addEdge(self: *Builder, gpa: Allocator, data: EdgeData, members: []const VertexId) Error!EdgeId {
                for (members) |v| if (v.index() >= self.vertices.len) return error.InvalidVertex;
                if (self.edges.len >= std.math.maxInt(u32)) return error.TooManyEdges;
                if (self.edge_members.items.len + members.len > std.math.maxInt(u32)) return error.TooManyIncidences;
                try self.edge_members.ensureUnusedCapacity(gpa, members.len);
                try self.edge_offsets.ensureUnusedCapacity(gpa, 1);
                try self.edges.ensureUnusedCapacity(gpa, 1);
                self.edge_members.appendSliceAssumeCapacity(members);
                const id = EdgeId.from(self.edges.len);
                self.edges.appendAssumeCapacity(data);
                self.edge_offsets.appendAssumeCapacity(@intCast(self.edge_members.items.len));
                return id;
            }

            /// Consumes the builder.
            pub fn finish(self: *Builder, gpa: Allocator) Allocator.Error!Graph {
                const edge_offsets = try self.edge_offsets.toOwnedSlice(gpa);
                errdefer gpa.free(edge_offsets);
                const edge_members = try self.edge_members.toOwnedSlice(gpa);
                errdefer gpa.free(edge_members);
                const by_edge: EdgeMajor = .{ .offsets = edge_offsets, .cols = edge_members };
                const g: Graph = .{
                    .vertices = self.vertices,
                    .edges = self.edges,
                    .by_edge = by_edge,
                    .by_vertex = try by_edge.transpose(gpa, self.vertices.len),
                };
                self.* = undefined;
                return g;
            }
        };

        pub const Graph = struct {
            vertices: std.MultiArrayList(VertexData),
            edges: std.MultiArrayList(EdgeData),
            by_edge: EdgeMajor,
            by_vertex: VertexMajor,

            pub fn deinit(self: *Graph, gpa: Allocator) void {
                self.vertices.deinit(gpa);
                self.edges.deinit(gpa);
                self.by_edge.deinit(gpa);
                self.by_vertex.deinit(gpa);
                self.* = undefined;
            }

            pub inline fn vertexCount(self: Graph) u32 {
                return @intCast(self.by_vertex.rowCount());
            }

            pub inline fn edgeCount(self: Graph) u32 {
                return @intCast(self.by_edge.rowCount());
            }

            /// Pins of `e`, in terminal order.
            pub inline fn members(self: Graph, e: EdgeId) []const VertexId {
                return self.by_edge.row(e);
            }

            /// Edges touching `v`, sorted, once per pin on `v`.
            pub inline fn incident(self: Graph, v: VertexId) []const EdgeId {
                return self.by_vertex.row(v);
            }
        };
    };
}

test "members keep order and repeats; transpose is sorted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const H = BipartiteHypergraph(struct { name: []const u8 }, struct { year: u16 });
    var b = try H.Builder.init(gpa);
    for (0..5) |_| _ = try b.addVertex(gpa, .{ .name = "n" });
    const v: [5]VertexId = .{ .from(0), .from(1), .from(2), .from(3), .from(4) };
    _ = try b.addEdge(gpa, .{ .year = 1 }, &.{ v[2], v[0], v[1] });
    _ = try b.addEdge(gpa, .{ .year = 2 }, &.{ v[3], v[2], v[2], v[2] });
    try std.testing.expectError(error.InvalidVertex, b.addEdge(gpa, .{ .year = 3 }, &.{.from(9)}));
    const g = try b.finish(gpa);
    try std.testing.expectEqual(@as(u32, 2), g.edgeCount());
    try std.testing.expectEqualSlices(VertexId, &.{ v[3], v[2], v[2], v[2] }, g.members(.from(1)));
    try std.testing.expectEqualSlices(EdgeId, &.{ .from(0), .from(1), .from(1), .from(1) }, g.incident(v[2]));
    try std.testing.expectEqual(@as(usize, 0), g.incident(v[4]).len);
    try std.testing.expectEqual(@as(u16, 2), g.edges.items(.year)[1]);
}
