//! zui — idiomatic Zig bindings for [CUI](https://github.com/yappologistic/CUI),
//! an immediate-mode UI library written in C99 (~210 components, no dependencies).
//!
//! The C library is vendored under `vendor/cui` and compiled by `build.zig`.
//! This module wraps the C API with Zig-native ergonomics:
//!
//!  * options are plain Zig structs with defaults (C: designated initializers),
//!  * strings are `[]const u8` and formatting is `std.fmt` (C: printf + NUL care),
//!  * one uniform rule for containers: opening one pushes its matching end
//!    function onto an internal stack; close it with `defer ui.end()`,
//!  * a per-frame string arena: any string you pass to zui only needs to live
//!    for the call (CUI copies text into its own frame arena immediately).
//!
//! Components the wrapper does not mirror are one `zui.raw.` prefix away —
//! `raw` is the full translated C API (`@cImport` of cui.h / cui_app.h /
//! cui_render.h).
//!
//! A frame, loop style (the C `while (cui_app_frame(app))` idiom):
//!
//! ```zig
//! var app = try zui.App.create(.{ .title = "Hello", .width = 420, .height = 300 });
//! defer app.destroy();
//! var on = true;
//! while (app.frame()) {
//!     const ui = app.ui();
//!     ui.column(.{ .pad = 32, .gap = 16 });
//!     defer ui.end();                       // closes the column
//!     ui.heading("Hello", 2);
//!     _ = ui.switch_("On", &on, .{});
//!     _ = ui.button("Click", .{ .variant = .primary });
//! }
//! ```
//!
//! Callback style (C `cui_app_run`): see `App.run`.
//! Headless (no window — tests, screenshots): see `Ui.createHeadless`.

const std = @import("std");

/// The full translated C API (translated from src/c_bindings.h by the build
/// script — Zig 0.17 removed @cImport). Anything this module does not wrap
/// can be called directly, e.g. `zui.raw.cui_slider_ex(ui.h, ...)`. The
/// handle a wrapper object carries (`.h`) is the `cui_ctx *` the C functions
/// want.
pub const raw = @import("c");

pub const c = raw; // shorter alias

// --------------------------------------------------------------------------
// Value types
// --------------------------------------------------------------------------

/// C `cui_size`: how a component sizes itself along one axis.
/// `.fit` is the C zero value.
pub const Size = union(enum) {
    fit,
    fill,
    grow: f32,
    px: f32,
    /// 0..100 of the parent
    pct: f32,

    pub fn toC(self: Size) c.cui_size {
        var v: c.cui_size = std.mem.zeroes(c.cui_size);
        switch (self) {
            .fit => {}, // CUI_SIZE_FIT = 0, value 0
            .fill => setSizeKind(&v, .grow, 1),
            .grow => |w| setSizeKind(&v, .grow, w),
            .px => |w| setSizeKind(&v, .fixed, w),
            .pct => |p| setSizeKind(&v, .percent, p),
        }
        return v;
    }
};

const SizeKind = enum(c_int) { fit = 0, grow, fixed, percent };

fn setSizeKind(v: *c.cui_size, kind: SizeKind, value: f32) void {
    v.kind = enumOrInt(@TypeOf(v.kind), kind);
    v.value = value;
}

/// C `cui_color` { r, g, b, a }.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn rgb(hex: u32) Color {
        return .{
            .r = @truncate(hex >> 16),
            .g = @truncate(hex >> 8),
            .b = @truncate(hex),
        };
    }

    pub fn rgba(hex: u32) Color {
        return .{
            .r = @truncate(hex >> 24),
            .g = @truncate(hex >> 16),
            .b = @truncate(hex >> 8),
            .a = @truncate(hex),
        };
    }

    fn toC(self: Color) c.cui_color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a };
    }
};

/// Container direction (C `cui_dir`).
pub const Dir = enum(c_int) { column = 0, row, stack, grid };
/// Cross-axis alignment of children (C `cui_align`).
pub const Align = enum(c_int) { default = 0, start, center, end, stretch };
/// Main-axis distribution (C `cui_justify`).
pub const Justify = enum(c_int) { start = 0, center, end, between, around };
/// Shadow strength (C `cui_elevation`).
pub const Elevation = enum(c_int) { none = 0, resting, raised, floating };
/// Text direction (C `cui_direction`).
pub const Direction = enum(c_int) { inherit = 0, ltr, rtl, auto };
pub const TextAlign = enum(c_int) { start = 0, center, right, left, end };

