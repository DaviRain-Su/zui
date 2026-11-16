//! Renders the hello UI headless (no window) and writes screenshot.png.
//! Useful for CI: `zig build run-screenshot` then inspect the PNG.

const std = @import("std");
const zui = @import("zui");

pub fn main(init: std.process.Init) !void {
    var ui = try zui.Ui.createHeadless(420, 300, 2.0);
    defer ui.destroy();

    var notifications = true;
    const clicks: u32 = 3;

    ui.beginFrame(1.0 / 60.0);
    {
        ui.column(.{ .pad = 32, .gap = 16, .width = .fill, .height = .fill });
        defer ui.end();

        ui.heading("Hello, CUI", 2);
        ui.secondary("A native window, a few components and no dependencies.");
        _ = ui.switch_("Notifications", &notifications, .{});

        {
            ui.row(.{ .gap = 8 });
            defer ui.end();
            _ = ui.button("Click me", .{ .variant = .primary, .icon = zui.icon.plus });
            ui.textf("Clicked {} times", .{clicks});
        }
    }
    ui.endFrame();

    const dd = ui.drawData();
    const w: usize = @intCast(dd.width_px);
    const h: usize = @intCast(dd.height_px);
    const px = try init.gpa.alloc(u8, w * h * 4);
    defer init.gpa.free(px);
    @memset(px, 0);
    try ui.render(px);

    if (!zui.raw.cui_write_png("screenshot.png", px.ptr, @intCast(w), @intCast(h), @intCast(w * 4)))
        return error.WritePngFailed;
    std.debug.print("wrote screenshot.png ({}x{} @2x, {} vertices)\n", .{ w / 2, h / 2, dd.vertex_count });
}
