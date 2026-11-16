const std = @import("std");

// The vendored CUI library's source list comes from vendor/cui/SOURCES.txt,
// which tools/sync_cui.sh regenerates on every sync - so upstream adding or
// removing files never breaks the build. (Read with @embedFile: build.zig
// cannot touch the filesystem at configuration time.)
// Optional components are excluded at sync time: cui_bidi.c/cui_shape.c only
// build with -DCUI_TEXT_SHAPING (off, matching upstream's CMake default).
const cui_sources = blk: {
    const manifest = @embedFile("vendor/cui/SOURCES.txt");
    @setEvalBranchQuota(20000);
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, manifest, "\n");
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        count += 1;
    }
    var out: [count][]const u8 = undefined;
    var i: usize = 0;
    var it2 = std.mem.tokenizeAny(u8, manifest, "\n");
    while (it2.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        out[i] = line;
        i += 1;
    }
    break :blk out;
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const c_flags: []const []const u8 = if (optimize == .debug)
        &.{ "-std=c99" }
    else
        &.{ "-std=c99", "-O2", "-DNDEBUG" };

    const zui_mod = b.createModule(.{
        .root_source_file = b.path("src/zui.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Zig 0.17 removed @cImport: translate the CUI headers into a module and
    // import it from zui.zig as `@import("c")`.
    const cui_bindings = b.addTranslateC(.{
        .root_source_file = b.path("src/c_bindings.h"),
        .target = target,
        .optimize = optimize,
    });
    cui_bindings.addIncludePath(b.path("vendor/cui/include"));
    zui_mod.addImport("c", cui_bindings.createModule());
    zui_mod.addIncludePath(b.path("vendor/cui/include"));
    zui_mod.addCSourceFiles(.{
        .root = b.path("vendor/cui"),
        .files = &cui_sources,
        .flags = c_flags,
    });

    switch (target.result.os.tag) {
        .macos => {
            zui_mod.addCMacro("GL_SILENCE_DEPRECATION", "1");
            zui_mod.addCSourceFile(.{
                .file = b.path("vendor/cui/src/platform/cui_app_cocoa.m"),
                .flags = &.{ "-fobjc-arc", "-std=c99" },
            });
            zui_mod.linkFramework("Cocoa", .{});
            zui_mod.linkFramework("QuartzCore", .{});
            zui_mod.linkFramework("OpenGL", .{});
        },
        .windows => {
            zui_mod.addCSourceFile(.{
                .file = b.path("vendor/cui/src/platform/cui_app_win32.c"),
                .flags = c_flags,
            });
            inline for (.{ "user32", "gdi32", "opengl32", "shell32", "imm32", "dwmapi", "comdlg32", "ole32" }) |lib|
                zui_mod.linkSystemLibrary(lib, .{});
        },
        else => {
            zui_mod.addCSourceFile(.{
                .file = b.path("vendor/cui/src/platform/cui_app_x11.c"),
                .flags = c_flags,
            });
            inline for (.{ "X11", "GL" }) |lib|
                zui_mod.linkSystemLibrary(lib, .{});
        },
    }

    // Examples -------------------------------------------------------------
    const Example = struct { name: []const u8, path: []const u8 };
    const examples = [_]Example{
        .{ .name = "hello", .path = "examples/hello.zig" },
        .{ .name = "todo", .path = "examples/todo.zig" },
        .{ .name = "screenshot", .path = "examples/screenshot.zig" },
    };
    for (examples) |ex| {
        const mod = b.createModule(.{
            .root_source_file = b.path(ex.path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mod.addImport("zui", zui_mod);
        const exe = b.addExecutable(.{ .name = ex.name, .root_module = mod });
        b.installArtifact(exe);

        const step_name = std.fmt.allocPrint(b.allocator, "run-{s}", .{ex.name}) catch unreachable;
        const desc = std.fmt.allocPrint(b.allocator, "Run the {s} example", .{ex.name}) catch unreachable;
        const run_step = b.addRunArtifact(exe);
        b.step(step_name, desc).dependOn(&run_step.step);
    }

    // Tests (headless: software renderer, no window) ------------------------
    const tests = b.addTest(.{ .root_module = zui_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run headless smoke tests");
    test_step.dependOn(&run_tests.step);
}