pub const ButtonVariant = enum(c_int) { default = 0, secondary, primary, outline, ghost, danger, link };
pub const ControlSize = enum(c_int) { md = 0, sm, lg };

/// Window renderer (C `cui_renderer_kind`).
pub const RendererKind = enum(c_int) { auto = 0, opengl, software };
/// Theme (C `cui_theme_mode`).
pub const ThemeMode = enum(c_int) { light = 0, dark };
/// Accent color (C `cui_accent`).
pub const Accent = enum(c_int) { neutral = 0, violet, blue, green, amber, orange, coral, rose };

/// A few common Lucide icons (UTF-8 strings, from cui_icons.h; the full list
/// lives there — any of them can be passed as a string).
pub const icon = struct {
    pub const check = "\xee\x81\xac";
    pub const x = "\xee\x86\xb2";
    pub const plus = "\xee\x84\xbd";
    pub const minus = "\xee\x84\x9c";
    pub const chevron_down = "\xee\x81\xad";
    pub const chevron_up = "\xee\x81\xb0";
    pub const chevron_left = "\xee\x81\xae";
    pub const chevron_right = "\xee\x81\xaf";
    pub const search = "\xee\x85\x91";
    pub const settings = "\xee\x85\x94";
    pub const user = "\xee\x86\x9f";
    pub const bell = "\xee\x81\x99";
    pub const trash = "\xee\x86\x8e";
    pub const pencil = "\xee\x87\xb9";
    pub const copy = "\xee\x82\x9e";
};

/// Flags a text field returns for the frame (C `CUI_CHANGED` / `CUI_SUBMITTED` / ...).
pub const InputFlags = struct {
    raw_value: c_int,

    pub fn changed(self: InputFlags) bool {
        return self.raw_value & c.CUI_CHANGED != 0;
    }
    pub fn submitted(self: InputFlags) bool {
        return self.raw_value & c.CUI_SUBMITTED != 0;
    }
    pub fn focused(self: InputFlags) bool {
        return self.raw_value & c.CUI_FOCUSED != 0;
    }
    pub fn blurred(self: InputFlags) bool {
        return self.raw_value & c.CUI_BLURRED != 0;
    }
};

// --------------------------------------------------------------------------
// Options (mirror the C opts structs; zero value = C default)
// --------------------------------------------------------------------------

/// C `cui_box` — options for every container.
pub const BoxOpts = struct {
    id: ?[]const u8 = null,
    dir: Dir = .column,
    width: Size = .fit,
    height: Size = .fit,
    min_width: f32 = 0,
    max_width: f32 = 0,
    min_height: f32 = 0,
    max_height: f32 = 0,
    pad: f32 = 0,
    pad_x: f32 = 0,
    pad_y: f32 = 0,
    pad_top: f32 = 0,
    pad_right: f32 = 0,
    pad_bottom: f32 = 0,
    pad_left: f32 = 0,
    gap: f32 = 0,
    /// `dir = .grid`: column count (with min_column_width: the most columns)
    columns: i32 = 0,
    /// `dir = .grid`: as many columns as fit at this width, at least one
    min_column_width: f32 = 0,
    /// rows: children that do not fit move to a new line
    wrap: bool = false,
    @"align": Align = .default,
    justify: Justify = .start,
    bg: ?Color = null,
    border_color: ?Color = null,
    border: f32 = 0,
    radius: f32 = 0,
    radius_tl: f32 = 0,
    radius_tr: f32 = 0,
    radius_br: f32 = 0,
    radius_bl: f32 = 0,
    elevation: Elevation = .none,
    scroll_x: bool = false,
    scroll_y: bool = false,
    clip: bool = false,
    /// 0 means 1 (fully opaque)
    opacity: f32 = 0,
    direction: Direction = .inherit,
};

/// C `cui_card_opts`.
pub const CardOpts = struct {
    id: ?[]const u8 = null,
    width: Size = .fit,
    height: Size = .fit,
    min_width: f32 = 0,
    max_width: f32 = 0,
    pad: f32 = 0,
    pad_x: f32 = 0,
    pad_y: f32 = 0,
    gap: f32 = 0,
    dir: Dir = .column,
    @"align": Align = .default,
    wrap: bool = false,
    /// lifts slightly on hover; hover state via `zui.raw.cui_last_hovered`
    hoverable: bool = false,
    muted: bool = false,
    selected: bool = false,
};

