//! The README "small program" of CUI, wrapped for Zig.
//!
//! Run: zig build run-hello

const zui = @import("zui");

pub fn main() !void {
    var app = try zui.App.create(.{ .title = "Hello", .width = 420, .height = 300 });
    defer app.destroy();

    var notifications = true;
    var clicks: u32 = 0;

    while (app.frame()) {
        const ui = app.ui();

        ui.column(.{ .pad = 32, .gap = 16 });
        defer ui.end();

        ui.heading("Hello, CUI", 2);
        ui.secondary("A native window, a few components and no dependencies. Wrapped for Zig.");
        _ = ui.switch_("Notifications", &notifications, .{});

        ui.row(.{ .gap = 8 });
        defer ui.end();

        if (ui.button("Click me", .{ .variant = .primary, .icon = zui.icon.plus }))
            clicks += 1;
        ui.textf("Clicked {} times", .{clicks});
    }
}
