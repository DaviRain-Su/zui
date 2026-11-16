//! Headless smoke tests: drive a cui_ctx with the software renderer, build a
//! real frame of components, and rasterize it. No window is opened.

const std = @import("std");
const zui = @import("zui.zig");

fn countLit(pixels: []const u8) usize {
    var lit: usize = 0;
    for (pixels) |b| {
        if (b != 0) lit += 1;
    }
    return lit;
}

test "headless frame builds, formats text and rasterizes" {
    var ui = try zui.Ui.createHeadless(320, 200, 1.0);
    defer ui.destroy();

    var on = true;
    var clicks: u32 = 7;

    ui.beginFrame(1.0 / 60.0);
    {
        ui.column(.{ .pad = 16, .gap = 8, .width = .fill, .height = .fill });
        defer ui.end();

        ui.heading("Hello from Zig", 2);
        ui.secondary("Immediate mode, no dependencies.");
        _ = ui.switch_("Notifications", &on, .{});

        {
            ui.row(.{ .gap = 8 });
            defer ui.end();
            if (ui.button("Click me", .{ .variant = .primary, .icon = zui.icon.plus }))
                clicks += 1;
            ui.spacer();
            ui.textf("Clicked {} times", .{clicks});
        }

        {
            ui.scroll(.{ .id = "list", .height = .fill });
            defer ui.end();
            var i: i32 = 0;
            while (i < 5) : (i += 1) {
                ui.pushIdInt(i);
                defer ui.end();
                _ = ui.checkbox("task", &on, .{});
            }
        }
    }
    ui.endFrame();

    const dd = ui.drawData();
    try std.testing.expect(dd.vertex_count > 0);

    const px = try std.testing.allocator.alloc(u8, 320 * 200 * 4);
    defer std.testing.allocator.free(px);
    @memset(px, 0);
    try ui.render(px);
    try std.testing.expect(countLit(px) > 1000);
}

test "text field binds the caller's buffer and reports flags" {
    var ui = try zui.Ui.createHeadless(200, 100, 1.0);
    defer ui.destroy();

    var buf: [64]u8 = @splat(0);
    ui.beginFrame(1.0 / 60.0);
    {
        ui.column(.{ .pad = 8 });
        defer ui.end();
        const flags = ui.input("field", &buf, .{ .placeholder = "type here", .width = .fill });
        try std.testing.expect(!flags.changed());
        try std.testing.expect(!flags.submitted());
        try std.testing.expectEqualStrings("", std.mem.sliceTo(&buf, 0));
    }
    ui.endFrame();
}

test "tmp strings live for the frame and are NUL-terminated" {
    var ui = try zui.Ui.createHeadless(120, 80, 1.0);
    defer ui.destroy();
    ui.beginFrame(1.0 / 60.0);
    const s = ui.tmpFmt("{}-{}", .{ @as(u8, 42), true });
    try std.testing.expectEqualStrings("42-true", s);
    ui.endFrame();
}

test "unbalanced scopes are caught" {
    var ui = try zui.Ui.createHeadless(120, 80, 1.0);
    defer ui.destroy();
    ui.column(.{});
    try std.testing.expect(ui.scoped());
    ui.end();
    try std.testing.expect(!ui.scoped());
}
