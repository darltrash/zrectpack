//! stb_rect_pack-inspired rect packing utility. Like stb_rect_pack, this module implements the
//! skyline rect-packing algorithm. Unlike stb_rect_pack, it only implements the bottom-left
//! heuristic.

/// Rect type that the packer operates on.
pub const Rect = struct {
    /// Reserved for your use.
    id: u32,
    /// Width, supplied by you.
    w: u32,
    /// Height, supplied by you.
    h: u32,
    /// Packing result. Should be initialized to `.not_placed` (default). Updated during packing.
    result: PackResult = .not_placed,
};

/// Indicates whether a rect was placed, and if so, where.
pub const PackResult = union(enum) {
    not_placed,
    placed: struct { x: u32, y: u32 },
};

/// A node representing a point in the skyline and the width it covers.
const Node = struct { x: u32, y: u32, w: u32 };

/// Sorts the supplied indices according by height of their respective rect
const Sort = struct {
    rects: []Rect,
    idxs: []usize,

    pub fn lessThan(ctx: Sort, a: usize, b: usize) bool {
        const lhs = ctx.rects[ctx.idxs[a]];
        const rhs = ctx.rects[ctx.idxs[b]];
        return lhs.h > rhs.h or (lhs.h == rhs.h and lhs.w > rhs.w);
    }

    pub fn swap(ctx: Sort, a: usize, b: usize) void {
        std.mem.swap(usize, &ctx.idxs[a], &ctx.idxs[b]);
    }
};

pub const Packer = struct {
    /// Bin width.
    w: u32,
    /// Bin height.
    h: u32,
    /// The skyline, ordered by x-pos in strictly increasing order.
    nodes: ArrayList(Node),

    pub fn init(allocator: Allocator, w: u32, h: u32) !Packer {
        var nodes: ArrayList(Node) = .empty;
        try nodes.append(allocator, .{ .w = w, .x = 0, .y = 0 });

        return .{
            .w = w,
            .h = h,
            .nodes = nodes,
        };
    }

    pub fn deinit(self: *Packer, allocator: Allocator) void {
        self.nodes.deinit(allocator);
        self.* = undefined;
    }

    /// Pack the supplied rects. Returns `true` if all rects were packed, `false` otherwise.
    pub fn pack(self: *Packer, allocator: Allocator, rects: []Rect) !bool {
        const rect_indices = blk: {
            var idxs = try allocator.alloc(usize, rects.len);
            for (0..idxs.len) |i| idxs[i] = i;
            std.sort.pdqContext(0, rects.len, Sort{ .rects = rects, .idxs = idxs });
            break :blk idxs;
        };
        defer allocator.free(rect_indices);

        var all_rects_packed = true;
        for (rect_indices) |i| {
            const rect = &rects[i];
            if (rect.w == 0 or rect.h == 0) {
                all_rects_packed = false;
                continue;
            }

            const result = self.findResult(rect.*) orelse {
                all_rects_packed = false;
                continue;
            };

            const new_node: Node = .{
                .x = self.nodes.items[result.idx].x,
                .y = result.y + rect.h,
                .w = rect.w,
            };

            rect.result = .{
                .placed = .{ .x = new_node.x, .y = result.y },
            };

            try self.insertNode(allocator, result.idx, new_node);
        }
        return all_rects_packed;
    }

    /// Locates the skyline node that can accommodate the rect while maintaining the lowest skyline.
    fn findResult(self: *Packer, rect: Rect) ?struct { idx: usize, y: u32 } {
        var maybe_best_idx: ?usize = null;
        var best_y: u32 = std.math.maxInt(u32);

        for (0..self.nodes.items.len) |start| {
            const node = self.nodes.items[start];

            // If the rect at this node would exceed the bin width, bail
            if (node.x + rect.w > self.w) break;

            // locate the highest point that the rect can be placed at
            const top_y: u32 = blk: {
                var accumulated_width: u32 = 0;
                var top_y: u32 = node.y;
                for (self.nodes.items[start..]) |seg| {
                    accumulated_width += seg.w;
                    top_y = @max(top_y, seg.y);
                    if (accumulated_width >= rect.w) break :blk top_y;
                }
                // this should be unreachable if the nodes array is well-formed
                unreachable;
            };

            // If the rect at this node would exceed the bin height, bail
            if (top_y + rect.h > self.h) continue;

            // prefer the node with the lowest y-pos
            if (top_y < best_y) {
                best_y = top_y;
                maybe_best_idx = start;
            }
        }

        return if (maybe_best_idx) |idx| .{
            .idx = idx,
            .y = best_y,
        } else null;
    }

    /// Inserts a new node and at the specified position.
    fn insertNode(self: *Packer, gpa: Allocator, i: usize, node: Node) !void {
        // TODO: There's probably a clever way to only do all node updates with a single replaceRange call
        try self.nodes.insert(gpa, i, node);

        var cover = self.nodes.items[i].w;
        var idx = i + 1;

        while (cover > 0 and idx < self.nodes.items.len) {
            const n = &self.nodes.items[idx];

            if (cover < n.w) {
                // rectangle ends in the middle of this run -> shorten & shift it
                n.x += cover;
                n.w -= cover;
                cover = 0;
            } else {
                // run fully covered -> delete it
                cover -= n.w;
                _ = self.nodes.orderedRemove(idx);
                continue;
            }

            if (cover > 0) idx += 1;
        }

        // If the node to the right has the same height, delete it.
        if (i + 1 < self.nodes.items.len and self.nodes.items[i].y == self.nodes.items[i + 1].y) {
            self.nodes.items[i].w += self.nodes.items[i + 1].w;
            _ = self.nodes.orderedRemove(i + 1);
        }

        // assert that:
        // - there's at least a 1 node
        // - x positions are in strictly increasing order
        // - the accumulated width of all nodes equals the bin width
        std.debug.assert(blk: {
            if (self.nodes.items.len == 0) break :blk false;
            var prev = self.nodes.items[0];
            var acc_w = prev.w;
            for (self.nodes.items[1..]) |n| {
                if (n.x <= prev.x) break :blk false;
                if (prev.x + prev.w != n.x) break :blk false;
                acc_w += n.w;
                prev = n;
            }
            if (self.w != acc_w) break :blk false;
            break :blk true;
        });
    }
};

