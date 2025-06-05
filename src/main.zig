const SCREEN_WIDTH = 800;
const SCREEN_HEIGHT = 600;
const RECT_ATTRS_SIZE = 8;
const DEFAULT_NUM_RECTS = 100;
const DEFAULT_VBO_CAPACITY = std.math.ceilPowerOfTwo(u32, DEFAULT_NUM_RECTS * RECT_ATTRS_SIZE) catch @compileError("capacity overflow");

const Mat4 = [16]f32;
const Vec2 = [2]f32;
const VsParams = extern struct { u_proj: Mat4 };

const PackRun = struct {
    seed: u64,
    impl: u.RectPackImpl,
    bin_width: u32,
    bin_height: u32,
    elapsed: u64,
    stats: u.PackStats,
    heuristic: c_int, // only used with stbrp
};

const RectPackOptions = struct {
    impl: u.RectPackImpl = .zrectpack,
    heuristic: c_int = stbrp.STBRP_HEURISTIC_Skyline_BL_sortHeight, // only used with stb_rect_pack
    bin_height: c_int = SCREEN_HEIGHT,
    bin_width: c_int = SCREEN_WIDTH,
    bin_height_viewport_sync: bool = true,
    bin_width_viewport_sync: bool = true,
};

const RectGenerationOptions = struct {
    seed: c_int = 12345,
    rects_to_generate: c_int = DEFAULT_NUM_RECTS,
    min_w: c_int = 1,
    min_h: c_int = 1,
    max_w: c_int = 128,
    max_h: c_int = 128,
};

const state = struct {
    var bind: sg.Bindings = .{};
    var pip: sg.Pipeline = .{};
    var pass_action: sg.PassAction = .{};
    var rect_instance_attrs: ArrayList(f32) = .empty;
    var vbo_capacity: u32 = undefined;
    var scroll_y: f32 = 0;
    var scroll_x: f32 = 0;
    var is_panning: bool = false;
    var last_pointer_x: f32 = 0.0;
    var last_pointer_y: f32 = 0.0;
    var rectpack_opts: RectPackOptions = .{};
    var rect_generation_opts: RectGenerationOptions = .{};
    var last_run: ?PackRun = null;
    var pack_error: bool = false;
    var buffer_updated_this_frame: bool = false;
};

fn ortho(left: f32, right: f32, top: f32, bottom: f32) Mat4 {
    return [_]f32{
        2.0 / (right - left),             0.0,                             0.0, 0.0,
        0.0,                              -2.0 / (bottom - top),           0.0, 0.0,
        0.0,                              0.0,                             1.0, 0.0,
        -(right + left) / (right - left), (bottom + top) / (bottom - top), 0.0, 1.0,
    };
}

fn bindRectInstanceBuffer(capacity: u32) void {
    std.log.debug("binding rect instance buffer with capacity: {}", .{capacity});
    state.bind.vertex_buffers[1] = sg.makeBuffer(.{
        .label = "rect instance buffer",
        .usage = .STREAM,
        .size = capacity,
    });
    state.vbo_capacity = capacity;
}

fn resizeRectInstanceBufferIfNeeded() !void {
    const bytes_needed: usize = state.rect_instance_attrs.items.len * @sizeOf(f32);
    if (bytes_needed <= state.vbo_capacity) return;
    std.log.debug("rect instance buffer needs resizing", .{});
    if (bytes_needed > std.math.maxInt(u32)) {
        std.log.err("buffer size exceeds maximum value", .{});
        return error.OutOfMemory;
    }
    const new_capacity = try std.math.ceilPowerOfTwo(u32, @intCast(bytes_needed));
    sg.destroyBuffer(state.bind.vertex_buffers[1]);
    bindRectInstanceBuffer(new_capacity);
}