/// C `cui_scroll_opts`.
pub const ScrollOpts = struct {
    id: ?[]const u8 = null,
    width: Size = .fit,
    height: Size = .fit,
    horizontal: bool = false,
    pad: f32 = 0,
    gap: f32 = 0,
    fade_edges: bool = false,
    fade_color: ?Color = null,
};

/// C `cui_split_opts`.
pub const SplitOpts = struct {
    vertical: bool = false,
    min_first: f32 = 0,
    min_second: f32 = 0,
    width: Size = .fit,
    height: Size = .fit,
};

/// C `cui_text_opts`.
pub const TextOpts = struct {
    /// C `cui_font`; 0 is the body font (see zui.raw for the list)
    font: c_int = 0,
    /// 0 = theme default
    size: f32 = 0,
    color: ?Color = null,
    @"align": TextAlign = .start,
    /// single line, ellipsis when it does not fit
    nowrap: bool = false,
    tabular: bool = false,
    width: Size = .fit,
    /// multiplier, 0 = default 1.45
    line_height: f32 = 0,
    direction: Direction = .inherit,
};

/// C `cui_button_opts`.
pub const ButtonOpts = struct {
    variant: ButtonVariant = .default,
    size: ControlSize = .md,
    icon: ?[]const u8 = null,
    icon_right: ?[]const u8 = null,
    disabled: bool = false,
    loading: bool = false,
    full_width: bool = false,
    selected: bool = false,
    tooltip: ?[]const u8 = null,
    shortcut: ?[]const u8 = null,
    width: Size = .fit,
    color: ?Color = null,
};

/// C `cui_check_opts` (checkbox, switch, radio).
pub const CheckOpts = struct {
    description: ?[]const u8 = null,
    disabled: bool = false,
    indeterminate: bool = false,
};

/// C `cui_input_opts` (input, textarea, search).
pub const InputOpts = struct {
    label: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    /// error text below the field (red)
    @"error": ?[]const u8 = null,
    password: bool = false,
    disabled: bool = false,
    clearable: bool = false,
    autofocus: bool = false,
    read_only: bool = false,
    size: ControlSize = .md,
    width: Size = .fit,
    /// textarea: height in points; negative fills the space
    height: f32 = 0,
    /// muted text before the value, e.g. "$"
    prefix: ?[]const u8 = null,
    /// muted text after the value, e.g. "kg"
    suffix: ?[]const u8 = null,
};

/// C `cui_slider_opts`.
pub const SliderOpts = struct {
    show_value: bool = false,
    disabled: bool = false,
    width: Size = .fit,
};

/// C `cui_number_opts`.
pub const NumberOpts = struct {
    label: ?[]const u8 = null,
    step: f64 = 0,
    decimals: i32 = 0,
    disabled: bool = false,
    width: Size = .fit,
    suffix: ?[]const u8 = null,
};

// --------------------------------------------------------------------------
// Ui — wraps one cui_ctx
// --------------------------------------------------------------------------

const ends_max = 128;
const EndFn = *const @TypeOf(c.cui_box_end);

const Owner = union(enum) {
    /// transient Ui (App.run trampoline): only owns the string arena
    none,
    /// owned by an App; C-side teardown is App.destroy's job
    app,
    /// created by createHeadless; destroy() tears the ctx and renderer down
    headless: struct { sw: *c.cui_sw_renderer },
};

