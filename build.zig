pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zrectpack = configureZrectpack(b, target, optimize);
    const sokol = configureSokol(b, target, optimize);
    const stbrp = configureStbRectPack(b, sokol, target, optimize);
    const zbench = configureZbench(b, target, optimize);
    const shdc_step = try configureCompileShadersStep(b);
    const demo = try configureDemo(b, zrectpack, sokol, stbrp, shdc_step, target, optimize);
    const benchmark = configureBenchmark(b, zrectpack, stbrp, zbench, target, optimize);
    configureUnitTests(b, &.{ zrectpack.mod, demo.mod, benchmark.mod });
}

fn configureUnitTests(b: *Build, test_modules: []const *Module) void {
    const test_step = b.step("test", "Run unit tests");
    for (test_modules) |test_module| {
        const test_ = b.addTest(.{ .root_module = test_module });
        test_step.dependOn(&b.addRunArtifact(test_).step);
    }
}

fn configureCompileShadersStep(b: *Build) !*Step {
    const run = try shdc.compile(b, .{
        .dep_shdc = b.dependency("sokolshdc", .{}),
        .input = b.path("src/shader.glsl"),
        .output = b.path("src/shader.zig"),
        .slang = .{
            .glsl300es = true,
            .glsl430 = true,
            .metal_macos = true,
            .hlsl5 = true,
        },
        .reflection = true,
    });
    const shdc_step = b.step("shdc", "Compile shaders");
    shdc_step.dependOn(&run.step);
    return shdc_step;
}

const ZRectpackConfig = struct { mod: *Module };
fn configureZrectpack(b: *Build, target: ResolvedTarget, optimize: OptimizeMode) ZRectpackConfig {
    const mod = b.addModule("zrectpack", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zrectpack",
        .root_module = mod,
    });

    b.installArtifact(lib);

    return .{ .mod = mod };
}

fn configureDemo(
    b: *Build,
    zrectpack: ZRectpackConfig,
    sokol: SokolConfig,
    stbrp: StbRectPackConfig,
    shdc_step: *Build.Step,
    target: ResolvedTarget,
    optimize: OptimizeMode,
) !struct { mod: *Module } {
    const mod_demo = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zrectpack", .module = zrectpack.mod },
            .{ .name = "sokol", .module = sokol.mod },
            .{ .name = "dcimgui", .module = sokol.mod_cimgui },
            .{ .name = "stbrp", .module = stbrp.mod },
        },
    });
    mod_demo.linkLibrary(stbrp.lib);

    const compile_demo: *Step.Compile, const step_run: *Step.Run = blk: {
        if (target.result.cpu.arch.isWasm()) {
            const emLinkStep = @import("sokol").emLinkStep;
            const emRunStep = @import("sokol").emRunStep;

            const compile_demo = b.addStaticLibrary(.{
                .name = "demo",
                .root_module = mod_demo,
            });

            const link_step = try emLinkStep(b, .{
                .lib_main = compile_demo,
                .target = mod_demo.resolved_target.?,
                .optimize = mod_demo.optimize.?,
                .emsdk = sokol.dep_emsdk,
                .use_webgl2 = true,
                .use_emmalloc = true,
                .use_offset_converter = true,
                .use_filesystem = false,
                .shell_file_path = b.path("src/shell.html"),
            });
            b.getInstallStep().dependOn(&link_step.step);
            const step_run = emRunStep(b, .{ .name = "demo", .emsdk = sokol.dep_emsdk });
            step_run.step.dependOn(&link_step.step);
            break :blk .{ compile_demo, step_run };
        } else {
            const compile_demo = b.addExecutable(.{
                .name = "zrectpack_demo",
                .root_module = mod_demo,
            });

            const step_run = b.addRunArtifact(compile_demo);
            step_run.step.dependOn(b.getInstallStep());
            break :blk .{ compile_demo, step_run };
        }
    };

    if (b.args) |args| step_run.addArgs(args);
    b.step("run", "Run the app").dependOn(&step_run.step);
    compile_demo.step.dependOn(shdc_step);
    return .{ .mod = mod_demo };
}