export fn init() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });

    simgui.setup(.{
        .logger = .{ .func = slog.func },
    });

    state.bind.vertex_buffers[0] = sg.makeBuffer(.{
        .label = "unit quad indices",
        .data = sg.asRange(&[_]f32{
            0.0, 0.0, // top-left
            1.0, 0.0, // top-right
            1.0, 1.0, // bottom-right
            0.0, 1.0, // bottom-left
        }),
    });

    state.bind.index_buffer = sg.makeBuffer(.{
        .label = "unit quad indices",
        .type = .INDEXBUFFER,
        .data = sg.asRange(&[_]u16{ 0, 1, 2, 2, 3, 0 }),
    });

    bindRectInstanceBuffer(DEFAULT_VBO_CAPACITY);

    state.pip = sg.makePipeline(.{
        .shader = sg.makeShader(shd.quadShaderDesc(sg.queryBackend())),
        .layout = init: {
            var l = sg.VertexLayoutState{};
            l.attrs[shd.ATTR_quad_a_pos].format = .FLOAT2;
            l.attrs[shd.ATTR_quad_a_pos].buffer_index = 0;

            l.buffers[1].step_func = .PER_INSTANCE;
            l.buffers[1].stride = 32;
            l.attrs[shd.ATTR_quad_a_instance_pos].format = .FLOAT2;
            l.attrs[shd.ATTR_quad_a_instance_pos].buffer_index = 1;
            l.attrs[shd.ATTR_quad_a_instance_pos].offset = 0;

            l.attrs[shd.ATTR_quad_a_instance_size].format = .FLOAT2;
            l.attrs[shd.ATTR_quad_a_instance_size].buffer_index = 1;
            l.attrs[shd.ATTR_quad_a_instance_size].offset = 8;

            l.attrs[shd.ATTR_quad_a_instance_color].format = .FLOAT4;
            l.attrs[shd.ATTR_quad_a_instance_color].buffer_index = 1;
            l.attrs[shd.ATTR_quad_a_instance_color].offset = 16;
            break :init l;
        },
        .index_type = .UINT16,
    });

    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };

    // Perform initial pack with default settings
    pack(.zrectpack) catch |e| {
        state.pack_error = true;
        std.log.err("Initial pack failed: {}", .{e});
    };
}

export fn frame() void {
    state.buffer_updated_this_frame = false;
    const viewport_width = sapp.width();
    const viewport_height = sapp.height();
    const dt = sapp.frameDuration();
    const dpi_scale = sapp.dpiScale();

    drawUi(viewport_width, viewport_height, dt, dpi_scale) catch |e| {
        state.pack_error = true;
        std.log.err("An error occurred! Here's a mostly useless error message: {}", .{e});
    };
    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    sg.applyPipeline(state.pip);
    sg.applyBindings(state.bind);
    const u_proj = ortho(
        state.scroll_x,
        state.scroll_x + @as(f32, @floatFromInt(viewport_width)),
        state.scroll_y,
        state.scroll_y + @as(f32, @floatFromInt(viewport_height)),
    );
    sg.applyUniforms(shd.UB_vs_params, sg.asRange(&u_proj));
    if (state.last_run) |stats| {
        sg.draw(0, 6, stats.stats.rects_packed);
    }
    simgui.render();
    sg.endPass();
    sg.commit();
}

