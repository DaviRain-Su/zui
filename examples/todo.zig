//! A to-do app: add, tick off, filter and clear tasks, and save to a file.
//! Ported from CUI's docs/tutorial.md (~130 lines of C).
//!
//! Run: zig build run-todo

const std = @import("std");
const zui = @import("zui");

const max_tasks = 200;
const title_len = 96;

const Task = struct {
    title: [title_len]u8 = @splat(0),
    done: bool = false,

    fn text(self: *const Task) []const u8 {
        return std.mem.sliceTo(&self.title, 0);
    }
};

const AppState = struct {
    tasks: [max_tasks]Task = @splat(.{}),
    count: usize = 0,
    draft: [title_len]u8 = @splat(0),
    filter: i32 = 0, // 0 all, 1 open, 2 done
    confirm_clear: bool = false,

    fn addTask(self: *AppState) bool {
        const d = std.mem.sliceTo(&self.draft, 0);
        if (d.len == 0 or self.count >= max_tasks) return false;
        const t = &self.tasks[self.count];
        @memcpy(t.title[0..d.len], d);
        t.done = false;
        self.count += 1;
        @memset(&self.draft, 0);
        return true;
    }

    fn openDone(self: *const AppState) struct { open: usize, done: usize } {
        var open: usize = 0;
        for (self.tasks[0..self.count]) |t| {
            if (!t.done) open += 1;
        }
        return .{ .open = open, .done = self.count - open };
    }

    fn save(self: *const AppState, io: std.Io) void {
        var buf: [max_tasks * (title_len + 4)]u8 = undefined;
        var n: usize = 0;
        for (self.tasks[0..self.count]) |t| {
            const line = std.fmt.bufPrint(buf[n..], "{s} {s}\n", .{ if (t.done) "[x]" else "[ ]", t.text() }) catch break;
            n += line.len;
        }
        var dir = std.Io.Dir.cwd();
        const f = dir.createFile(io, "todo.txt", .{}) catch return;
        defer f.close(io);
        f.writePositionalAll(io, buf[0..n], 0) catch {};
    }

    fn load(self: *AppState, io: std.Io) void {
        var dir = std.Io.Dir.cwd();
        const f = dir.openFile(io, "todo.txt", .{}) catch return;
        defer f.close(io);
        var data: [1 << 16]u8 = undefined;
        const n = f.readPositionalAll(io, &data, 0) catch return;
        var it = std.mem.splitScalar(u8, data[0..n], '\n');
        while (it.next()) |line| {
            if (line.len < 4 or self.count >= max_tasks) continue;
            const done = std.mem.startsWith(u8, line, "[x]");
            const body = std.mem.trim(u8, line[4..], " \t");
            if (body.len == 0 or body.len >= title_len) continue;
            const t = &self.tasks[self.count];
            @memcpy(t.title[0..body.len], body);
            t.done = done;
            self.count += 1;
        }
    }
};

fn frame(ui: *zui.Ui, a: *AppState) void {
    ui.column(.{ .pad = 24, .gap = 16, .width = .fill, .height = .fill });
    defer ui.end();

    // header --------------------------------------------------------------
    {
        ui.row(.{ .gap = 12, .@"align" = .end });
        defer ui.end();
        ui.heading("To do", 2);
        ui.spacer();
        const od = a.openDone();
        ui.textf("{} open, {} done", .{ od.open, od.done });
    }

    // add a task ----------------------------------------------------------
    {
        ui.row(.{ .gap = 8 });
        defer ui.end();
        const typed = ui.input("new-task", &a.draft, .{ .placeholder = "Add a task", .width = .fill });
        const add = ui.button("Add", .{
            .variant = .primary,
            .icon = zui.icon.plus,
            .disabled = a.draft[0] == 0,
        });
        if (typed.submitted() or add) {
            if (a.addTask()) a.confirm_clear = false;
        }
    }

    // filter row -----------------------------------------------------------
    {
        ui.row(.{ .gap = 4 });
        defer ui.end();
        ui.muted("Show:");
        _ = ui.radio("All", &a.filter, 0, .{});
        _ = ui.radio("Open", &a.filter, 1, .{});
        _ = ui.radio("Done", &a.filter, 2, .{});
        ui.spacer();
        if (a.count > 0) {
            const label = if (a.confirm_clear) "Really clear?" else "Clear";
            if (ui.button(label, .{
                .variant = if (a.confirm_clear) .danger else .default,
                .icon = zui.icon.trash,
            })) {
                if (a.confirm_clear) {
                    var w: usize = 0;
                    for (a.tasks[0..a.count]) |t| {
                        if (!t.done) {
                            a.tasks[w] = t;
                            w += 1;
                        }
                    }
                    a.count = w;
                    a.confirm_clear = false;
                } else {
                    a.confirm_clear = true;
                }
            }
        } else {
            a.confirm_clear = false;
        }
    }

    // the list -------------------------------------------------------------
    {
        ui.scroll(.{ .id = "tasks", .width = .fill, .height = .fill, .gap = 2 });
        defer ui.end();

        var remove: ?usize = null;
        for (a.tasks[0..a.count], 0..) |*t, i| {
            const visible = switch (a.filter) {
                1 => !t.done,
                2 => t.done,
                else => true,
            };
            if (!visible) continue;

            ui.pushIdInt(@intCast(i));
            defer ui.end();
            {
                ui.row(.{ .gap = 8, .@"align" = .center, .width = .fill });
                defer ui.end();
                _ = ui.checkbox(t.text(), &t.done, .{});
                ui.spacer();
                if (ui.iconButton(zui.icon.x, .{ .tooltip = "Delete", .variant = .ghost, .size = .sm }))
                    remove = i;
            }
        }

        if (remove) |i| {
            std.mem.copyForwards(Task, a.tasks[i .. a.count - 1], a.tasks[i + 1 .. a.count]);
            a.count -= 1;
            a.confirm_clear = false;
        }
    }
}

pub fn main(init: std.process.Init) !u8 {
    var state = AppState{};
    state.load(init.io);
    defer state.save(init.io);

    const code = zui.App.run(.{ .title = "To do", .width = 520, .height = 640 }, frame, &state);
    return @intCast(code);
}