const SokolConfig = struct {
    dep: *Dependency,
    mod: *Module,
    dep_emsdk: *Dependency,
    emsdk_include_path: LazyPath,
    dep_cimgui: *Dependency,
    mod_cimgui: *Module,
};

fn configureSokol(b: *Build, target: ResolvedTarget, optimize: OptimizeMode) SokolConfig {
    const dep = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .with_sokol_imgui = true,
    });

    const dep_cimgui = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    });

    const dep_emsdk = dep.builder.dependency("emsdk", .{});
    const emsdk_include_path = dep_emsdk.path("upstream/emscripten/cache/sysroot/include");

    if (target.result.cpu.arch.isWasm()) {
        dep_cimgui.artifact("cimgui_clib").addSystemIncludePath(emsdk_include_path);
        dep_cimgui.artifact("cimgui_clib").step.dependOn(&dep.artifact("sokol_clib").step);
    }

    dep.artifact("sokol_clib").addIncludePath(dep_cimgui.path("src"));

    return .{
        .dep = dep,
        .mod = dep.module("sokol"),
        .dep_emsdk = dep.builder.dependency("emsdk", .{}),
        .emsdk_include_path = emsdk_include_path,
        .dep_cimgui = dep_cimgui,
        .mod_cimgui = dep_cimgui.module("cimgui"),
    };
}

const StbRectPackConfig = struct { dep: *Dependency, lib: *Step.Compile, mod: *Module };
fn configureStbRectPack(b: *Build, sokol_config: SokolConfig, target: ResolvedTarget, optimize: OptimizeMode) StbRectPackConfig {
    const dep = b.dependency("stb", .{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addStaticLibrary(.{
        .name = "stbrp",
        .target = target,
        .optimize = optimize,
    });

    lib.addIncludePath(dep.path(""));

    const flags: []const []const u8 = if (optimize == .Debug) &.{
        "-std=c99",
        "-fno-sanitize=undefined",
        "-g",
        "-O0",
    } else &.{
        "-std=c99",
        "-fno-sanitize=undefined",
    };

    lib.addCSourceFile(.{
        .file = b.path("src/stb_rect_pack_impl.c"),
        .flags = flags,
    });

    if (target.result.cpu.arch.isWasm()) {
        lib.addSystemIncludePath(sokol_config.emsdk_include_path);
    } else {
        lib.linkLibC();
    }

    const bindings = b.addTranslateC(.{
        .optimize = optimize,
        .target = target,
        .root_source_file = dep.path("stb_rect_pack.h"),
    });

    return .{
        .dep = dep,
        .lib = lib,
        .mod = bindings.createModule(),
    };
}

const ZbenchConfig = struct { mod: *Module };
fn configureZbench(b: *Build, target: ResolvedTarget, optimize: OptimizeMode) ZbenchConfig {
    const dep = b.dependency("zbench", .{
        .target = target,
        .optimize = optimize,
    });

    return .{ .mod = dep.module("zbench") };
}

fn configureBenchmark(
    b: *Build,
    zrectpack: ZRectpackConfig,
    stbrp: StbRectPackConfig,
    zbench: ZbenchConfig,
    target: ResolvedTarget,
    optimize: OptimizeMode,
) struct { mod: *Module } {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zrectpack", .module = zrectpack.mod },
            .{ .name = "stbrp", .module = stbrp.mod },
            .{ .name = "zbench", .module = zbench.mod },
        },
    });
    mod.linkLibrary(stbrp.lib);

    const exe = b.addExecutable(.{
        .name = "zrectpack_benchmark",
        .root_module = mod,
    });
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run.addArgs(args);
    }

    b.step("benchmark", "Run the benchmark").dependOn(&run.step);
    return .{ .mod = mod };
}

const std = @import("std");
const shdc = @import("sokolshdc");
const Build = std.Build;
const Module = Build.Module;
const Step = Build.Step;
const Dependency = Build.Dependency;
const ResolvedTarget = Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const LazyPath = Build.LazyPath;