fn drawUi(viewport_width: i32, viewport_height: i32, dt: f64, dpi_scale: f32) !void {
    simgui.newFrame(.{
        .width = viewport_width,
        .height = viewport_height,
        .delta_time = dt,
        .dpi_scale = dpi_scale,
    });

    ig.igSetNextWindowPos(.{ .x = 10, .y = 10 }, ig.ImGuiCond_Once);
    ig.igSetNextWindowSize(.{ .x = 300, .y = 400 }, ig.ImGuiCond_Once);
    _ = ig.igBegin("zrectpack", 0, ig.ImGuiWindowFlags_None);
    defer ig.igEnd();

    ig.igText("You can scroll and pan the view!");

    if (ig.igCollapsingHeader("packing options", ig.ImGuiTreeNodeFlags_None)) {
        _ = ig.igRadioButtonIntPtr(
            "zrectpack",
            @ptrCast(&state.rectpack_opts.impl),
            @intFromEnum(u.RectPackImpl.zrectpack),
        );
        ig.igSameLine();
        _ = ig.igRadioButtonIntPtr(
            "stb_rect_pack",
            @ptrCast(&state.rectpack_opts.impl),
            @intFromEnum(u.RectPackImpl.stb),
        );

        if (state.rectpack_opts.impl == .stb) {
            _ = ig.igRadioButtonIntPtr("bottom left", &state.rectpack_opts.heuristic, stbrp.STBRP_HEURISTIC_Skyline_BL_sortHeight);
            ig.igSameLine();
            _ = ig.igRadioButtonIntPtr("best fit", &state.rectpack_opts.heuristic, stbrp.STBRP_HEURISTIC_Skyline_BF_sortHeight);
        }

        ig.igSetNextItemWidth(50);

        if (ig.igInputIntEx("bin width", &state.rectpack_opts.bin_width, 0, 0, ig.ImGuiInputTextFlags_None)) {
            state.rectpack_opts.bin_width = @max(1, state.rectpack_opts.bin_width);
        }

        ig.igSameLine();

        if (ig.igCheckbox("Sync to viewport##w", &state.rectpack_opts.bin_width_viewport_sync)) {
            if (state.rectpack_opts.bin_width_viewport_sync) state.rectpack_opts.bin_width = viewport_width;
        }

        ig.igSeparator();

        ig.igSetNextItemWidth(50);
        if (ig.igInputIntEx("bin height", &state.rectpack_opts.bin_height, 0, 0, ig.ImGuiInputTextFlags_None)) {
            state.rectpack_opts.bin_height = @max(1, state.rectpack_opts.bin_height);
        }

        ig.igSameLine();

        if (ig.igCheckbox("Sync to viewport##h", &state.rectpack_opts.bin_height_viewport_sync)) {
            if (state.rectpack_opts.bin_height_viewport_sync) state.rectpack_opts.bin_height = viewport_height;
        }
    }

    if (ig.igCollapsingHeader("rect generation options", ig.ImGuiTreeNodeFlags_None)) {
        ig.igSetNextItemWidth(50);
        if (ig.igInputIntEx("seed", &state.rect_generation_opts.seed, 0, 0, ig.ImGuiInputTextFlags_None)) {
            state.rect_generation_opts.seed = @max(0, state.rect_generation_opts.seed);
        }

        ig.igSetNextItemWidth(50);
        if (ig.igInputIntEx("min width", &state.rect_generation_opts.min_w, 0, 0, ig.ImGuiInputTextFlags_None)) {
            state.rect_generation_opts.min_w = @max(0, state.rect_generation_opts.min_w);
        }

        ig.igSameLine();

        ig.igSetNextItemWidth(50);
        if (ig.igInputIntEx("min height", &state.rect_generation_opts.min_h, 0, 0, ig.ImGuiInputTextFlags_None)) {
            state.rect_generation_opts.min_h = @max(0, state.rect_generation_opts.min_h);
        }

        ig.igSetNextItemWidth(50);
        if (ig.igInputIntEx("max width", &state.rect_generation_opts.max_w, 0, 0, ig.ImGuiInputTextFlags_None)) {
            state.rect_generation_opts.max_w = @max(0, state.rect_generation_opts.max_w);
        }

        ig.igSameLine();

        ig.igSetNextItemWidth(50);
        if (ig.igInputIntEx("max height", &state.rect_generation_opts.max_h, 0, 0, ig.ImGuiInputTextFlags_None)) {
            state.rect_generation_opts.max_h = @max(0, state.rect_generation_opts.max_h);
        }

        ig.igSetNextItemWidth(50);
        if (ig.igInputIntEx("count", &state.rect_generation_opts.rects_to_generate, 0, 0, ig.ImGuiInputTextFlags_None)) {
            state.rect_generation_opts.rects_to_generate = @max(0, state.rect_generation_opts.rects_to_generate);
        }
    }

    if (ig.igButton("pack!")) {
        switch (state.rectpack_opts.impl) {
            .zrectpack => try pack(.zrectpack),
            .stb => try pack(.stb),
        }
    }

    if (state.pack_error) {
        _ = ig.igTextColored(ig.ImVec4{ .x = 1, .y = 0, .z = 0, .w = 1 }, "An error occurred! See logs for details.", .{});
    } else {
        if (state.last_run) |run| {
            var buf: [64]u8 = undefined;
            const heuristic = if (run.impl == .zrectpack) "bottom-left" else if (run.heuristic == stbrp.STBRP_HEURISTIC_Skyline_BL_sortHeight) "bottom-left" else "best-fit";
            const cstr = std.fmt.bufPrintZ(&buf, "impl: {s} ({s})", .{ @tagName(run.impl), heuristic }) catch "err";
            _ = ig.igText("%s", cstr.ptr);
            _ = ig.igText("placed: %d ", run.stats.rects_packed);
            _ = ig.igText("not placed: %d ", run.stats.rects_not_packed);
            _ = ig.igText("packing bounds: %d,%d ", run.stats.pack_width, run.stats.pack_height);
            _ = ig.igText("waste: %f", run.stats.waste);
            _ = ig.igText("elapsed: %f ms", @as(f64, @floatFromInt(run.elapsed)) / 1_000_000);
        }
    }
}

