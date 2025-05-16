pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var bench = zbench.Benchmark.init(gpa, .{});
    defer bench.deinit();
    const zrpBenchmark = try ZrpBenchmark.init(gpa);
    defer zrpBenchmark.deinit(gpa);
    try bench.addParam("zrectpack Benchmark", &zrpBenchmark, .{});
    const stbrpBenchmark = try StbrpBenchmark.init(gpa);
    defer stbrpBenchmark.deinit(gpa);
    try bench.addParam("stb_rect_pack Benchmark", &stbrpBenchmark, .{});
    try bench.run(std.io.getStdOut().writer());
}

const generate_opts: u.GenerateRectsOpts = .{
    .seed = 12345,
    .num_rects = 1000,
    .min_w = 2,
    .min_h = 2,
    .max_w = 128,
    .max_h = 128,
};

const ZrpBenchmark = struct {
    const Self = @This();
    rects: []zrp.Rect,

    fn init(gpa: std.mem.Allocator) !Self {
        const rects = try u.generateRects(gpa, .zrectpack, generate_opts);
        return .{ .rects = rects };
    }

    fn deinit(self: Self, gpa: std.mem.Allocator) void {
        gpa.free(self.rects);
    }

    pub fn run(self: Self, gpa: std.mem.Allocator) void {
        var packer = zrp.Packer.init(gpa, .{ .bin_w = 800, .bin_h = 3000 }) catch @panic("failed");
        defer packer.deinit(gpa);
        _ = packer.pack(gpa, self.rects) catch @panic("failed");
    }
};

const StbrpBenchmark = struct {
    const Self = @This();
    rects: []stbrp.stbrp_rect,

    fn init(gpa: std.mem.Allocator) !Self {
        const rects = try u.generateRects(gpa, .stb, generate_opts);
        return .{ .rects = rects };
    }

    fn deinit(self: Self, gpa: std.mem.Allocator) void {
        gpa.free(self.rects);
    }

    pub fn run(self: Self, gpa: std.mem.Allocator) void {
        var packer = u.StbRectPack.init(gpa, .{ .bin_w = 800, .bin_h = 3000 }) catch @panic("failed");
        defer packer.deinit(gpa);
        _ = packer.pack(self.rects);
    }
};

const std = @import("std");
const zbench = @import("zbench");
const zrp = @import("zrectpack");
const stbrp = @import("stbrp");
const u = @import("util.zig");
