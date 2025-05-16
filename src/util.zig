pub const RectPackImpl = enum(i32) { zrectpack = 0, stb = 1 };

pub fn RectType(ty: RectPackImpl) type {
    return switch (ty) {
        .zrectpack => Rect,
        .stb => stbrp_rect,
    };
}

pub const PackStats = struct {
    pack_height: u32,
    pack_width: u32,
    rects_packed: u32,
    rects_not_packed: u32,
    area: u32,
    waste: f32,
};

pub const GenerateRectsOpts = struct {
    seed: u64,
    num_rects: u64,
    min_w: i32,
    min_h: i32,
    max_w: i32,
    max_h: i32,
};

pub fn generateRects(gpa: std.mem.Allocator, comptime ty: RectPackImpl, opts: GenerateRectsOpts) ![]RectType(ty) {
    var prng = std.Random.DefaultPrng.init(opts.seed);
    const rand = prng.random();
    var rects = try ArrayList(RectType(ty)).initCapacity(gpa, @intCast(opts.num_rects));
    for (0..@intCast(opts.num_rects)) |i| {
        const w = rand.intRangeAtMost(i32, opts.min_w, opts.max_w);
        const h = rand.intRangeAtMost(i32, opts.min_h, opts.max_h);
        const rect = switch (ty) {
            .zrectpack => Rect{
                .id = @as(u32, @intCast(i)) + 1,
                .w = @intCast(w),
                .h = @intCast(h),
            },
            .stb => stbrp_rect{
                .id = @as(i32, @intCast(i)) + 1,
                .w = w,
                .h = h,
            },
        };
        try rects.append(gpa, rect);
    }
    return rects.toOwnedSlice(gpa);
}

pub const StbRectPack = struct {
    const Self = @This();
    ctx: *stbrp_context,
    nodes: []stbrp_node,

    pub fn init(gpa: std.mem.Allocator, opts: struct { bin_w: u32, bin_h: u32, heuristic: c_int = stb_heuristic_bl }) !Self {
        const ctx = try gpa.create(stbrp_context);
        const nodes = try gpa.alloc(stbrp_node, opts.bin_w);
        stbrp_init_target(ctx, @intCast(opts.bin_w), @intCast(opts.bin_h), nodes.ptr, @intCast(nodes.len));
        stbrp_setup_heuristic(ctx, opts.heuristic);
        return .{ .ctx = ctx, .nodes = nodes };
    }

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        gpa.free(self.nodes);
        gpa.destroy(self.ctx);
        self.* = undefined;
    }

    pub fn pack(self: *Self, rects: []stbrp_rect) c_int {
        return stbrp_pack_rects(self.ctx, rects.ptr, @intCast(rects.len));
    }
};

pub fn calcStats(comptime impl: RectPackImpl, rects: []const RectType(impl)) PackStats {
    var placed: u32, var not_placed: u32, var area: u32, var width: u32, var height: u32 = .{0} ** 5;
    for (rects) |rect| {
        switch (impl) {
            .zrectpack => {
                switch (rect.result) {
                    .placed => |pos| {
                        placed += 1;
                        area += rect.w * rect.h;
                        height = @max(height, pos.y + rect.h);
                        width = @max(width, pos.x + rect.w);
                    },
                    else => not_placed += 1,
                }
            },
            .stb => {
                if (rect.was_packed > 0) {
                    placed += @max(0, rect.was_packed);
                    area += @as(u32, @intCast(rect.w * rect.h));
                    height = @max(height, @as(u32, @intCast(rect.y + rect.h)));
                    width = @max(width, @as(u32, @intCast(rect.x + rect.w)));
                } else {
                    not_placed += 1;
                }
            },
        }
    }

    return .{
        .rects_packed = placed,
        .rects_not_packed = not_placed,
        .pack_width = width,
        .pack_height = height,
        .area = area,
        .waste = 1 - @as(f32, @floatFromInt(area)) / @as(f32, @floatFromInt(width * height)),
    };
}

const std = @import("std");
const ArrayList = std.ArrayListUnmanaged;
const Rect = @import("zrectpack").Rect;
const stbrp_rect = @import("stbrp").stbrp_rect;
const stbrp_node = @import("stbrp").stbrp_node;
const stbrp_context = @import("stbrp").stbrp_context;
const stbrp_init_target = @import("stbrp").stbrp_init_target;
const stbrp_pack_rects = @import("stbrp").stbrp_pack_rects;
const stbrp_setup_heuristic = @import("stbrp").stbrp_setup_heuristic;
const stb_heuristic_bl = @import("stbrp").STBRP_HEURISTIC_Skyline_BL_sortHeight;
const stb_heuristic_bf = @import("stbrp").STBRP_HEURISTIC_Skyline_BF_sortHeight;