export fn cleanup() void {
    state.rect_instance_attrs.deinit(gpa);
    simgui.shutdown();
    sg.shutdown();
}

export fn event(ev: [*c]const sapp.Event) void {
    // forward input events to sokol-imgui and swallow them if handled
    if (simgui.handleEvent(ev.*)) return;

    switch (ev.*.type) {
        .MOUSE_DOWN, .TOUCHES_BEGAN => {
            state.is_panning = true;
            state.last_pointer_x = ev.*.mouse_x;
            state.last_pointer_y = ev.*.mouse_y;
        },
        .MOUSE_UP, .TOUCHES_ENDED => {
            state.is_panning = false;
        },
        .MOUSE_MOVE, .TOUCHES_MOVED => {
            if (state.is_panning) {
                const dx = ev.*.mouse_x - state.last_pointer_x;
                const dy = ev.*.mouse_y - state.last_pointer_y;
                state.scroll_x -= dx;
                state.scroll_y -= dy;
                state.last_pointer_x = ev.*.mouse_x;
                state.last_pointer_y = ev.*.mouse_y;
            }
        },
        .MOUSE_SCROLL => {
            const SCROLL_SPEED = 10;
            state.scroll_x = state.scroll_x - ev.*.scroll_x * SCROLL_SPEED;
            state.scroll_y = state.scroll_y - ev.*.scroll_y * SCROLL_SPEED;
        },
        .RESIZED => {
            var should_repack = false;
            if (state.rectpack_opts.bin_width_viewport_sync) {
                state.rectpack_opts.bin_width = sapp.width();
                should_repack = true;
            }
            if (state.rectpack_opts.bin_height_viewport_sync) {
                state.rectpack_opts.bin_height = sapp.height();
                should_repack = true;
            }
            if (should_repack and state.last_run != null) {
                switch (state.rectpack_opts.impl) {
                    .zrectpack => pack(.zrectpack) catch |e| {
                        state.pack_error = true;
                        std.log.err("Pack error on resize: {}", .{e});
                    },
                    .stb => pack(.stb) catch |e| {
                        state.pack_error = true;
                        std.log.err("Pack error on resize: {}", .{e});
                    },
                }
            }
        },
        else => {},
    }
}

pub fn main() void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .width = SCREEN_WIDTH,
        .height = SCREEN_HEIGHT,
        .icon = .{ .sokol_default = true },
        .window_title = "zrectpack",
        .logger = .{ .func = slog.func },
    });
}

fn pack(comptime impl: u.RectPackImpl) !void {
    if (state.rectpack_opts.bin_width_viewport_sync) {
        state.rectpack_opts.bin_width = sapp.width();
    }
    if (state.rectpack_opts.bin_height_viewport_sync) {
        state.rectpack_opts.bin_height = sapp.height();
    }

    state.pack_error = false;
    state.scroll_y = 0;
    state.scroll_x = 0;

    const bin_w: u32 = @intCast(state.rectpack_opts.bin_width);
    const bin_h: u32 = @intCast(state.rectpack_opts.bin_height);

    // TODO: find a way to have imgui bind to an actual u64
    const seed: u64 = @intCast(state.rect_generation_opts.seed);
    const num_rects: u64 = @intCast(state.rect_generation_opts.rects_to_generate);
    const min_width: i32 = @intCast(state.rect_generation_opts.min_w);
    const min_height: i32 = @intCast(state.rect_generation_opts.min_h);
    const max_width: i32 = @intCast(state.rect_generation_opts.max_w);
    const max_height: i32 = @intCast(state.rect_generation_opts.max_h);
    const rects = try u.generateRects(gpa, impl, .{
        .seed = seed,
        .num_rects = num_rects,
        .min_w = min_width,
        .min_h = min_height,
        .max_w = max_width,
        .max_h = max_height,
    });
    defer gpa.free(rects);

    const elapsed = brk: switch (impl) {
        .zrectpack => {
            var packer = try Packer.init(gpa, .{ .bin_w = bin_w, .bin_h = bin_h });
            defer packer.deinit(gpa);
            var timer = try std.time.Timer.start();
            _ = try packer.pack(gpa, rects);
            break :brk timer.read();
        },
        .stb => {
            var stb_rect_pack: u.StbRectPack = try .init(gpa, .{
                .bin_w = bin_w,
                .bin_h = bin_h,
                .heuristic = state.rectpack_opts.heuristic,
            });
            defer stb_rect_pack.deinit(gpa);

            var timer = try std.time.Timer.start();
            _ = stb_rect_pack.pack(rects);
            break :brk timer.read();
        },
    };

    try updateInstanceAttrs(impl, rects);

    state.last_run = .{
        .seed = @intCast(state.rect_generation_opts.seed),
        .impl = impl,
        .bin_width = bin_w,
        .bin_height = bin_h,
        .elapsed = elapsed,
        .stats = u.calcStats(impl, rects),
        .heuristic = state.rectpack_opts.heuristic,
    };

    try resizeRectInstanceBufferIfNeeded();
    if (!state.buffer_updated_this_frame) {
        sg.updateBuffer(state.bind.vertex_buffers[1], sg.asRange(state.rect_instance_attrs.items));
        state.buffer_updated_this_frame = true;
    }
}

