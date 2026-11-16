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

test "simulated mouse click presses a button" {
    var ui = try zui.Ui.createHeadless(320, 200, 1.0);
    defer ui.destroy();

    // CUI's own tests simulate clicks the same way: feed each event between
    // frames, hover first, then press for a frame, then release.
    var clicked = false;

    // frame: lay the button out and remember where it landed
    ui.beginFrame(1.0 / 60.0);
    {
        ui.column(.{ .pad = 16 });
        defer ui.end();
        _ = ui.button("Press", .{ .width = .{ .px = 120 } });
    }
    ui.endFrame();
    const r = ui.lastRect();
    try std.testing.expect(r.w > 0 and r.h > 0);
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;

    // hover for a frame
    ui.mouseMove(cx, cy);
    ui.beginFrame(1.0 / 60.0);
    {
        ui.column(.{ .pad = 16 });
        defer ui.end();
        _ = ui.button("Press", .{ .width = .{ .px = 120 } });
    }
    ui.endFrame();

    // press for a frame
    ui.mouseButton(.left, true);
    ui.beginFrame(1.0 / 60.0);
    {
        ui.column(.{ .pad = 16 });
        defer ui.end();
        _ = ui.button("Press", .{ .width = .{ .px = 120 } });
    }
    ui.endFrame();

    // release, then a settle frame
    ui.mouseButton(.left, false);
    ui.beginFrame(1.0 / 60.0);
    {
        ui.column(.{ .pad = 16 });
        defer ui.end();
        if (ui.button("Press", .{ .width = .{ .px = 120 } })) clicked = true;
    }
    ui.endFrame();
    ui.beginFrame(1.0 / 60.0);
    {
        ui.column(.{ .pad = 16 });
        defer ui.end();
        _ = ui.button("Press", .{ .width = .{ .px = 120 } });
    }
    ui.endFrame();

    try std.testing.expect(clicked);
}

test "tmp strings live for the frame and are NUL-terminated" {
    var ui = try zui.Ui.createHeadless(120, 80, 1.0);
    defer ui.destroy();
    ui.beginFrame(1.0 / 60.0);
    const s = ui.tmpFmt("{}-{}", .{ @as(u8, 42), true });
    try std.testing.expectEqualStrings("42-true", s);
    ui.endFrame();
}

test "generated components: charts, tables, string arrays, results" {
    var ui = try zui.Ui.createHeadless(420, 320, 1.0);
    defer ui.destroy();

    var seg: i32 = 1;
    const pct: f32 = 0.42;

    ui.beginFrame(1.0 / 60.0);
    {
        ui.column(.{ .pad = 16, .gap = 8, .width = .fill, .height = .fill });
        defer ui.end();

        _ = ui.badge("v1.4.0", .{}); // opts struct with strings
        ui.progress_bar(pct, .{}); // renamed method, float by value

        // struct array with a folded pointer+count field (series values)
        const series = [_]zui.Series{
            .{ .name = "a", .values = &.{ 1.0, 2.0, 3.0, 2.5 } },
            .{ .name = "b", .values = &.{ 0.5, 1.5, 1.0, 2.0 } },
        };
        ui.line_chart("chart", &series, .{});

        // string array + int out-param
        _ = ui.segmented("seg", &.{ "A", "B", "C" }, &seg, .{});
        try std.testing.expect(seg == 1);

        // SCOPE_IF container: body runs only when the table opened
        const cols = [_]zui.TableColumn{
            .{ .title = "Name", .width = .fill },
            .{ .title = "Size" },
        };
        if (ui.table("t", &cols, .{})) {
            defer ui.end();
            _ = ui.table_row(false);
            _ = ui.table_row(false);
        }

        // query helpers
        try std.testing.expect(ui.lastId() != 0);
    }
    ui.endFrame();

    const dd = ui.drawData();
    try std.testing.expect(dd.vertex_count > 100);
}
test "unbalanced scopes are caught" {
    var ui = try zui.Ui.createHeadless(120, 80, 1.0);
    defer ui.destroy();
    ui.column(.{});
    try std.testing.expect(ui.scoped());
    ui.end();
    try std.testing.expect(!ui.scoped());
}

// Forces semantic analysis of every generated method and free function, so
// type errors anywhere in the generated surface fail the build.
fn refFns(comptime T: type) void {
    const info = @typeInfo(T).@"struct";
    inline for (info.decl_names) |d| {
        const D = @TypeOf(@field(T, d));
        if (@typeInfo(D) == .@"fn") {
            _ = &@field(T, d);
        }
    }
}

test "every declared function analyzes" {
    refFns(zui);
    refFns(zui.Ui);
    refFns(zui.App);
}

test "canvas callback paints and reports interaction rect" {
    var ui = try zui.Ui.createHeadless(200, 120, 1.0);
    defer ui.destroy();

    ui.beginFrame(1.0 / 60.0);
    {
        ui.column(.{ .pad = 8 });
        defer ui.end();
        _ = ui.canvas("cv", .{ .px = 100 }, .{ .px = 50 }, {}, struct {
            fn paint(u: *zui.Ui, r: zui.Rect, _: void) void {
                u.draw_rect(r, .{ .tl = 4, .tr = 4, .br = 4, .bl = 4 }, zui.Color.rgb(0xFF0000));
            }
        }.paint);
    }
    ui.endFrame();

    const px = try std.testing.allocator.alloc(u8, 200 * 120 * 4);
    defer std.testing.allocator.free(px);
    @memset(px, 0);
    try ui.render(px);
    var reds: usize = 0;
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        if (px[i] > 200 and px[i + 1] == 0 and px[i + 2] == 0) reds += 1;
    }
    try std.testing.expect(reds > 100);
}

test "color picker edits the caller's color" {
    var ui = try zui.Ui.createHeadless(300, 200, 1.0);
    defer ui.destroy();

    var col = zui.Color.rgb(0x3366CC);
    ui.beginFrame(1.0 / 60.0);
    {
        ui.column(.{ .pad = 12 });
        defer ui.end();
        _ = ui.color_picker("pick", &col);
    }
    ui.endFrame();
    try std.testing.expectEqual(@as(u8, 0x33), col.r);
}

test "free utility functions" {
    // color math
    const mixed = zui.mix(zui.Color.rgb(0x000000), zui.Color.rgb(0xFFFFFF), 0.5);
    try std.testing.expect(mixed.r > 40 and mixed.r < 220); // OKLab midpoint is not sRGB 128
    // date round trip
    const today = zui.date_today();
    const days = zui.date_to_days(today);
    try std.testing.expectEqual(today, zui.date_from_days(days));
    // name lookups
    try std.testing.expectEqualStrings("Not Found", zui.http_reason(404));
    var next_out: i64 = 0;
    try std.testing.expect(zui.cron_next("* * * * *", 0, 0, &next_out));
    try std.testing.expect(next_out > 0);
}
