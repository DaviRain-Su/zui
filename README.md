# zui

**CUI for Zig** — idiomatic Zig bindings for [CUI](https://github.com/yappologistic/CUI), an immediate-mode UI library written in C99 with ~210 components, no dependencies, and its own software renderer.

The C library is vendored under `vendor/cui` (v1.4.0, commit `a5c9ef5`) and compiled by `build.zig`; `src/zui.zig` wraps its API with Zig ergonomics. The result is a plain Zig dependency — `zig build` needs nothing else.

```zig
const zui = @import("zui");

pub fn main() !void {
    var app = try zui.App.create(.{ .title = "Hello", .width = 420, .height = 300 });
    defer app.destroy();

    var on = true;
    while (app.frame()) {
        const ui = app.ui();
        ui.column(.{ .pad = 32, .gap = 16 });
        defer ui.end();
        ui.heading("Hello", 2);
        _ = ui.switch_("On", &on, .{});
        if (ui.button("Click", .{ .variant = .primary })) {}
    }
}
```

## Try it

```sh
zig build run-hello   # README example: heading, switch, button
zig build run-todo    # the tutorial to-do app (persists to todo.txt)
zig build test        # headless smoke tests (software renderer, no window)
zig build run-screenshot  # renders the hello UI headless -> screenshot.png
```

`screenshot.png` is produced without opening a window (software renderer +
`cui_write_png`) — handy for CI.

## How the C API maps to Zig

| CUI (C) | zui (Zig) |
|---|---|
| `cui_app_run(&desc, frame, user)` | `zui.App.run(desc, frameFn, user)` or `App.create` + `while (app.frame())` |
| `cui_column(ui, .pad = 32) { ... }` | `ui.column(.{ .pad = 32 }); defer ui.end();` |
| `cui_push_id(ui, "x")` / `cui_pop_id` | `ui.pushId("x"); defer ui.end();` (same stack) |
| `CUI__OPTS(cui_button_opts, .variant = ...)` | `ui.button("Save", .{ .variant = .primary })` |
| `cui_textf(ui, "%d", n)` | `ui.textf("{} clicks", .{n})` (std.fmt) |
| `CUI_FILL`, `CUI_PX(40)` | `.width = .fill`, `.width = .{ .px = 40 }` |
| `CUI_BUTTON_PRIMARY` | `.variant = .primary` |
| `CUI_ICON_PLUS` | `zui.icon.plus` (UTF-8 string; the full Lucide set is in `vendor/cui/include/cui/cui_icons.h`) |
| `char buf[96]` text fields | `ui.input("id", &buf, .{})` — edits your `[]u8` in place |
| `cui_get_draw_data`, `cui_sw_render` | headless: `Ui.createHeadless`, `ui.beginFrame/endFrame/drawData/render` |
| everything else | `zui.raw.cui_anything(ui.h, ...)` — the full translated C API |

### The one rule: `defer ui.end()`

CUI's C macros open a component and close it at the end of the `{ ... }` block. Zig has no block macros, so every container opens by pushing its matching end function (`cui_box_end`, `cui_card_end`, `cui_scroll_end`, `cui_split_end`, `cui_pop_id`, `cui_pop_disabled`) onto an internal stack, and `ui.end()` pops and calls it:

```zig
ui.card(.{ .pad = 16 });
defer ui.end();
ui.text("inside the card");
{
    ui.pushId("row");
    defer ui.end();
    _ = ui.button("nested", .{});
}
```

Scopes must not cross frames: `App.frame` and `Ui.beginFrame` panic if a frame ended with scopes open (in C this would corrupt the layout silently). The stack is LIFO, so ordinary `defer` ordering is always correct.

### Strings

Every `[]const u8` you pass is copied into a per-frame arena (`ui.tmpStr` / `ui.tmpFmt`) and from there CUI copies what it keeps — so temporaries and formatted strings are safe, and there is nothing to free. The one exception is text field buffers, which stay yours: CUI edits them in place.

### Headless testing

```zig
var ui = try zui.Ui.createHeadless(320, 200, 1.0);
defer ui.destroy();
ui.beginFrame(1.0 / 60.0);
ui.column(.{ .pad = 16 });
defer ui.end();
ui.heading("Hi", 2);
ui.endFrame();
try ui.render(pixels); // RGBA, software rasterizer
```

Headless contexts can also be driven with input — feed events between frames,
the way the app layer does: `ui.mouseMove(x, y)` / `ui.mouseButton(.left, true)`
/ `ui.typeText("hi")`, with `ui.lastRect()` to locate a component after layout.
`src/smoke_test.zig` includes a test that clicks a button this way.

## Layout

```
build.zig            translates src/c_bindings.h into Zig bindings, compiles
                     vendored CUI (C99), links the window backend (Cocoa/
                     QuartzCore/OpenGL on macOS, win32, X11), builds examples
tools/gen.py         generates the typed component surface from the vendored
                     header into the marked regions of src/zui.zig
src/zui.zig          the wrapper: hand-written core (Ui, App, options, enums,
                     icons) + generated components between GEN markers
src/c_bindings.h    header aggregation translated at build time
                     (Zig 0.17 removed @cImport)
src/smoke_test.zig   headless tests (rendering, clicks, generated components)
examples/            hello, todo (ports of CUI's README and tutorial programs),
                     screenshot (headless PNG)
vendor/cui/          upstream CUI (include/, src/, third_party/, LICENSE)
```

## Updating the vendored CUI

```sh
git clone https://github.com/yappologistic/CUI.git
cd CUI && git checkout <commit>
rm -rf vendor/cui && cp -R include src third_party LICENSE ../zui/vendor/cui/
echo '<commit>' > ../zui/vendor/cui/VENDOR.txt
```

## Status

The wrapper covers the whole `cui_ctx` component surface. The hand-written
core (layout, text, buttons, inputs, app lifecycle, headless rendering) has
curated Zig-native types; everything else is **generated** by `tools/gen.py`
from the vendored header (~356 methods, opts structs with defaults, enums,
begin/end pairs as scopes, `const char *const *` as `[]const []const u8`,
pointer+count pairs folded into slices). Regenerate after updating the
vendored CUI:

```sh
python3 tools/gen.py && zig build test
```

Only what cannot be typed from Zig stays behind `zui.raw.*`: the callback
APIs (`cui_canvas` paint, `cui_state_on_free`, `cui_tree_sort`), the variadic
`cui_textf` family (use `ui.textf`), the renderer interfaces, and app-layer
extras that duplicate what `App` already wraps.

## License

MIT, like CUI. CUI itself is MIT — see `vendor/cui/LICENSE` (Lucide icons are ISC, stb headers are public domain / MIT; see `third_party/`).
