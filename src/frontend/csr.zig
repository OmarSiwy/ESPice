//! Bipartite hypergraph: nets are vertices, devices are hyperedges.
//! Adapted from cktImg src/csr.zig, Copyright (c) 2026 Omar El-Sawy, MIT License.
//!
//! An edge's member list is its pin list: order is the terminal role and
//! repeats are kept (bulk tied to source). Topology is one edge-major CSR;
//! payload is SoA in `MultiArrayList`s.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Index of a net.
pub const VertexId = enum(u32) {
    _,
    pub inline fn from(i: usize) VertexId {
        return @enumFromInt(@as(u32, @intCast(i)));
    }
    pub inline fn index(self: VertexId) u32 {
        return @intFromEnum(self);
    }
};

/// Index of a device.
pub const EdgeId = enum(u32) {
    _,
    pub inline fn from(i: usize) EdgeId {
        return @enumFromInt(@as(u32, @intCast(i)));
    }
    pub inline fn index(self: EdgeId) u32 {
        return @intFromEnum(self);
    }
};

/// Hypergraph over vertex payload `VertexData` and edge payload `EdgeData`.
/// ponytail: edge-major only; add the vertex-major transpose when a pass
/// needs the devices on a net.
pub fn BipartiteHypergraph(comptime VertexData: type, comptime EdgeData: type) type {
    return struct {
        /// Why `addVertex`/`addEdge` refused: a member that is no vertex, or a
        /// count past u32.
        pub const Error = error{ InvalidVertex, TooManyVertices, TooManyEdges, TooManyIncidences } || Allocator.Error;

        /// Append-only. Each edge arrives with its full member list; `finish`
        /// freezes the tables into a `Graph`.
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

            /// Reserves room for the given totals so the adds below do not reallocate.
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

            /// Stores `members` in the given order, repeats included.
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

            /// Consumes the builder; the graph owns its tables in `gpa`.
            pub fn finish(self: *Builder, gpa: Allocator) Allocator.Error!Graph {
                const offsets = try self.edge_offsets.toOwnedSlice(gpa);
                errdefer gpa.free(offsets);
                const g: Graph = .{
                    .vertices = self.vertices,
                    .edges = self.edges,
                    .offsets = offsets,
                    .members = try self.edge_members.toOwnedSlice(gpa),
                };
                self.* = undefined;
                return g;
            }
        };

        /// Frozen hypergraph. Edge `e`'s pins are `members[offsets[e]..offsets[e + 1]]`.
        pub const Graph = struct {
            vertices: std.MultiArrayList(VertexData),
            edges: std.MultiArrayList(EdgeData),
            offsets: []const u32,
            members: []const VertexId,

            pub inline fn vertexCount(self: Graph) u32 {
                return @intCast(self.vertices.len);
            }

            pub inline fn edgeCount(self: Graph) u32 {
                return @intCast(self.edges.len);
            }

            /// Pins of `e`, in terminal order.
            pub inline fn pins(self: Graph, e: EdgeId) []const VertexId {
                return self.members[self.offsets[e.index()]..self.offsets[e.index() + 1]];
            }
        };
    };
}

test "members keep order and repeats" {
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
    try std.testing.expectEqual(@as(u32, 5), g.vertexCount());
    try std.testing.expectEqualSlices(VertexId, &.{ v[2], v[0], v[1] }, g.pins(.from(0)));
    try std.testing.expectEqualSlices(VertexId, &.{ v[3], v[2], v[2], v[2] }, g.pins(.from(1)));
    try std.testing.expectEqual(@as(u16, 2), g.edges.items(.year)[1]);
}