pub const Ui = struct {
    /// the wrapped `cui_ctx *`; pass to any `zui.raw.cui_*` function
    h: *c.cui_ctx,
    owner: Owner,
    arena: std.heap.ArenaAllocator,
    ends: [ends_max]EndFn = undefined,
    depth: usize = 0,

    // ---- lifecycle ----------------------------------------------------------

    /// Creates a windowless context backed by CUI's software renderer, for
    /// tests, screenshots and servers. `width`/`height` are logical points.
    pub fn createHeadless(width: i32, height: i32, scale: f32) !*Ui {
        const sw = c.cui_sw_create();
        if (sw == null) return error.CuiRendererFailed;
        errdefer c.cui_sw_destroy(@ptrCast(sw));

        var desc: c.cui_ctx_desc = std.mem.zeroes(c.cui_ctx_desc);
        desc.renderer = c.cui_sw_iface(@ptrCast(sw));
        const hctx = c.cui_create(&desc);
        if (hctx == null) return error.CuiCreateFailed;
        errdefer c.cui_destroy(@ptrCast(hctx));

        const self = try std.heap.page_allocator.create(Ui);
        errdefer std.heap.page_allocator.destroy(self);
        self.* = .{
            .h = forcePtr(c.cui_ctx, hctx),
            .owner = .{ .headless = .{ .sw = forcePtr(c.cui_sw_renderer, sw) } },
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
        self.setViewport(@floatFromInt(width), @floatFromInt(height), scale);
        return self;
    }

    /// Frees the Ui. For headless contexts also destroys the ctx and renderer.
    pub fn destroy(self: *Ui) void {
        switch (self.owner) {
            .headless => |hd| {
                c.cui_destroy(self.h);
                c.cui_sw_destroy(hd.sw);
            },
            else => {},
        }
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }

    // ---- frame ---------------------------------------------------------------

    /// Headless only: begins a frame (App drives this itself).
    pub fn beginFrame(self: *Ui, dt: f32) void {
        self.assertBalanced();
        self.resetStrings();
        c.cui_begin_frame(self.h, dt);
    }

    /// Headless only: ends the frame; `drawData` then holds what was built.
    pub fn endFrame(self: *Ui) void {
        self.assertBalanced();
        c.cui_end_frame(self.h);
    }

    /// Headless only: the draw list of the last ended frame.
    pub fn drawData(self: *Ui) *const c.cui_draw_data {
        const dd = c.cui_get_draw_data(self.h);
        if (dd == null) @panic("zui: no draw data (call endFrame first)");
        return @ptrCast(dd);
    }

    /// Headless only: rasterizes the last frame into `pixels` (RGBA, 4 bytes/px).
    pub fn render(self: *Ui, pixels: []u8) !void {
        const dd = self.drawData();
        const w: usize = @intCast(dd.width_px);
        const hgt: usize = @intCast(dd.height_px);
        if (pixels.len < w * hgt * 4) return error.BufferTooSmall;
        const sw = switch (self.owner) {
            .headless => |hd| hd.sw,
            else => return error.NotHeadless,
        };
        c.cui_sw_render(sw, dd, pixels.ptr, dd.width_px, dd.height_px, @intCast(w * 4), cEnumZero(c.cui_sw_format));
    }

    pub fn setViewport(self: *Ui, width: f32, height: f32, scale: f32) void {
        c.cui_set_viewport(self.h, width, height, scale);
    }

    // ---- frame string arena --------------------------------------------------

    /// Frees and reuses the memory behind strings created this frame.
    /// Called by the frame drivers; no need to call it yourself.
    pub fn resetStrings(self: *Ui) void {
        _ = self.arena.reset(.retain_capacity);
    }

    /// NUL-terminated copy of `s` that lives until the next frame begins.
    pub fn tmpStr(self: *Ui, s: []const u8) [:0]const u8 {
        if (std.mem.indexOfScalar(u8, s, 0) != null)
            @panic("zui: string contains a NUL byte");
        return self.arena.allocator().dupeSentinel(u8, s, 0) catch
            @panic("zui: out of memory in the frame string arena");
    }

    /// Formatted string that lives until the next frame begins
    /// (the C equivalent is `cui_textf`).
    pub fn tmpFmt(self: *Ui, comptime fmt: []const u8, args: anytype) [:0]const u8 {
        return std.fmt.allocPrintSentinel(self.arena.allocator(), fmt, args, 0) catch
            @panic("zui: out of memory in the frame string arena");
    }

    // ---- scopes ---------------------------------------------------------------

    /// Opens a vertical container. Pair with `defer ui.end()`.
    pub fn column(self: *Ui, opts: BoxOpts) void {
        self.pushEnd(c.cui_box_end);
        const co = self.cvtOpts(c.cui_box, opts);
        _ = c.cui_column_begin(self.h, &co);
    }

    /// Opens a horizontal container. Pair with `defer ui.end()`.
    pub fn row(self: *Ui, opts: BoxOpts) void {
        self.pushEnd(c.cui_box_end);
        const co = self.cvtOpts(c.cui_box, opts);
        _ = c.cui_row_begin(self.h, &co);
    }

    /// Opens a raw `cui_box` (arbitrary direction). Pair with `defer ui.end()`.
    pub fn box(self: *Ui, opts: BoxOpts) void {
        self.pushEnd(c.cui_box_end);
        const co = self.cvtOpts(c.cui_box, opts);
        _ = c.cui_box_begin(self.h, &co);
    }

    /// Opens a bordered surface. Pair with `defer ui.end()`.
    pub fn card(self: *Ui, opts: CardOpts) void {
        self.pushEnd(c.cui_card_end);
        const co = self.cvtOpts(c.cui_card_opts, opts);
        _ = c.cui_card_begin(self.h, &co);
    }

    /// Opens a scroll area. Pair with `defer ui.end()`.
    pub fn scroll(self: *Ui, opts: ScrollOpts) void {
        self.pushEnd(c.cui_scroll_end);
        const co = self.cvtOpts(c.cui_scroll_opts, opts);
        c.cui_scroll_begin(self.h, &co);
    }

    /// Opens the first pane of a resizable split view; call `splitNext()`
    /// between the panes. Pair with `defer ui.end()`.
    pub fn split(self: *Ui, id: []const u8, ratio: *f32, opts: SplitOpts) void {
        self.pushEnd(c.cui_split_end);
        const co = self.cvtOpts(c.cui_split_opts, opts);
        c.cui_split_begin(self.h, self.tmpStr(id).ptr, ratio, &co);
    }

    pub fn splitNext(self: *Ui) void {
        c.cui_split_next(self.h);
    }

    /// Names the components until the matching `ui.end()` (C `cui_id_scope`).
    pub fn pushId(self: *Ui, str: []const u8) void {
        self.pushEnd(c.cui_pop_id);
        c.cui_push_id(self.h, self.tmpStr(str).ptr);
    }

    pub fn pushIdInt(self: *Ui, value: i32) void {
        self.pushEnd(c.cui_pop_id);
        c.cui_push_id_int(self.h, value);
    }

    /// Disables everything until the matching `ui.end()`.
    pub fn pushDisabled(self: *Ui, disabled: bool) void {
        self.pushEnd(c.cui_pop_disabled);
        c.cui_push_disabled(self.h, disabled);
    }

    /// Closes the innermost open scope (container, id or disabled scope).
    /// The intended use is `defer ui.end();` right after opening one.
    pub fn end(self: *Ui) void {
        if (self.depth == 0)
            @panic("zui: ui.end() with no open scope");
        self.depth -= 1;
        self.ends[self.depth](self.h);
    }

    /// True while a scope is open (mid-frame bookkeeping).
    pub fn scoped(self: *Ui) bool {
        return self.depth != 0;
    }

    pub fn isDisabled(self: *Ui) bool {
        return c.cui_is_disabled(self.h);
    }

    // ---- text -----------------------------------------------------------------

    pub fn heading(self: *Ui, s: []const u8, level: i32) void {
        c.cui_heading(self.h, self.tmpStr(s).ptr, level);
    }

    pub fn text(self: *Ui, s: []const u8) void {
        c.cui_text_ex(self.h, self.tmpStr(s).ptr, null);
    }

    pub fn textOpts(self: *Ui, s: []const u8, opts: TextOpts) void {
        const co = self.cvtOpts(c.cui_text_opts, opts);
        c.cui_text_ex(self.h, self.tmpStr(s).ptr, &co);
    }

    /// Formatted text with Zig's `std.fmt` syntax (C: `cui_textf`).
    pub fn textf(self: *Ui, comptime fmt: []const u8, args: anytype) void {
        self.text(self.tmpFmt(fmt, args));
    }

    pub fn secondary(self: *Ui, s: []const u8) void {
        c.cui_secondary(self.h, self.tmpStr(s).ptr);
    }

    pub fn muted(self: *Ui, s: []const u8) void {
        c.cui_muted(self.h, self.tmpStr(s).ptr);
    }

    pub fn code(self: *Ui, s: []const u8) void {
        c.cui_code(self.h, self.tmpStr(s).ptr);
    }

    pub fn kbd(self: *Ui, keys: []const u8) void {
        c.cui_kbd(self.h, self.tmpStr(keys).ptr);
    }

    pub fn link(self: *Ui, s: []const u8) bool {
        return c.cui_link(self.h, self.tmpStr(s).ptr);
    }

    /// Draws an icon glyph by name (e.g. `zui.icon.plus`).
    pub fn iconGlyph(self: *Ui, name: []const u8, size: f32, color: ?Color) void {
        c.cui_icon(self.h, self.tmpStr(name).ptr, size, colorToC(color));
    }

    // ---- flow -----------------------------------------------------------------

    pub fn spacer(self: *Ui) void {
        c.cui_spacer(self.h);
    }

    pub fn gap(self: *Ui, size: f32) void {
        c.cui_gap(self.h, size);
    }

    pub fn separator(self: *Ui) void {
        c.cui_separator(self.h);
    }

    // ---- controls ---------------------------------------------------------------

    /// Returns true on the frame the button was clicked.
    pub fn button(self: *Ui, label: []const u8, opts: ButtonOpts) bool {
        const co = self.cvtOpts(c.cui_button_opts, opts);
        return c.cui_button_ex(self.h, self.tmpStr(label).ptr, &co);
    }

    /// Square/round icon-only button. Give it a tooltip so it has a name.
    pub fn iconButton(self: *Ui, icon_name: []const u8, opts: ButtonOpts) bool {
        const co = self.cvtOpts(c.cui_button_opts, opts);
        return c.cui_icon_button_ex(self.h, self.tmpStr(icon_name).ptr, &co);
    }

    pub fn checkbox(self: *Ui, label: []const u8, value: *bool, opts: CheckOpts) bool {
        const co = self.cvtOpts(c.cui_check_opts, opts);
        return c.cui_checkbox_ex(self.h, self.tmpStr(label).ptr, value, &co);
    }

    pub fn switch_(self: *Ui, label: []const u8, value: *bool, opts: CheckOpts) bool {
        const co = self.cvtOpts(c.cui_check_opts, opts);
        return c.cui_switch_ex(self.h, self.tmpStr(label).ptr, value, &co);
    }

    pub fn radio(self: *Ui, label: []const u8, value: *i32, option: i32, opts: CheckOpts) bool {
        const co = self.cvtOpts(c.cui_check_opts, opts);
        return c.cui_radio_ex(self.h, self.tmpStr(label).ptr, value, option, &co);
    }

    /// Returns true when the value changed this frame.
    pub fn slider(self: *Ui, label: []const u8, value: *f32, min: f32, max: f32, opts: SliderOpts) bool {
        const co = self.cvtOpts(c.cui_slider_opts, opts);
        return c.cui_slider_ex(self.h, self.tmpStr(label).ptr, value, min, max, &co);
    }

    /// A bounded number field; only complete finite drafts update `value`.
    pub fn number(self: *Ui, id: []const u8, value: *f64, min: f64, max: f64, opts: NumberOpts) bool {
        const co = self.cvtOpts(c.cui_number_opts, opts);
        return c.cui_number_ex(self.h, self.tmpStr(id).ptr, value, min, max, &co);
    }

    /// Single-line text field editing `buf` in place. `buf` must stay valid
    /// and keep its size; the field shows whatever is in it.
    pub fn input(self: *Ui, id: []const u8, buf: []u8, opts: InputOpts) InputFlags {
        const co = self.cvtOpts(c.cui_input_opts, opts);
        const r = c.cui_input_ex(self.h, self.tmpStr(id).ptr, buf.ptr, buf.len, &co);
        return .{ .raw_value = r };
    }

    pub fn textarea(self: *Ui, id: []const u8, buf: []u8, opts: InputOpts) InputFlags {
        const co = self.cvtOpts(c.cui_input_opts, opts);
        const r = c.cui_textarea_ex(self.h, self.tmpStr(id).ptr, buf.ptr, buf.len, &co);
        return .{ .raw_value = r };
    }

    pub fn search(self: *Ui, id: []const u8, buf: []u8, opts: InputOpts) InputFlags {
        const co = self.cvtOpts(c.cui_input_opts, opts);
        const r = c.cui_search_ex(self.h, self.tmpStr(id).ptr, buf.ptr, buf.len, &co);
        return .{ .raw_value = r };
    }

    // ---- internals --------------------------------------------------------------

    fn init(owner: Owner) Ui {
        return .{
            .h = undefined,
            .owner = owner,
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
    }

    fn assertBalanced(self: *Ui) void {
        if (self.depth != 0)
            @panic("zui: container scope(s) still open at end of frame — every ui.column/row/card/scroll/split/pushId/pushDisabled needs a matching `defer ui.end()`");
    }

    inline fn pushEnd(self: *Ui, f: EndFn) void {
        if (self.depth >= ends_max)
            @panic("zui: too many open scopes in one frame (raise zui's ends_max)");
        self.ends[self.depth] = f;
        self.depth += 1;
    }

    /// Converts a Zig options struct into its C counterpart. Field rules:
    /// `?[]const u8` -> frame-arena NUL-terminated pointer, `Size` -> `cui_size`,
    /// `?Color` -> `cui_color` (null = zeroed = C default), wrapper enums ->
    /// the C enum value, everything else copies directly. Field names must
    /// match the C struct.
    fn cvtOpts(self: *Ui, comptime C: type, o: anytype) C {
        var out: C = std.mem.zeroes(C);
        const info = @typeInfo(@TypeOf(o)).@"struct";
        inline for (0..info.field_names.len) |i| {
            const f = info.field_names[i];
            const val = @field(o, f);
            const From = @TypeOf(val);
            const dst = &@field(out, f);
            const To = @TypeOf(dst.*);
            if (From == ?[]const u8) {
                dst.* = if (val) |s| @ptrCast(self.tmpStr(s).ptr) else null;
            } else if (From == Size) {
                dst.* = val.toC();
            } else if (From == ?Color) {
                dst.* = if (val) |cc| cc.toC() else std.mem.zeroes(To);
            } else if (@typeInfo(From) == .@"enum") {
                if (@typeInfo(To) == .@"enum") {
                    dst.* = @enumFromInt(@intFromEnum(val));
                } else {
                    dst.* = @intCast(@intFromEnum(val));
                }
            } else {
                dst.* = val;
            }
        }
        return out;
    }
};

fn colorToC(color: ?Color) c.cui_color {
    return if (color) |cc| cc.toC() else std.mem.zeroes(c.cui_color);
}

/// Unwraps a pointer the way translate-c declared it (optional or [*c]).
/// The caller must have checked for null.
fn forcePtr(comptime P: type, v: anytype) *P {
    if (@typeInfo(@TypeOf(v)) == .optional) return v.?;
    return @ptrCast(v);
}

/// The zero value of a C enum, whatever shape translate-c gave it.
fn cEnumZero(comptime T: type) T {
    if (@typeInfo(T) == .@"enum") return @enumFromInt(0);
    return @as(T, 0);
}

// --------------------------------------------------------------------------
// App — the window + event loop (C cui_app)
// --------------------------------------------------------------------------

pub const AppDesc = struct {
    title: []const u8 = "CUI",
    /// logical size; 0 = C default (1080 x 720)
    width: i32 = 0,
    height: i32 = 0,
    /// 0 = C default (360 x 280)
    min_width: i32 = 0,
    min_height: i32 = 0,
    fixed_size: bool = false,
    /// render every frame even when idle (games, video)
    continuous: bool = false,
    no_vsync: bool = false,
    /// create the window hidden
    hidden: bool = false,
    renderer: RendererKind = .auto,
    theme: ThemeMode = .light,
    accent: Accent = .neutral,
    follow_system_theme: bool = false,
    /// Linux only: the app's ID (WM_CLASS / Wayland app_id)
    app_id: ?[]const u8 = null,
};

pub const App = struct {
    handle: *c.cui_app,
    ui_state: Ui,

    /// Creates a window. Fails when no window can be opened.
    pub fn create(desc: AppDesc) !*App {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var cd: c.cui_app_desc = std.mem.zeroes(c.cui_app_desc);
        cd.title = @ptrCast((try alloc.dupeSentinel(u8, desc.title, 0)).ptr);
        cd.width = desc.width;
        cd.height = desc.height;
        cd.min_width = desc.min_width;
        cd.min_height = desc.min_height;
        cd.fixed_size = desc.fixed_size;
        cd.continuous = desc.continuous;
        cd.no_vsync = desc.no_vsync;
        cd.hidden = desc.hidden;
        cd.renderer = enumOrInt(@TypeOf(cd.renderer), desc.renderer);
        cd.theme = enumOrInt(@TypeOf(cd.theme), desc.theme);
        cd.accent = enumOrInt(@TypeOf(cd.accent), desc.accent);
        cd.follow_system_theme = desc.follow_system_theme;
        if (desc.app_id) |aid|
            cd.app_id = @ptrCast((try alloc.dupeSentinel(u8, aid, 0)).ptr);

        const handle = c.cui_app_create(&cd);
        if (handle == null) return error.CuiAppCreateFailed;
        errdefer c.cui_app_destroy(@ptrCast(handle));

        const self = try std.heap.page_allocator.create(App);
        errdefer std.heap.page_allocator.destroy(self);
        self.* = .{
            .handle = forcePtr(c.cui_app, handle),
            .ui_state = Ui.init(.app),
        };
        self.ui_state.h = forcePtr(c.cui_ctx, c.cui_app_ui(self.handle));
        return self;
    }

    pub fn destroy(self: *App) void {
        c.cui_app_destroy(self.handle);
        self.ui_state.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }

    /// Presents the previous frame, waits for input or animation, then begins
    /// a new one. Returns false once the window was closed or `quit` was called.
    pub fn frame(self: *App) bool {
        self.ui_state.assertBalanced();
        if (!c.cui_app_frame(self.handle)) return false;
        self.ui_state.h = forcePtr(c.cui_ctx, c.cui_app_ui(self.handle));
        self.ui_state.resetStrings();
        return true;
    }

    /// The UI to draw into for this frame. Valid until the next `frame` call.
    pub fn ui(self: *App) *Ui {
        return &self.ui_state;
    }

    /// Ends the loop after the current frame.
    pub fn quit(self: *App) void {
        c.cui_app_quit(self.handle);
    }

    pub fn setTitle(self: *App, title: []const u8) void {
        c.cui_app_set_title(self.handle, self.ui_state.tmpStr(title).ptr);
    }

    pub fn setSize(self: *App, width: i32, height: i32) void {
        c.cui_app_set_size(self.handle, width, height);
    }

    pub fn maximize(self: *App) void {
        c.cui_app_maximize(self.handle);
    }

    pub fn restore(self: *App) void {
        c.cui_app_restore(self.handle);
    }

    /// Active backend name: "cocoa", "win32", "x11", "sdl2" or "glfw".
    pub fn backend(self: *App) []const u8 {
        return std.mem.span(c.cui_app_backend(self.handle));
    }

    /// True when the software renderer is drawing (no usable OpenGL).
    pub fn isSoftware(self: *App) bool {
        return c.cui_app_is_software(self.handle);
    }

    // ---- callback style ---------------------------------------------------------

    /// C `cui_app_run`: creates the window, calls `frameFn(&ui, user)` whenever
    /// the screen needs drawing, destroys the window, returns the exit code.
    /// `frameFn` is `fn (*Ui, @TypeOf(user)) void`.
    pub fn run(desc: AppDesc, frameFn: anytype, user: anytype) i32 {
        const User = @TypeOf(user);
        const State = struct { ui: Ui, user: User };
        const Tramp = struct {
            fn call(hctx: ?*c.cui_ctx, u: ?*anyopaque) callconv(.c) void {
                const st: *State = @ptrCast(@alignCast(u.?));
                st.ui.h = hctx.?;
                st.ui.assertBalanced();
                st.ui.resetStrings();
                @call(.auto, frameFn, .{ &st.ui, st.user });
            }
        };

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var cd: c.cui_app_desc = std.mem.zeroes(c.cui_app_desc);
        cd.title = @ptrCast((alloc.dupeSentinel(u8, desc.title, 0) catch @panic("zui: out of memory")).ptr);
        cd.width = desc.width;
        cd.height = desc.height;
        cd.min_width = desc.min_width;
        cd.min_height = desc.min_height;
        cd.fixed_size = desc.fixed_size;
        cd.continuous = desc.continuous;
        cd.no_vsync = desc.no_vsync;
        cd.hidden = desc.hidden;
        cd.renderer = enumOrInt(@TypeOf(cd.renderer), desc.renderer);
        cd.theme = enumOrInt(@TypeOf(cd.theme), desc.theme);
        cd.accent = enumOrInt(@TypeOf(cd.accent), desc.accent);
        cd.follow_system_theme = desc.follow_system_theme;
        if (desc.app_id) |aid|
            cd.app_id = @ptrCast((alloc.dupeSentinel(u8, aid, 0) catch @panic("zui: out of memory")).ptr);

        const st = std.heap.page_allocator.create(State) catch @panic("zui: out of memory");
        defer {
            st.ui.arena.deinit();
            std.heap.page_allocator.destroy(st);
        }
        st.* = .{ .ui = Ui.init(.none), .user = user };
        return c.cui_app_run(&cd, Tramp.call, st);
    }
};

// --------------------------------------------------------------------------
// helpers
// --------------------------------------------------------------------------

/// Converts a wrapper enum into a C-side enum field/argument, whatever shape
/// translate-c gave the C enum (a real Zig enum or an integer).
fn enumOrInt(comptime To: type, v: anytype) To {
    const n = @intFromEnum(v);
    return if (@typeInfo(To) == .@"enum") @enumFromInt(n) else @intCast(n);
}

// --------------------------------------------------------------------------
// tests
// --------------------------------------------------------------------------

test {
    _ = @import("smoke_test.zig");
}
