pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zrectpack = configureZrectpack(b, target, optimize);
    configureUnitTests(b, &.{zrectpack.mod});
}

fn configureUnitTests(b: *Build, test_modules: []const *Module) void {
    const test_step = b.step("test", "Run unit tests");
    for (test_modules) |test_module| {
        const test_ = b.addTest(.{ .root_module = test_module });
        test_step.dependOn(&b.addRunArtifact(test_).step);
    }
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

const std = @import("std");
const shdc = @import("sokolshdc");
const Build = std.Build;
const Module = Build.Module;
const Step = Build.Step;
const Dependency = Build.Dependency;
const ResolvedTarget = Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const LazyPath = Build.LazyPath;