test "smoke" {
    const alloc = std.testing.allocator;

    var packer = try Packer.init(alloc, 512, 512);
    defer packer.deinit(alloc);

    var rects: ArrayList(Rect) = .empty;
    defer rects.deinit(alloc);

    try rects.appendSlice(alloc, &.{
        .{ .id = 1, .w = 128, .h = 128 },
        .{ .id = 2, .w = 16, .h = 16 },
        .{ .id = 3, .w = 32, .h = 32 },
        .{ .id = 4, .w = 32, .h = 64 },
        .{ .id = 5, .w = 64, .h = 32 },
        .{ .id = 6, .w = 64, .h = 32 },
        .{ .id = 7, .w = 64, .h = 64 },
        .{ .id = 8, .w = 16, .h = 16 },
        .{ .id = 9, .w = 32, .h = 32 },
        .{ .id = 10, .w = 32, .h = 64 },
        .{ .id = 11, .w = 64, .h = 8 },
        .{ .id = 12, .w = 64, .h = 128 },
        .{ .id = 13, .w = 32, .h = 16 },
        .{ .id = 14, .w = 32, .h = 32 },
        .{ .id = 15, .w = 64, .h = 128 },
    });
    _ = try packer.pack(alloc, rects.items);

    for (rects.items) |rect| {
        try std.testing.expect(rect.result == .placed);
    }
}

test "readme example" {
    const alloc = std.testing.allocator;

    var packer = try Packer.init(alloc, 200, 128);
    defer packer.deinit(alloc);

    var rects: std.ArrayListUnmanaged(Rect) = .empty;
    defer rects.deinit(alloc);

    try rects.appendSlice(alloc, &.{
        .{ .id = 1, .w = 128, .h = 128 },
        .{ .id = 2, .w = 16, .h = 16 },
        .{ .id = 3, .w = 32, .h = 32 },
        .{ .id = 4, .w = 32, .h = 64 },
        .{ .id = 5, .w = 64, .h = 32 },
    });

    _ = try packer.pack(alloc, rects.items);

    for (rects.items) |rect| {
        switch (rect.result) {
            .placed => |pos| std.debug.print("rect {} placed at ({}, {})\n", .{ rect.id, pos.x, pos.y }),
            .not_placed => std.debug.print("rect {} couldn't be placed\n", .{rect.id}),
        }
    }
}

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