fn updateInstanceAttrs(comptime impl: u.RectPackImpl, rects: []const u.RectType(impl)) !void {
    state.rect_instance_attrs.clearAndFree(gpa);
    try state.rect_instance_attrs.ensureTotalCapacity(gpa, rects.len * RECT_ATTRS_SIZE);
    for (rects) |rect| {
        const id: usize, const w: u32, const h: u32, const x: u32, const y: u32 = blk: {
            switch (impl) {
                .zrectpack => {
                    switch (rect.result) {
                        .placed => |pos| break :blk .{ rect.id, rect.w, rect.h, pos.x, pos.y },
                        .not_placed => continue,
                    }
                },
                .stb => {
                    if (rect.was_packed > 0) break :blk .{ @intCast(rect.id), @intCast(rect.w), @intCast(rect.h), @intCast(rect.x), @intCast(rect.y) } else continue;
                },
            }
        };
        const tau: f32 = std.math.pi * 2;
        const hue: f32 = @mod((@as(f32, @floatFromInt(id)) * 0.15), tau);
        const r: f32 = @sin(hue) * 0.5 + 0.5;
        const g: f32 = @sin(hue + 2.1) * 0.5 + 0.5;
        const b: f32 = @sin(hue + 4.2) * 0.5 + 0.5;
        const a = 1.0;
        try state.rect_instance_attrs.appendSlice(gpa, &.{
            @floatFromInt(x),
            @floatFromInt(y),
            @floatFromInt(w),
            @floatFromInt(h),
            r,
            g,
            b,
            a,
        });
    }
}

test "bottom-left results are identical" {
    const allocator = std.testing.allocator;

    const opts_template: u.GenerateRectsOpts = .{
        .seed = 0,
        .num_rects = 512,
        .min_w = 2,
        .min_h = 2,
        .max_w = 128,
        .max_h = 128,
    };

    const bin_w = 640;
    const bin_h = 3600;

    for (0..100) |seed| {
        for (0..100) |i| {
            const gen_opts = blk: {
                var gen_opts = opts_template;
                gen_opts.seed = seed;
                break :blk gen_opts;
            };
            const bin_w_to_test: u32 = @intCast(bin_w - i);
            const bin_h_to_test: u32 = @intCast(bin_h - i);
            const zrectpack_rects = try u.generateRects(allocator, .zrectpack, gen_opts);
            defer allocator.free(zrectpack_rects);

            var packer = try Packer.init(allocator, .{ .bin_w = bin_w_to_test, .bin_h = bin_h_to_test });
            defer packer.deinit(allocator);
            _ = try packer.pack(allocator, zrectpack_rects);

            const stb_rects = try u.generateRects(allocator, .stb, gen_opts);
            defer allocator.free(stb_rects);
            var stbPacker = try u.StbRectPack.init(allocator, .{
                .bin_w = bin_w_to_test,
                .bin_h = bin_h_to_test,
            });
            defer stbPacker.deinit(allocator);
            _ = stbPacker.pack(stb_rects);

            const zrpStats = u.calcStats(.zrectpack, zrectpack_rects);
            const stbStats = u.calcStats(.stb, stb_rects);

            try std.testing.expectEqual(stbStats, zrpStats);
        }
    }
}

const std = @import("std");
const gpa = std.heap.c_allocator;
const sokol = @import("sokol");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const simgui = @import("sokol").imgui;
const ArrayList = std.ArrayListUnmanaged;
const ig = @import("dcimgui");
const shd = @import("shader.zig");
const Packer = @import("zrectpack").Packer;
const Rect = @import("zrectpack").Rect;
const stbrp = @import("stbrp");
const u = @import("util.zig");
