# zrectpack (fork)

A stb_rect_pack-inspired, dependency-free rect packing library written in zig.

## Fork notice:

Hey, this project ain't mine! I just decided to fork it because I needed a quick and dirty rectangle
packing algorithm and the upstream repo didn't work for me, so please, go take a look at the 
[original repo](https://github.com/bgourlie/zrectpack), all rights to 
[W. Brian Gurlie](https://github.com/bgourlie) 

## Why?

I wanted a simple rect-packing utility in the spirit of stb_rect_pack but using zig idioms/features.
Incidentally, the zig implementation appears to be nearly 2x faster than stb_rect_pack (according to
rudimentary benchmarks, so take with an appropriate grain of salt) with some low-hanging performance
optimizations yet to be made.

## Why not?

This library only implements the bottom-left placement heuristic, while stb_rect_pack implements
both bottom-left and best-fit heuristics. Foregoing the best-fit heuristic was done because it
introduces additional complexity and runtime cost compared to the bottom-left heuristic, while
generally appearing to pack less efficiently. I suspect there's a class of inputs for which
best-fit is better suited, but until its utility is better understood, I don't plan on implementing
it.

All this is to say: If for some reason you need the best-fit heuristic, stb_rect_pack is the more
suitable choice.

## Getting Started

Install zrectpack:

```bash
zig fetch --save git+https://github.com/bgourlie/zrectpack.git
```

Add the dependency to your your `build.zig` and expose it to your module:

```zig
    const dep_zrectpack = b.dependency("zrectpack", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            ...,
            .{ .name = "zrectpack", .module = dep_zrectpack.module("zrectpack") },
        },
    });
```


## Example Use

```zig
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
```

## Contributions

Contributions are welcome! Some potential areas of improvement:

- Performance
- A more robust set of benchmarks
- Additional sorting options (both zrectpack and stb_rect_pack currently only support processing
  rects sorted tallest to shortest)
- Test cases assessing best-fit packing efficiency to better understand when it's actually useful
- Demo UI and options
