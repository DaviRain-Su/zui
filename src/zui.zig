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

/// C `cui_color` { r, g, b, a } (extern: layout-compatible with the C
/// struct, so `[]Color` can be passed to C functions writing in place).
pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn rgb(hex: u32) Color {
        return .{
            .r = @truncate(hex >> 16),
            .g = @truncate(hex >> 8),
            .b = @truncate(hex),
            .a = 255,
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

/// C `cui_rect` (extern: layout-compatible with the C struct).
pub const Rect = extern struct { x: f32, y: f32, w: f32, h: f32 };

/// C `cui_vec2` (extern: layout-compatible with the C struct).
pub const Vec2 = extern struct { x: f32, y: f32 };

pub const MouseButton = enum(c_int) { left = 0, right, middle };

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

// ==== GEN:TYPES ====

// Generated enums and struct mirrors. Field names match the C structs;
// defaults match C's zero-init semantics. Pointer+count field pairs are
// folded into one slice field.

/// A line, a threshold or a point drawn over a chart, with a two-line label: the label in
/// the foreground color and a muted detail under it. Line and bar charts take them in
/// cui_chart_opts, the dot chart in cui_dot_chart_opts. Labels that would overlap move
/// to the other side of their line, then down.
pub const AnnotationKind = enum(c_int) {
    x = 0,  // a vertical line at `x`, labelled at its top
    y = 1,  // a dashed horizontal line at the value `y`, labelled at its end
    point = 2,  // a dot at `x`, `y`, labelled beside it
};

/// ------------------------------------------------------------------------
/// Instruments: dot-matrix chart, event track, readout, dot-matrix display
/// ------------------------------------------------------------------------
/// How an axis labels its values.
pub const AxisUnits = enum(c_int) {
    number = 0,  // numbers, printed with the axis format (default "%g")
    hours = 1,  // hours shown as a time of day: 12.25 is 12:15, and 30 is 06:00 the next day
};

pub const Cursor = enum(c_int) {
    arrow = 0,
    hand = 1,
    text = 2,
    resize_ew = 3,
    resize_ns = 4,
    move = 5,
    not_allowed = 6,
    count = 7,
};

/// ---- Curve and gradient editors ----
/// Curve editor: keyframes on a plot, for easing, animation timing and
/// response curves. You own the array of keys, sorted by x; the editor edits
/// it in place (moves, handles, modes, adds and removes) and reports what it
/// did in the result, so data you keep beside each key can follow:
/// static cui_curve_key ease[8] = { { 0, 0 }, { 0.42f, 0.1f }, { 1, 1 } };
/// static int n = 3, sel = -1;
/// cui_curve_result r = cui_curve_editor(ui, "ease", ease, &n, 8, .selected = &sel);
/// if (r.added >= 0) insert_my_data(r.added);
/// if (r.removed >= 0) remove_my_data(r.removed);
/// ...
/// float y = cui_curve_eval(ease, n, t);   (the same curve the editor draws)
/// The mode of a key shapes the segment that leaves it: SMOOTH and FREE are
/// cubic beziers, LINEAR a straight line, STEP holds the key's value until the
/// next key. A SMOOTH key computes its tangents (no overshoot, flat at the
/// ends and at peaks); a FREE key uses its handles, which are relative to the
/// key in curve units (in_dx <= 0, out_dx >= 0) and are shortened to the
/// neighbouring key so the curve never folds back. The incoming segment of a
/// LINEAR or STEP key arrives with an automatic tangent. Before the first key
/// the curve holds the first value, after the last key the last value.
/// Drag a key to move it (x stays between its neighbours, both axes inside the
/// range); drag the handles of the selected key (a SMOOTH key becomes FREE);
/// Shift or `snap` snaps a drag to the grid. Double click empty space to add
/// a key (on the curve when the click is near it), Delete or Backspace removes
/// the selected key (never fewer than two). Keys are focusable: Tab moves
/// through them, the arrows nudge (Shift for fine steps). Hovering shows the
/// value under the pointer. The row under the plot sets the selected key's
/// mode and exact position (its fields stack on a narrow editor).
pub const CurveMode = enum(c_int) {
    smooth = 0,  // automatic tangents
    free = 1,  // the key's own handles
    linear = 2,  // a straight line to the next key
    step = 3,  // hold this value until the next key
};

/// ---- Diff viewer ----
/// Diff viewer: compares two versions of a text line by line, side by side or
/// inline, with changed words marked inside changed lines. The texts are yours
/// (UTF-8, read during the call); the view keeps a copy and diffs again only
/// when one of them changes, so it is cheap to call every frame.
/// static cui_diff_mode mode = CUI_DIFF_SPLIT;
/// static int change = 0;                       (the selected change, -1 none)
/// cui_diff_result r = cui_diff_view(ui, "diff", before, after, .mode = mode, .current = &change,
/// .language = "c", .old_title = "parser.c (main)", .new_title = "parser.c");
/// if (cui_icon_button(ui, CUI_ICON_ARROW_DOWN, .tooltip = "Next change", .shortcut = "N"))
/// change = CUI_MIN(change + 1, r.changes - 1);   (or any index: the view scrolls to it)
/// cui_textf(ui, "+%d -%d", r.added, r.removed);
/// The line diff is Myers' algorithm (the shortest edit script, in linear
/// memory). Very different large texts are capped: past about 16 million search
/// steps the remaining parts are shown as replaced, still a correct diff but
/// not the shortest (r.approximate). Insertions and deletions slide to end on
/// a blank line where they can, the way an added function reads best. Paired
/// changed lines get word marks when they have enough in common.
/// Split shows the old text on the left and the new on the right, rows aligned
/// with a blank filler opposite added or removed lines; narrower than
/// split_min_width (560 points) it shows inline instead (r.mode says which).
/// Each side has its line numbers and a + or - sign. Unchanged stretches keep
/// .context lines (3) beside each change; longer ones fold into a "42 unchanged
/// lines" row that opens on a click. Lines longer than the view scroll
/// sideways, both sides together; the first 1024 bytes of a line are drawn.
/// With the view focused: N or Alt+Down goes to the next change, P or Alt+Up to
/// the previous one, arrows and Page Up/Down scroll, E opens every fold and
/// Shift+E folds them again, Esc clears the selected change. A click on a
/// change selects it. Only the rows in sight are built.
pub const DiffMode = enum(c_int) {
    split = 0,
    @"inline" = 1,
};

/// The rows the view shows after folding, e.g. to put a comment button beside
/// a line. Copies rows [first, first + cap) and returns how many there are (0
/// before the view's first frame). Call it in the same id scope as the view.
pub const DiffRowKind = enum(c_int) {
    same = 0,
    removed = 1,
    added = 2,
    changed = 3,  // split: a removed line beside the added line that replaced it
    fold = 4,  // hidden unchanged lines, starting at old_line / new_line
};

/// ------------------------------------------------------------------------
/// Canvas and bars: format bar, live cursors, canvas controls, result card,
/// selection bar
/// ------------------------------------------------------------------------
/// Format bar: a floating bar that edits the format of a text selection. A
/// color swatch opens a grid of colors; bold and underline toggle; link
/// reports a click; the size readout follows the text style, chosen from a
/// menu that shows each style at its own size; alignment and list open small
/// flyouts (a corner mark says so); delete asks first, in a small tip with a
/// Delete button. You pass one struct with the format and the bar edits it:
/// static cui_text_format f = { .style = 0, .size = 44 };
/// int r = cui_format_bar(ui, "fmt", &f);
/// if (r & CUI_FORMAT_CHANGED) apply(&f);
/// if (r & CUI_FORMAT_DELETE) delete_selection();
/// It is a floating toolbar, so Tab moves through its items and what does not
/// fit goes into the toolbar's "more" menu.
pub const FormatAlign = enum(c_int) {
    left = 0,
    center = 1,
    right = 2,
    justify = 3,
};

pub const FormatList = enum(c_int) {
    none = 0,
    bullets = 1,
    numbers = 2,
    checks = 3,
};

/// Gantt chart: a task list beside a timeline of bars. Drag a bar to move
/// it, its ends to resize it. Bars are colored by state (done, active,
/// planned) with their progress inside, dependencies are soft curves with
/// small arrowheads, and today is an accent line. Returns the index of a
/// clicked task, or -1.
pub const GanttState = enum(c_int) {
    auto = 0,  // from the progress and today: 1 is done, more than 0 is active; untouched work is planned when it starts after today, else active
    done = 1,  // a green bar
    active = 2,  // a bar in the first series color
    planned = 3,  // a dashed, lightly tinted bar
};

pub const GaugeStyle = enum(c_int) {
    auto = 0,  // segments with `bands`, the arc without
    arc = 1,  // a track and a value arc with round caps, min and max at its ends
    segments = 2,  // short segments lit up to the value, in the band colors
    ring = 3,  // a slim full ring starting at the top
};

/// Gradient slider: a slider whose track is the value itself (a hue wheel, a white balance
/// temperature, an opacity over a checkerboard, or your own stops), with a thumb filled with
/// the color under it. An optional tool button after the track (an eyedropper) reports
/// clicks. Keys as for the slider. Returns CUI_WELL_* flags.
/// cui_gradient_slider(ui, "Hue", &hue, 0, 360, .swatch = true);
/// cui_gradient_slider(ui, "Opacity", &alpha, 0, 1, .track = CUI_GRADIENT_OPACITY, .color = brush);
pub const GradientTrack = enum(c_int) {
    hue = 0,
    temperature = 1,
    opacity = 2,
};

/// ---- HTTP request bar ----
/// The method, the URL and Send, as in an API client. Enter in the URL sends;
/// while `loading` the button cancels. cui_response_status shows a response's
/// status, time and size in one line. cui_url_params and cui_url_set_params
/// move a URL's query to and from key-value pairs, decoding and encoding it,
/// so a parameters table can stay in step with the URL.
pub const HttpMethod = enum(c_int) {
    get = 0,
    post = 1,
    put = 2,
    patch = 3,
    delete = 4,
    head = 5,
    options = 6,
};

/// Optional application-owned input capture, before legacy aggregation.
/// Runs synchronously on the UI thread. Event and text storage are borrowed
/// only during the callback. true consumes the event; false preserves the
/// existing widget behavior. No UI construction or input injection is allowed
/// inside the callback. Copy retained text. Unregister before freeing user.
/// To replay captured input, unregister, call the existing cui_input_* entry
/// points, then register again. Legacy replay retains existing text-size limits.
/// The caller owns queue limits and error policy.
/// Key events preserve each call, including repeated down and modifier-only
/// CUI_KEY_NONE events. File drops are not intercepted by this interface.
pub const InputEventKind = enum(c_int) {
    mouse_move = 0,
    mouse_button = 1,
    mouse_leave = 2,
    scroll = 3,
    key = 4,
    text = 5,
    focus = 6,
};

/// ---- Pipeline ----
/// A CI/CD run: stages left to right, each a column of jobs with their status
/// and duration. A stage's header sums up its jobs (failed, running, passed).
/// Running jobs spin. Click a job to get its index (open its log). Below 560
/// points the stages stack top to bottom.
pub const JobStatus = enum(c_int) {
    pending = 0,
    running = 1,
    passed = 2,
    failed = 3,
    skipped = 4,
    canceled = 5,
};

pub const Key = enum(c_int) {
    none = 0,
    tab = 1,
    enter = 2,
    escape = 3,
    backspace = 4,
    delete = 5,
    space = 6,
    left = 7,
    right = 8,
    up = 9,
    down = 10,
    home = 11,
    end = 12,
    page_up = 13,
    page_down = 14,
    a = 15,
    b = 16,
    c = 17,
    d = 18,
    e = 19,
    f = 20,
    g = 21,
    h = 22,
    i = 23,
    j = 24,
    k = 25,
    l = 26,
    m = 27,
    n = 28,
    o = 29,
    p = 30,
    q = 31,
    r = 32,
    s = 33,
    t = 34,
    u = 35,
    v = 36,
    w = 37,
    x = 38,
    y = 39,
    z = 40,
    @"0" = 41,
    @"1" = 42,
    @"2" = 43,
    @"3" = 44,
    @"4" = 45,
    @"5" = 46,
    @"6" = 47,
    @"7" = 48,
    @"8" = 49,
    @"9" = 50,
    minus = 51,
    equal = 52,
    comma = 53,
    period = 54,
    slash = 55,
    f1 = 56,
    f2 = 57,
    f3 = 58,
    f4 = 59,
    f5 = 60,
    f6 = 61,
    f7 = 62,
    f8 = 63,
    f9 = 64,
    f10 = 65,
    f11 = 66,
    f12 = 67,
    count = 68,
};

pub const LoaderStyle = enum(c_int) {
    dots = 0,
    bars = 1,
    pulse = 2,
    orbit = 3,
    grid = 4,
};

/// Log console. The app owns the storage: give cui_log_init an array of line
/// records and a byte buffer for the text. Appending never allocates; when
/// either is full the oldest lines are dropped (a ring buffer). Lines longer
/// than the text buffer are cut to fit.
/// static cui_log_line lines[4096];
/// static char text[256 * 1024];
/// static cui_log_buffer log;
/// cui_log_init(&log, lines, 4096, text, sizeof text);
/// log.now = seconds_since_start();             // optional timestamp source
/// cui_log_append(&log, CUI_LOG_WARN, "Shader %s took %d ms", name, ms);
/// ...
/// cui_log_view(ui, "log", &log, .height = 320, .timestamps = true);
/// Each append is one line: a trailing newline is dropped and other control
/// characters show as spaces. The view keeps its own filter, search, follow
/// and selection state (a small index of the matching lines, at most one entry
/// per line slot, freed with the context).
pub const LogLevel = enum(c_int) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    @"error" = 4,
    level_count = 5,
};

pub const Mod = enum(c_int) {
};

/// ------------------------------------------------------------------------
/// Menus and popovers
/// ------------------------------------------------------------------------
pub const Placement = enum(c_int) {
    bottom_start = 0,
    bottom = 1,
    bottom_end = 2,
    top_start = 3,
    top = 4,
    top_end = 5,
    right_start = 6,
    left_start = 7,
    right = 8,
    left = 9,
};

/// ---- Query builder ----
/// Conditions joined by "all" or "any", in groups you can nest: the filter of
/// an issue tracker, a log search or a database view. You own the nodes, in
/// order, each with its depth: node 0 is the outer group (made for you when
/// count is 0). A rule picks a field, an operator for the field's type and a
/// value; a group picks all or any. Returns true when anything changed.
/// cui_query_text writes the query as a sentence, cui_query_match tests a
/// record against it.
pub const QueryType = enum(c_int) {
    text = 0,
    number = 1,
    choice = 2,
    bool = 3,
};

/// ---- Problems panel ----
/// Compiler and linter diagnostics, grouped by file: errors, warnings, notes
/// and hints with their position, source and code. Toggles above filter by
/// severity (with counts) and a field filters by text. A file's header folds
/// its group. Up and Down move the selection, Left and Right fold and unfold,
/// Enter or a double-click reports `activated` (open the file there). Only the
/// rows in view are built, so thousands of diagnostics stay fast. The array
/// needs to be valid only during the call.
pub const Severity = enum(c_int) {
    @"error" = 0,
    warning = 1,
    info = 2,
    hint = 3,
};

pub const Side = enum(c_int) {
    right = 0,
    left = 1,
    bottom = 2,
    top = 3,
};

/// Spinner: says that something is happening, for as long as you call it. `size` is its
/// height in points (20 when 0). The default style is a ring with a sweeping arc
/// that holds still with reduced motion. The other styles
/// are drawn in dots on an 8x8 ordered dither, one point a dot below 32 points tall and two
/// from there, and each fits a kind of wait:
/// cui_spinner(ui, 20);                                        the ring
/// cui_spinner(ui, 14, .style = CUI_SPINNER_COMET);            inline, in a button or a chip
/// cui_spinner(ui, 56, .style = CUI_SPINNER_RADAR);            searching a network
/// cui_spinner(ui, 32, .style = CUI_SPINNER_UPLOAD, .color = CUI_COLOR_ACCENT);
/// A dither spinner asks for a frame only when its dots move (12 to 30 times a second by
/// style) and only while it is on screen; reduced motion holds each style on a still frame.
pub const SpinnerStyle = enum(c_int) {
    arc = 0,  // a ring with an arc sweeping round it
    comet = 1,  // a ring of dots with a head and a tail that thins out dot by dot
    dot_matrix = 2,  // a 5x5 grid of dots with a wave running through it, for dense layouts
    fill_drain = 3,  // a tile that fills from the bottom, then dissolves: a step of a job
    radar = 4,  // a sweep round a dial; points light up as it passes: searching, scanning
    ripple = 5,  // rings spreading from a dot: connecting, pairing, waiting for the other side
    upload = 6,  // chevrons streaming up: sending
    download = 7,  // chevrons streaming down: receiving
    transfer = 8,  // both, side by side: syncing both ways
    orbit = 9,  // two dots circling, their trails dissolving: syncing
    bounce = 10,  // three bouncing dots with short trails: typing, a chat reply
    scan = 11,  // a scan line reading a page: indexing, importing
    pulse = 12,  // a soft disc breathing in density: recording, live
    spiral = 13,  // three arms turning: a long, calm background wait
    plasma = 14,  // slow moving noise in a tile: generating an image or audio
};

/// Button that shows the result of the work it started: idle, a spinner while
/// busy, then a check (or an error) that settles back. Width morphs smoothly
/// between the states. Returns true when clicked while idle.
pub const Status = enum(c_int) {
    idle = 0,
    busy = 1,
    success = 2,
    @"error" = 3,
};

/// ------------------------------------------------------------------------
/// Navigation
/// ------------------------------------------------------------------------
pub const TabsVariant = enum(c_int) {
    underline = 0,
    pill = 1,
};

/// ---- Creative controls ----
/// Status tag: an icon, a label and a fill tinted by the state, for a table cell, a card
/// header or a group of tags. "In progress" turns its dashed ring slowly (it holds still with
/// reduced motion). A NULL label shows the state's English name.
/// cui_status_tag(ui, "Failed", CUI_TAG_FAILED);
/// if (cui_status_tag(ui, name, CUI_TAG_CUSTOM, .icon = CUI_ICON_TAG, .tone = CUI_TONE_TEAL, .removable = true)) remove(name);
pub const TagStatus = enum(c_int) {
    pending = 0,
    in_progress = 1,
    submitted = 2,
    in_review = 3,
    success = 4,
    failed = 5,
    expired = 6,
    custom = 7,  // your `icon` and `tone` only
};

/// Tool call: a compact row with the tool, a detail and its status; opens to
/// show the input and the output (shown as JSON when they parse).
pub const TaskStatus = enum(c_int) {
    pending = 0,
    running = 1,
    done = 2,
    failed = 3,
    skipped = 4,
};

pub const TextureFormat = enum(c_int) {
    r8 = 1,
    rgba8 = 4,
};

/// ---- Timeline ----
/// Timeline editor (dope sheet): a track list on the left, a time ruler on
/// top and a row per track with its keys (and clips, for video and audio
/// tracks). You own the tracks, their keys and clips, the playhead time and
/// the selection; the editor edits them in place and reports what it did:
/// static cui_curve_key rot[32] = { { 0, 0 }, { 1, 30 }, { 2, 0 } };
/// static bool rot_sel[32];                   (parallel to the keys)
/// static cui_timeline_track tracks[] = {
/// { "Hero", CUI_ICON_USER, 0 },
/// { "Rotation", NULL, 1, .keys = rot, .key_count = 3, .key_capacity = 32, .key_selected = rot_sel },
/// };
/// static float t;
/// cui_timeline_editor_result r = cui_timeline_editor(ui, "anim", tracks, 2, &t, .end = 4, .fps = 24);
/// if (r.play_toggled) playing = !playing;    (you advance t while playing)
/// float angle = cui_curve_eval(rot, tracks[1].key_count, t);
/// Keys are curve keys (x is the time in seconds, y the value), so a track's
/// array goes straight into cui_curve_editor and cui_curve_eval; the mode sets
/// the mark: a diamond for SMOOTH and FREE, a circle for LINEAR, a square for
/// STEP. Keys stay sorted by time and inside start..end. A track whose next
/// tracks are deeper is a group: a chevron collapses it and its row shows
/// its tracks' keys as small marks. Only the rows in view are visited and
/// only the keys in view are searched (binary searches), so thousands of
/// tracks stay fast.
/// Mouse: click the ruler or drag in it to scrub (snapped to frames); click a
/// key to select it, Shift+click adds, Ctrl+click toggles; drag in empty
/// space for a box selection (Shift or Ctrl adds to the selection); drag
/// selected keys to move them, by whole frames (hold Shift to move freely);
/// double-click a row to add a key there (on the curve, so the motion is
/// kept); drag a clip to move it, its ends to trim it; click a track name to
/// select its keys. The wheel zooms time around the pointer, Shift+wheel or a
/// sideways scroll pans, the wheel over the track list scrolls the rows, and
/// a middle-button drag pans both ways. Hovering a key shows its time and
/// value.
/// Keys when focused: Left/Right step the playhead a frame (Shift: 10),
/// Alt+Left/Right move the selected keys a frame (Shift: 10), Up/Down jump to
/// the previous/next key, Home/End to the start/end, Space reports a play
/// request, Delete or Backspace removes the selected keys and clips, Ctrl+A
/// selects every key on the visible tracks, Esc clears the selection, F fits
/// the whole sequence (animated, snaps with reduced motion), + and - zoom
/// around the playhead. The view follows the playhead when it leaves the
/// view.
pub const TimelineRuler = enum(c_int) {
    frames = 0,  // frame numbers
    seconds = 1,  // 1.5 s
    timecode = 2,  // minutes:seconds:frames (hours too past an hour)
};

/// Semantic colors. Use these instead of raw colors so your UI follows the
/// theme (light/dark) and the accent. They can go anywhere a cui_color goes.
pub const Token = enum(c_int) {
    none = 0,
    background = 1,
    surface = 2,
    surface_raised = 3,
    surface_muted = 4,
    foreground = 5,
    text_secondary = 6,
    text_muted = 7,
    border = 8,
    border_subtle = 9,
    border_strong = 10,
    accent = 11,
    accent_strong = 12,
    accent_subtle = 13,
    accent_foreground = 14,
    success = 15,
    warning = 16,
    danger = 17,
    info = 18,
    control_on = 19,
    control_glyph = 20,
    control_track = 21,
    control_track_hover = 22,
    control_thumb = 23,
    control_thumb_on = 24,
    hover = 25,
    active = 26,
    scrim = 27,
    focus_ring = 28,
    series_1 = 29,
    series_2 = 30,
    series_3 = 31,
    series_4 = 32,
    series_5 = 33,
    series_6 = 34,
    count = 35,
};

pub const Tone = enum(c_int) {
    neutral = 0,
    info = 1,
    success = 2,
    warning = 3,
    danger = 4,
    violet = 5,
    teal = 6,
    rose = 7,
    accent = 8,
};

/// Toolbar: a row of compact icon buttons, toggles, separators and small text
/// buttons. Icon only buttons show their tooltip as their name. Items that do
/// not fit collapse, from the end, into a "more" menu; an item chosen there
/// returns true on the next frame. Tab moves through the items.
/// The grouped style puts groups of items on raised wells inside one muted
/// pill, with an optional inset radio set and a filled primary action at the
/// end; the floating style is one bordered pill for bars that sit over
/// content (a format bar, the actions under an image). Both are as wide as
/// their items and measure the room their parent gives them for the overflow.
/// cui_toolbar(ui, "edit", .style = CUI_TOOLBAR_GROUPED) {
/// cui_toolbar_group(ui) { cui_toolbar_button(ui, CUI_ICON_UNDO_2, .tooltip = "Undo"); ... }
/// cui_toolbar_group(ui) { ...; cui_toolbar_radio(ui, "mode", icons, 3, &mode, .labels = names); }
/// if (cui_toolbar_primary(ui, CUI_ICON_SPARKLES, .tooltip = "Generate")) generate();
/// }
pub const ToolbarStyle = enum(c_int) {
    plain = 0,  // a strip as wide as its parent, with a hairline under it
    grouped = 1,  // raised groups inside one muted pill
    floating = 2,  // one bordered surface pill
};

pub const VoiceOwner = enum(c_int) {
    you = 0,
    reply = 1,
};

/// What a voice conversation is doing, for the voice session's label (and the
/// voice orb, which shows the first four).
pub const VoiceState = enum(c_int) {
    idle = 0,
    listening = 1,
    thinking = 2,
    speaking = 3,
    muted = 4,
};

pub const AgentPlanOpts = struct {
    title: ?[]const u8 = null,  // heading of the plan, default "Plan"
};

/// C `cui_agent_status_opts` — Agent status pill: what the agent is doing right now and for how long.
pub const AgentStatusOpts = struct {
    status: TaskStatus = .pending,
    seconds: f32 = 0,  // elapsed time shown after the text, as 42s or 1m 05s; 0 hides it
    icon: ?[]const u8 = null,
};

pub const AlertOpts = struct {
    description: ?[]const u8 = null,
    tone: Tone = .neutral,
    icon: ?[]const u8 = null,
    dismissible: bool = false,
};

pub const ApiEndpoint = struct {
    method: ?[]const u8 = null,  // "GET"
    path: ?[]const u8 = null,  // "/users/{id}"
    summary: ?[]const u8 = null,  // one line after the path; the filter field searches it
    tag: ?[]const u8 = null,  // groups the list; NULL groups as "Other"
    deprecated: bool = false,  // struck through and muted, with a "Deprecated" badge
    params: []const ApiParam = &.{},  // the parameters listed when the endpoint is opened; may be `NULL`
};

pub const ApiExplorerOpts = struct {
    width: Size = .fit,
    height: f32 = 0,
    // `selected` (int *): pointer field, reach it via zui.raw
};

pub const ApiExplorerResult = struct {
    selected: i32 = 0,  // the selected endpoint, or -1
    try_it: i32 = 0,  // endpoint, or -1
};

/// C `cui_api_param` — ---- API explorer ----
/// Endpoints grouped by tag, each with its method, its path (parameters
/// marked) and its summary; deprecated ones are struck through. A click opens
/// an endpoint's parameters and a Try it button. A field filters by path or
/// summary. Up and Down move, Enter opens.
pub const ApiParam = struct {
    name: ?[]const u8 = null,  // the parameter's name, in the code font
    in: ?[]const u8 = null,  // where it goes: "path", "query", "header" or "body"
    @"type": ?[]const u8 = null,  // e.g. "string"; shown before where it goes
    required: bool = false,  // a red asterisk after the name
    description: ?[]const u8 = null,  // what the parameter is for, shown after its type and place; may be `NULL`
};

/// C `cui_aspect` — Aspect ratio picker: each choice drawn as a rectangle of its own proportions with its
/// ratio under it, and an optional dashed "Custom". The value at the right of the label is
/// the size in pixels. Tab reaches the choices, Left and Right move between them.
/// static const cui_aspect sizes[] = { { 1, 1 }, { 4, 3 }, { 16, 9 } };
/// cui_aspect_picker(ui, "Aspect ratio", &pick, .ratios = sizes, .count = 3, .custom = true);
pub const Aspect = struct {
    w: i32 = 0,
    h: i32 = 0,
    label: ?[]const u8 = null,
};

pub const AspectPickerOpts = struct {
    ratios: []const Aspect = &.{},  // your choices; NULL: 1:1, 4:5, 3:2, 16:9, 9:16 and 21:9
    custom: bool = false,  // adds a "Custom" choice after a divider; *index == the count of choices selects it
    custom_label: ?[]const u8 = null,  // default "Custom"
    base: i32 = 0,  // the short side in pixels, for the size at the right of the label; default 1080, negative hides the size
    value: ?[]const u8 = null,  // text at the right of the label instead of the size
    plain: bool = false,
};

pub const AvatarOpts = struct {
    size: f32 = 0,
    image: usize = 0,  // picture to show instead of the initials of the name
    status: ?[]const u8 = null,  // a dot at the bottom right: "online" green, "busy" red, "away" amber, anything else gray
    square: bool = false,  // rounded square instead of a circle
};

pub const BadgeOpts = struct {
    tone: Tone = .neutral,
    dot: bool = false,  // a small dot before the text, in the tone's color
    solid: bool = false,  // filled with the tone's color instead of a light tint of it
    icon: ?[]const u8 = null,
    size: ControlSize = .md,
};

/// C `cui_banner_opts` — ------------------------------------------------------------------------
/// More feedback
/// ------------------------------------------------------------------------
/// Announcement banner across the top of a view. Collapses smoothly when
/// dismissed (*open becomes false). Returns true when the action is clicked.
pub const BannerOpts = struct {
    tone: Tone = .neutral,
    icon: ?[]const u8 = null,
    action: ?[]const u8 = null,  // label of a button in the banner; the call returns true when it is clicked
    dismissible: bool = false,
};

/// C `cui_bar_list_opts` — Bar list: ranked horizontal bars. Rows are keyed by label, so when the
/// values change the bars grow and the rows slide to their new rank.
pub const BarListOpts = struct {
    width: Size = .fit,
    format: ?[]const u8 = null,
    max_rows: i32 = 0,  // shows only this many rows from the top; 0 shows all
    keep_order: bool = false,  // keeps the items in the order given instead of sorting them largest first
    color: ?Color = null,
};

/// C `cui_blame_commit` — ---- Blame ----
/// Source with who last changed each line: lines from one commit share one
/// gutter entry with its author, age and hash, and a bar at the edge shades
/// newer changes stronger. Hover a gutter entry for the commit's summary and
/// to mark its lines; click it to get the commit. Only the lines in view are
/// built. On a phone the gutter keeps only the shade and initials.
pub const BlameCommit = struct {
    hash: ?[]const u8 = null,  // the commit id; its first 7 characters are shown
    author: ?[]const u8 = null,  // shown in the gutter; on a phone as initials
    summary: ?[]const u8 = null,  // the commit's message line, shown in the gutter's tooltip
    time: i64 = 0,  // Unix seconds
};

pub const BlameOpts = struct {
    width: Size = .fit,
    height: f32 = 0,  // default 360
    lang: ?[]const u8 = null,  // highlights the code, as the code block
    now: i64 = 0,  // ages are counted to here; 0: the clock
    first_line: i32 = 0,  // number of the first line, default 1
};

pub const BlameResult = struct {
    clicked: i32 = 0,  // commit whose gutter entry was clicked this frame, or -1
    hovered: i32 = 0,  // commits, or -1
};

/// C `cui_calendar_heatmap_opts` — Calendar heatmap: one cell per day from start, weeks as columns, in five
/// levels, with month and weekday labels and a Less / More legend.
pub const CalendarHeatmapOpts = struct {
    cell: f32 = 0,  // size of a day's square in points, default 11
    color: ?Color = null,  // the top step, default the accent
    format: ?[]const u8 = null,
    unit: ?[]const u8 = null,
};

/// C `cui_candle` — Candlestick chart: open, high, low and close per period with volume under
/// it, for prices. The wheel zooms around the pointer, dragging (or Shift+wheel)
/// pans, a crosshair shows each candle's values, and the price axis fits the
/// candles in view. Zoomed out past a few points per candle, candles merge
/// per pixel column, so a long history stays fast. When the view shows the
/// newest candle it follows new ones as they are appended. With the chart
/// focused, Left and Right move the crosshair (Shift: ten at a time), Home and
/// End jump to the ends, + and - zoom and 0 fits everything.
/// cui_candlestick(ui, "btc", candles, count, .labels = dates, .overlays = &sma, .overlay_count = 1);
pub const Candle = struct {
    open: f32 = 0,  // price at the start of the period
    high: f32 = 0,  // highest price in the period
    low: f32 = 0,  // lowest price in the period
    close: f32 = 0,  // price at the end of the period
    volume: f32 = 0,  // amount traded in the period, drawn as a bar under the candle; 0 for none
};

pub const CandlestickOpts = struct {
    width: Size = .fit,
    height: f32 = 0,  // default 320
    // `labels` (const char *const *): pointer field, reach it via zui.raw
    format: ?[]const u8 = null,  // prices, default "%.2f"
    overlays: []const Series = &.{},  // series drawn as lines over the candles; at most 4
    no_volume: bool = false,  // volume bars show when any candle has volume
    ohlc: bool = false,  // OHLC bars instead of candle bodies
    up: ?Color = null,  // default the success and danger colors
    down: ?Color = null,  // default the success and danger colors
};

pub const CanvasControlsOpts = struct {
    steps: []const f32 = &.{},  // zoom presets, ascending; `NULL`: 0.25 0.33 0.5 0.67 0.8 1 1.25 1.5 2 3 4
    content: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },  // the content's bounds in canvas points, for fit; empty: fit is only reported
    toggles: []const CanvasToggle = &.{},
    no_fit: bool = false,  // leaves out the fit button
    start_side: bool = false,  // the rail sits at the start edge (left, or right in a right-to-left interface)
};

/// C `cui_canvas_opts` — A zeroed options struct gives the same behavior as cui_canvas.
pub const CanvasOpts = struct {
    focusable: bool = false,  // Tab stop; with keyboard focus Enter or Space clicks it
    component_input: bool = false,  // requires focusable; the host routes keys instead of button activation
};

pub const CanvasResult = struct {
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    hovered: bool = false,
    pressed: bool = false,
    clicked: bool = false,
    mouse: Vec2 = .{ .x = 0, .y = 0 },
};

/// C `cui_canvas_toggle` — Canvas controls: a floating rail of zoom controls over the previous component,
/// at its end edge: zoom in, the zoom as a percentage (a click resets it to 100%),
/// zoom out, fit, and toggles of your own (grid, layers). It drives a pan and
/// zoom view, the same struct as the node editor's, so it works with a node
/// editor as it is; zooming keeps the middle of the component in place and
/// eases there. Zoom steps through presets (25% to 400% unless you pass your
/// own). Tab moves through the buttons.
/// static cui_node_view view;
/// static bool grid = true;
/// cui_canvas_toggle t[] = { { CUI_ICON_GRID_3X3, "Grid", &grid } };
/// cui_node_editor_end(ui);
/// cui_canvas_controls(ui, "zoom", &view, .content = bounds, .toggles = t, .toggle_count = 1);
pub const CanvasToggle = struct {
    icon: ?[]const u8 = null,
    label: ?[]const u8 = null,  // the tooltip
    // `on` (bool *): pointer field, reach it via zui.raw
};

/// C `cui_card_stack_opts` — Card stack: a deck where the top card can be flicked away left or right.
/// Build `count` cards; card 0 is the top. end returns -1 or 1 on the frame
/// the top card leaves (to the left or right), else 0.
pub const CardStackOpts = struct {
    width: Size = .fit,
    height: f32 = 0,
    visible: i32 = 0,  // cards of the deck that show at once, default 3
};

/// C `cui_carousel_opts` — ------------------------------------------------------------------------
/// Media
/// ------------------------------------------------------------------------
/// Carousel: slides that you swipe, drag, scroll or page with the arrows
/// and dots. Build every slide between begin and end:
/// cui_carousel(ui, "tour", 4, &index, .height = 220) {
/// for (int k = 0; k < 4; k++) cui_carousel_slide(ui) { ... }
/// }
pub const CarouselOpts = struct {
    height: f32 = 0,
    auto_advance: f32 = 0,  // seconds on a slide before it moves to the next, paused while hovered; 0 turns it off
    gap: f32 = 0,
    no_arrows: bool = false,  // hides the previous and next arrows that show on hover
    no_dots: bool = false,  // hides the row of page dots under the slides
    loop: bool = false,  // past the last slide comes the first again, and back from the first the last
};

pub const ChartAnnotation = struct {
    kind: AnnotationKind = .x,
    x: f64 = 0,  // in the chart's x units: x_min to x_max, or the point's index in a line or bar chart that sets neither
    y: f64 = 0,  // a value, in the chart's value units
    label: ?[]const u8 = null,  // first line, e.g. "PEAK 203 MG"; `NULL` for a line with no label
    detail: ?[]const u8 = null,  // second line, muted, e.g. "13:06"; `NULL` for none
    accent: bool = false,  // the line, dot and label in the accent color
    color: ?Color = null,  // the line, dot and label in this color, e.g. CUI_COLOR_SUCCESS; default: `accent` decides
};

pub const ChartOpts = struct {
    width: Size = .fit,
    height: f32 = 0,  // default 220
    // `labels` (const char *const *): pointer field, reach it via zui.raw
    label_count: i32 = 0,  // number of `labels`; 0 means one per data point
    area: bool = false,  // fill under lines
    no_grid: bool = false,
    no_legend: bool = false,
    stacked: bool = false,  // bars stack in one column; lines stack on the series before them
    smooth: bool = false,  // curved lines
    format: ?[]const u8 = null,  // value format for axis and tooltip, default "%.0f"
    min: f32 = 0,  // fixed y range when min != max
    max: f32 = 0,  // fixed y range when min != max
    annotations: []const ChartAnnotation = &.{},  // lines and points drawn over the chart (line and bar charts)
    dither: bool = false,  // line chart: every series filled with dots that thin out from its line to the bottom of its band (implies `area`); with `stacked`, bands never mix colors
    x_min: f64 = 0,  // line and bar charts: what the first and last point stand for, in annotation x units; equal: annotation x is the point's index
    x_max: f64 = 0,  // line and bar charts: what the first and last point stand for, in annotation x units; equal: annotation x is the point's index
};

/// C `cui_chat_opts` — ------------------------------------------------------------------------
/// Conversation
/// ------------------------------------------------------------------------
/// Chat message bubble. Consecutive messages from one person set grouped so
/// they stack tightly and show the avatar once.
pub const ChatOpts = struct {
    mine: bool = false,  // right aligned, accent bubble
    author: ?[]const u8 = null,  // name above the first bubble of a group
    time: ?[]const u8 = null,  // shown after the author's name; on your own messages after `status`
    status: ?[]const u8 = null,  // under your own last message, e.g. "Read"
    grouped: bool = false,  // continues the previous message
    last_in_group: bool = false,  // shows the avatar (others) and status (mine)
    avatar: usize = 0,  // picture for the sender's avatar instead of initials (other people's messages)
    markdown: bool = false,  // render the text with cui_markdown (compact, as wide as it needs)
    markdown_result: ?*c.cui_markdown_result = null,  // optional: links and task toggles the markdown reported
};

pub const ChecklistOpts = struct {
    title: ?[]const u8 = null,  // heading of the card, default "Get started"
    description: ?[]const u8 = null,
};

pub const ChipOpts = struct {
    icon: ?[]const u8 = null,
    disabled: bool = false,
};

/// C `cui_choice` — ------------------------------------------------------------------------
/// More components
/// ------------------------------------------------------------------------
/// Radio cards: larger selectable cards for choices that need a description
/// (plans, templates).
pub const Choice = struct {
    title: ?[]const u8 = null,  // the card's heading, in medium weight; wraps when long
    description: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    badge: ?[]const u8 = null,  // small accent badge beside the title, e.g. "Popular"; `NULL` for none
};

pub const CodeEditorOpts = struct {
    lang: ?[]const u8 = null,  // as cui_code_block: "c", "cpp", "js", "ts", "python", "rust", "go", "json", "shell", "sql"; "text" for none
    width: Size = .fit,  // default fill
    height: f32 = 0,  // default 320; negative fills the space
    size: f32 = 0,  // font size, default 13
    tab_size: i32 = 0,  // columns per indentation level, default 4
    use_tabs: bool = false,  // indent with tab characters instead of spaces
    read_only: bool = false,
    no_line_numbers: bool = false,  // hides the gutter of line numbers
    autofocus: bool = false,
    placeholder: ?[]const u8 = null,  // shown while the text is empty
    marks: []const TextMark = &.{},  // ranges to highlight (search results, regex matches), sorted by start
};

pub const CodeEditorResult = struct {
    changed: bool = false,  // the text changed this frame
    refused: bool = false,  // an edit did not fit in the capacity and was dropped
    focused: bool = false,  // the editor or its find bar has the keyboard
    cursor: i32 = 0,  // caret and the other end of the selection, byte offsets
    anchor: i32 = 0,  // caret and the other end of the selection, byte offsets
    line: i32 = 0,  // the caret, 1 based; columns count tabs to their stop
    column: i32 = 0,  // the caret, 1 based; columns count tabs to their stop
    line_count: i32 = 0,  // lines, and bytes of text
    length: i32 = 0,  // lines, and bytes of text
    bracket: i32 = 0,  // the bracket beside the caret and its partner, byte offsets, or -1
    bracket_match: i32 = 0,  // the bracket beside the caret and its partner, byte offsets, or -1
    find_matches: i32 = 0,  // with the find bar open: matches, and which one is selected (1 based, 0 none)
    find_index: i32 = 0,  // with the find bar open: matches, and which one is selected (1 based, 0 none)
};

/// C `cui_code_opts` — ------------------------------------------------------------------------
/// Code
/// ------------------------------------------------------------------------
/// Code block with syntax highlighting (lang: "c", "cpp", "js", "ts",
/// "python", "rust", "go", "json", "shell", "sql", or "text" for none), line numbers, a title bar and a
/// copy button. Long lines scroll sideways.
pub const CodeOpts = struct {
    lang: ?[]const u8 = null,  // "c", "cpp", "js", "ts", "python", "rust", "go", "json", "shell", "sql" or "text" (no colors); shown in the title bar
    title: ?[]const u8 = null,  // e.g. a file name
    line_numbers: bool = false,  // a column of line numbers on the left
    highlight_from: i32 = 0,  // 1 based line range to emphasize
    highlight_to: i32 = 0,  // 1 based line range to emphasize
    max_height: f32 = 0,  // scrolls beyond this, default none
    size: f32 = 0,  // font size, default 13
    no_header: bool = false,  // no title bar, even with a lang
};

/// C `cui_command` — ------------------------------------------------------------------------
/// Command palette (block)
/// ------------------------------------------------------------------------
pub const Command = struct {
    title: ?[]const u8 = null,  // the command's text in the list; what typing in the palette searches
    icon: ?[]const u8 = null,
    group: ?[]const u8 = null,  // heading above a run of commands with the same group, shown while the search is empty
    shortcut: ?[]const u8 = null,
};

pub const CommentOpts = struct {
    time: ?[]const u8 = null,  // muted text after the author's name, e.g. "2h ago"
    depth: i32 = 0,  // 0 for a top level comment; each level indents a reply 44 points under a connector line
    // `likes` (int *): pointer field, reach it via zui.raw
    // `liked` (bool *): pointer field, reach it via zui.raw
    edited: bool = false,  // adds "edited" after the time
    badge: ?[]const u8 = null,  // small badge after the author's name, e.g. "Author"
};

/// C `cui_commit` — ---- Commit graph ----
/// Version history: the branch lanes drawn beside each commit, newest first,
/// with its message, branch and tag names, author, date and short hash. Each
/// commit names its parents by row (parents come later in the array), so
/// merges and branches draw as lines between lanes. Only the rows in view are
/// built. Up and Down move the selection; Enter or a double-click activates.
pub const Commit = struct {
    hash: ?[]const u8 = null,  // the commit id; its first 7 characters are shown
    message: ?[]const u8 = null,  // the first line is shown
    author: ?[]const u8 = null,  // shown in its own column, which a narrow panel leaves out
    date: ?[]const u8 = null,  // already formatted: "2 hours ago", "Mar 3"
    refs: ?[]const u8 = null,  // "main, origin/main, tag: v1.2", may be NULL
    // `int parent[2]` (arr): unsupported field type, reach it via zui.raw
};

pub const CommitGraphOpts = struct {
    width: Size = .fit,
    height: f32 = 0,
    // `selected` (int *): pointer field, reach it via zui.raw
};

pub const CommitGraphResult = struct {
    clicked: i32 = 0,  // row clicked this frame, or -1
    activated: i32 = 0,  // row double-clicked or chosen with Enter this frame, or -1
    hovered: i32 = 0,  // row under the pointer, or -1
};

/// C `cui_compare_opts` — Before and after: drag the divider to compare two images. *pos is 0..1.
pub const CompareOpts = struct {
    width: Size = .fit,
    height: f32 = 0,
    before_label: ?[]const u8 = null,  // caption in the top left corner, default "Before"
    after_label: ?[]const u8 = null,  // caption in the top right corner, default "After"
    aspect: f32 = 0,  // the images' width / height: they are cropped to fill, never stretched
};

pub const ComposerOpts = struct {
    placeholder: ?[]const u8 = null,
    busy: bool = false,  // a reply is being generated: the send button becomes stop and Enter does not send
    // `attachments` (const char *const *): pointer field, reach it via zui.raw
    attachment_count: i32 = 0,  // number of `attachments`
    // `removed` (int *): pointer field, reach it via zui.raw
    models: []const Model = &.{},  // models for a picker beside the attach button; `NULL` for no picker
    // `model` (int *): pointer field, reach it via zui.raw
    max_lines: i32 = 0,  // default 8
    width: Size = .fit,
    mic: bool = false,  // a microphone button beside send, which returns `CUI_COMPOSER_RECORD`
    recording: bool = false,  // shows the recorder instead of the text: set it on `CUI_COMPOSER_RECORD`, clear it on cancel or send
    levels: []const f32 = &.{},  // the microphone's levels while recording (0..1, newest last), drawn as a scrolling voice waveform
    record_seconds: f32 = 0,  // how long the take is so far, shown beside the recording dot
};

/// C `cui_confirm_opts` — Two step destructive button: the first click morphs it into a confirm
/// state with a countdown, the second click confirms. Returns true once.
pub const ConfirmOpts = struct {
    confirm_label: ?[]const u8 = null,  // default "Click to confirm"
    icon: ?[]const u8 = null,
    variant: ButtonVariant = .default,  // resting look, default secondary
    size: ControlSize = .md,
    timeout: f32 = 0,  // seconds before it disarms, default 3
};

/// C `cui_confirm_popover_opts` — Confirm popover: a small question anchored to the previous component.
/// Open it with cui_popover_open(ui, id). A new Enter press can confirm it.
/// Returns true when confirmed.
pub const ConfirmPopoverOpts = struct {
    title: ?[]const u8 = null,  // the question, in medium weight at the top, e.g. "Delete this file?"
    description: ?[]const u8 = null,
    confirm_label: ?[]const u8 = null,  // default "Confirm"
    cancel_label: ?[]const u8 = null,  // default "Cancel"
    danger: bool = false,
    placement: Placement = .bottom_start,
};

/// C `cui_context_opts` — Context meter: a small ring of how full the context is; hover for a
/// breakdown. It turns amber past 80% and red past 95%.
pub const ContextOpts = struct {
    parts: []const VizItem = &.{},  // what fills the context (label, amount, color), for the breakdown on hover
    unit: ?[]const u8 = null,
};

/// C `cui_corners` — ------------------------------------------------------------------------
/// Custom drawing
/// ------------------------------------------------------------------------
pub const Corners = struct {
    tl: f32 = 0,
    tr: f32 = 0,
    br: f32 = 0,
    bl: f32 = 0,
};

/// C `cui_countdown_opts` — Countdown: days, hours, minutes and seconds as tiles whose digits roll.
pub const CountdownOpts = struct {
    hide_days: bool = false,  // no days tile; the hours tile counts the days in (49 hours, not 2 days and 1 hour)
    compact: bool = false,  // small tiles joined by colons, without the unit names under them
};

/// C `cui_counter_opts` — Odometer: a number whose digits roll to their new values.
pub const CounterOpts = struct {
    format: ?[]const u8 = null,
    size: f32 = 0,
    font: i32 = 0,  // default `CUI_FONT_DISPLAY`
    color: ?Color = null,
    group_thousands: bool = false,  // commas between thousands: 48210 shows as 48,210
};

/// C `cui_coverage_file` — ---- Coverage ----
/// Test coverage by folder and file: the files' paths make the tree, each
/// folder sums up what it holds, and folders fold. Line coverage shows as a
/// bar colored by thresholds, with branches and functions beside it. Click a
/// column's title to sort. Enter or a double-click activates a file. Narrow
/// panels show lines only.
pub const CoverageFile = struct {
    path: ?[]const u8 = null,  // "src/core/layout.c"
    lines: i32 = 0,  // lines that can be covered
    lines_hit: i32 = 0,  // lines the tests ran
    branches: i32 = 0,  // 0 branches: not measured
    branches_hit: i32 = 0,  // 0 branches: not measured
    functions: i32 = 0,  // functions in the file
    functions_hit: i32 = 0,  // functions the tests called
};

pub const CoverageOpts = struct {
    width: Size = .fit,
    height: f32 = 0,
    low: f32 = 0,
    high: f32 = 0,
};

pub const CoverageResult = struct {
    activated: i32 = 0,  // file opened this frame (Enter or a double-click), or -1
    lines: f32 = 0,  // percent of all lines covered
};

/// C `cui_cropper_opts` — Cropper: a crop rectangle over a picture, in image pixels. Drag inside to
/// move it, drag a corner or an edge to resize it; the outside dims and thirds
/// lines show while you drag. With it focused, the arrows move the crop (Shift
/// for 10 pixels). A zeroed crop starts as the largest centered rectangle of
/// the aspect.
pub const CropperOpts = struct {
    width: Size = .fit,  // default the width it gets and 360
    height: Size = .fit,  // default the width it gets and 360
    aspect: f32 = 0,  // width / height to keep, 0 for free
    round: bool = false,  // a round mask, for avatars (keeps a 1:1 aspect)
    min_size: f32 = 0,  // smallest side, image pixels; default 16
};

pub const CurveKey = struct {
    x: f32 = 0,  // position along the horizontal axis, in curve units (seconds in a timeline track)
    y: f32 = 0,  // the curve's value at the key
    in_dx: f32 = 0,  // handle toward the previous key, relative to the key (FREE)
    in_dy: f32 = 0,  // handle toward the previous key, relative to the key (FREE)
    out_dx: f32 = 0,  // handle toward the next key, relative to the key (FREE)
    out_dy: f32 = 0,  // handle toward the next key, relative to the key (FREE)
    mode: u8 = 0,  // cui_curve_mode
};

pub const CurveOpts = struct {
    x_min: f32 = 0,  // plotted range; both 0 = 0..1. Keys stay inside it
    x_max: f32 = 0,  // plotted range; both 0 = 0..1. Keys stay inside it
    y_min: f32 = 0,  // both 0 = 0..1; leave room above and below for overshoot
    y_max: f32 = 0,  // both 0 = 0..1; leave room above and below for overshoot
    width: Size = .fit,  // default fill
    height: f32 = 0,  // plot height, default 220
    x_format: ?[]const u8 = null,  // printf formats for labels and readouts, default from the grid step
    y_format: ?[]const u8 = null,  // printf formats for labels and readouts, default from the grid step
    x_label: ?[]const u8 = null,  // readout names, default "X" and "Y" (e.g. "Time", "Value")
    y_label: ?[]const u8 = null,  // readout names, default "X" and "Y" (e.g. "Time", "Value")
    // `selected` (int *): pointer field, reach it via zui.raw
    snap: bool = false,  // drags always snap to the grid (otherwise hold Shift)
    show_playhead: bool = false,  // a marker at x = playhead
    playhead: f32 = 0,  // x of the playhead marker, drawn when `show_playhead` is set
};

pub const CurveResult = struct {
    changed: bool = false,  // a key moved, a handle or mode changed, or a key was added or removed
    added: i32 = 0,  // index of the key added this frame, or -1
    removed: i32 = 0,  // index the removed key had, or -1
    selected: i32 = 0,  // the selected key, or -1
    hovered: bool = false,  // the pointer is over the plot:
    hover_x: f32 = 0,  // the x under it and the curve's value there
    hover_y: f32 = 0,  // the x under it and the curve's value there
};

pub const Date = struct {
    year: i32 = 0,
    month: i32 = 0,
    day: i32 = 0,
};

pub const DateOpts = struct {
    label: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    width: Size = .fit,
};

pub const DateRangeOpts = struct {
    label: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    width: Size = .fit,
    no_presets: bool = false,  // hides the list of preset ranges beside (or above) the calendar
};

pub const Diagnostic = struct {
    severity: Severity = .@"error",
    message: ?[]const u8 = null,  // the text of the row; the whole message shows on hover
    file: ?[]const u8 = null,  // groups the rows; NULL or "" groups as "No file"
    line: i32 = 0,  // 1 based; 0 leaves it out
    column: i32 = 0,  // 1 based; 0 leaves it out
    source: ?[]const u8 = null,  // "gcc", "clang-tidy"... (may be NULL)
    code: ?[]const u8 = null,  // "-Wunused-variable"... (may be NULL)
};

/// C `cui_dialog_opts` — ------------------------------------------------------------------------
/// Dialogs, sheets, toasts, alerts
/// ------------------------------------------------------------------------
pub const DialogOpts = struct {
    description: ?[]const u8 = null,
    width: f32 = 0,  // default 440
    no_close_button: bool = false,  // hides the x in the corner (Esc and a click outside still close it unless `persistent`)
    persistent: bool = false,  // clicking outside or Esc does not close
    draggable: bool = false,  // the header moves the dialog; it stays inside the window
    resizable: bool = false,  // the edges and corners resize it, down to a minimum size; the content is clipped when it no longer fits
};

/// C `cui_diff_hunk` — The same diff without a view. Old lines [old_start, old_start + old_count)
/// became new lines [new_start, new_start + new_count), 0 based; a pure
/// insertion has old_count 0 and goes before old line old_start. Writes up to
/// cap hunks and returns how many there are (-1 when out of memory). Lines end
/// at "\n"; a "\r" before it is part of the line ending. Allocates with malloc.
pub const DiffHunk = struct {
    old_start: i32 = 0,
    old_count: i32 = 0,
    new_start: i32 = 0,
    new_count: i32 = 0,
};

pub const DiffOpts = struct {
    mode: DiffMode = .split,
    language: ?[]const u8 = null,  // syntax colors, as cui_code_block: "c", "js", "python", ...
    old_title: ?[]const u8 = null,  // a header above the sides, e.g. file names, with the +/- summary
    new_title: ?[]const u8 = null,  // a header above the sides, e.g. file names, with the +/- summary
    // `current` (int *): pointer field, reach it via zui.raw
    context: i32 = 0,  // unchanged lines kept beside each change, default 3
    no_fold: bool = false,  // show every unchanged line
    ignore_eol: bool = false,  // "\r\n" equals "\n", and a missing final newline does not count
    split_min_width: f32 = 0,  // below this width split shows inline, default 560
    width: Size = .fit,  // default fill
    height: f32 = 0,  // default: the rows, up to 420; negative fills the space
    size: f32 = 0,  // font size, default 12
};

/// C `cui_diff_range` — Word marks between two versions of one line, as byte ranges (a length of -1
/// reads up to the terminator). Returns false when the lines have too little in
/// common for marks to help, or a line is very long (over 2000 bytes).
pub const DiffRange = struct {
    start: i32 = 0,
    length: i32 = 0,
};

pub const DiffResult = struct {
    added: i32 = 0,  // lines
    removed: i32 = 0,  // lines
    changes: i32 = 0,  // change blocks (hunks without context)
    current: i32 = 0,  // the selected change, -1 none
    current_changed: bool = false,  // this frame, by the keys, a click or .current
    mode: DiffMode = .split,  // what is shown: inline when split did not fit
    folds: i32 = 0,  // folded rows shown, and the unchanged lines they hide
    hidden: i32 = 0,  // folded rows shown, and the unchanged lines they hide
    recomputed: bool = false,  // a text changed and was diffed this frame
    approximate: bool = false,  // the search hit its limit: correct, maybe not the shortest
};

pub const DiffStats = struct {
    added: i32 = 0,
    removed: i32 = 0,
    hunks: i32 = 0,
    old_lines: i32 = 0,
    new_lines: i32 = 0,
    approximate: bool = false,
};

/// C `cui_doc_tab` — Document tabs: editor style tabs. Clicking selects (*selected is
/// updated), the x or a middle click asks to close, dragging reorders, and
/// the strip scrolls sideways when the tabs do not fit. A dirty tab shows a
/// dot that turns into the close button under the pointer. The selected tab
/// is filled with the surface color so it joins the content below; the strip
/// itself has no fill, like the other bars. Tabs keep their
/// state by title, so give two tabs with the same name a key: "main.c##src".
/// The component never removes or moves your tabs itself: it reports a close
/// or a move in the result and you apply it (selection already follows a
/// move). With keyboard focus on the strip, Left and Right select, Home and
/// End jump, Shift+Left/Right move the tab and Delete closes it. With
/// `shortcuts` set it also answers Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+PageUp/Down
/// and Ctrl+W (Cmd+W on macOS) from anywhere in the window.
pub const DocTab = struct {
    title: ?[]const u8 = null,  // the tab's text and its identity; add "##key" to tell two tabs with one name apart
    icon: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
    dirty: bool = false,  // unsaved changes: a dot in place of the x, which returns under the pointer
};

pub const DocTabsOpts = struct {
    shortcuts: bool = false,  // Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+PageUp/Down and Ctrl+W (Cmd+W on macOS) work from anywhere in the window
    no_close: bool = false,  // tabs have no x and cannot be closed (middle click, Delete and Ctrl+W do nothing)
    no_reorder: bool = false,  // tabs cannot be dragged or moved with Shift+Left/Right
};

pub const DocTabsResult = struct {
    changed: bool = false,  // *selected changed (click, keys or a move)
    close: i32 = 0,  // tab to close, or -1
    move_from: i32 = 0,  // move the tab at move_from to move_to, or -1
    move_to: i32 = 0,  // move the tab at move_from to move_to, or -1
};

pub const DockItemOpts = struct {
    color: ?Color = null,
    running: bool = false,  // a small dot under the icon
    badge: i32 = 0,  // a count badge on the icon ("99+" above 99); 0 for none
};

/// C `cui_dock_opts` — Dock: a row of icons that grow as the pointer passes, with labels and a
/// dot under the running ones. Each item returns true when clicked.
pub const DockOpts = struct {
    size: f32 = 0,
    magnify: f32 = 0,  // how much the icon under the pointer grows, default 1.55
};

/// C `cui_dock_panel_opts` — Returns true while the panel's content should be built; then call
/// cui_dock_panel_end.
pub const DockPanelOpts = struct {
    icon: ?[]const u8 = null,
    dirty: bool = false,  // unsaved changes: the panel's tab shows a dot in place of its x
};

/// C `cui_dockspace_opts` — ---- Docking ----
/// Dockspace: an IDE style workspace that lays out your panels in a tree of
/// resizable splits whose leaves hold one or more panels as document tabs.
/// Submit every panel each frame between cui_dockspace_begin and
/// cui_dockspace_end; the dockspace decides where it goes, and a panel's
/// content is built only while its tab is the one showing:
/// cui_dockspace_begin(ui, "main", .layout = "dock1 h0.25([Scene tree],[Viewport])");
/// if (cui_dock_panel_begin(ui, "Inspector", &show_inspector)) {
/// ...content...
/// cui_dock_panel_end(ui);
/// }
/// cui_dockspace_end(ui);
/// Drag a divider to resize. Drag a tab out of its strip to re-dock it: drop
/// targets appear over the leaf under the pointer (the middle stacks it as a
/// tab, the four sides split the leaf) and along the dockspace's outer edges,
/// with a tinted preview of where it will land; Esc cancels. A leaf that loses
/// its last panel collapses into its neighbour. The x on a tab writes
/// *open = false; set it back to true (from a View menu) and the panel
/// returns to its last place, or as a tab in the largest leaf. Pass NULL for a
/// panel that cannot be closed. Panels are identified by title ("Log (3)###log"
/// keeps the identity while the label changes), unique within a dockspace and
/// at most 63 bytes; a dockspace holds up to 48 panels. The id is global (it
/// ignores cui_push_id), so cui_dock_save and cui_dock_load can be called from
/// anywhere. Dockspaces lay out from the previous frame's size, so a panel
/// that appears or reopens shows from the next frame (one is requested).
/// After cui_dock_panel_begin, cui_last_rect gives the panel's tab.
pub const DockspaceOpts = struct {
    layout: ?[]const u8 = null,  // first run layout, in the cui_dock_save format
    width: Size = .fit,  // default fill
    height: Size = .fit,  // default fill
    min_panel_width: f32 = 0,  // default 120; splits stop here (and share what there is when too narrow)
    min_panel_height: f32 = 0,  // default 96
    shortcuts: bool = false,  // Ctrl+Tab, Ctrl+Shift+Tab and Ctrl+W act on the focused leaf
};

pub const DotChartOpts = struct {
    width: Size = .fit,
    height: f32 = 0,  // the plot and its labels, default 200
    x_min: f64 = 0,  // what the first and last sample stand for; equal: 0 to count - 1
    x_max: f64 = 0,  // what the first and last sample stand for; equal: 0 to count - 1
    x_units: AxisUnits = .number,
    x_format: ?[]const u8 = null,  // x labels with CUI_AXIS_NUMBER, default "%g"
    x_step: f64 = 0,  // spacing of the x labels in x units; 0 picks one that fits
    min: f32 = 0,  // value range when min != max; otherwise 0 to the largest stacked value
    max: f32 = 0,  // value range when min != max; otherwise 0 to the largest stacked value
    format: ?[]const u8 = null,  // values in the readout, default "%.0f"
    unit: ?[]const u8 = null,  // after values in the readout, e.g. "MG"
    pitch: f32 = 0,  // distance between dot centers in points, default 6
    no_grid: bool = false,  // hides the dim dots of the empty grid
    no_axis: bool = false,  // hides the x labels, e.g. when an event track under the chart has them
    no_readout: bool = false,  // no value label under the pointer
    annotations: []const ChartAnnotation = &.{},  // lines and points drawn over the dots
    // `x_label` (cui_axis_label_fn): unsupported field type, reach it via zui.raw
    // `x_label_user` (void *): pointer field, reach it via zui.raw
    // `value_label` (cui_axis_label_fn): unsupported field type, reach it via zui.raw
    // `value_label_user` (void *): pointer field, reach it via zui.raw
};

pub const DotChartResult = struct {
    hovered: i32 = 0,  // pointer or keyboard sample, middle on first keyboard activation, else -1
    x: f64 = 0,  // that sample's x, in x units
    value: f32 = 0,  // the stacked value there
    clicked: bool = false,  // the plot was clicked, or Enter was pressed on it, this frame: `x` is where
};

/// C `cui_dot_display_opts` — Dot-matrix display: text drawn with a 5 by 7 dot font, for clocks, counters and status
/// lines. Printable ASCII, the degree sign and the middle dot have glyphs; anything else is
/// a box. Unlit dots show dimly unless `no_dim` is set. In a box narrower than the text,
/// the dots shrink to fit, or with `marquee` the text scrolls.
pub const DotDisplayOpts = struct {
    pitch: f32 = 0,  // distance between dot centers in points, default 4
    color: ?Color = null,  // lit dots; unset: the foreground
    accent: bool = false,  // lit dots in the accent color
    no_dim: bool = false,  // hides the unlit dots
    marquee: bool = false,  // scrolls text that is wider than the box instead of shrinking it
    @"align": TextAlign = .start,  // where the text sits in a wider box, default start
    width: Size = .fit,  // default fit to the text
};

/// C `cui_dot_series` — Dot-matrix chart: values drawn as a grid of dots, lit up to each column's value and dim
/// above it. Several series stack, each in its own band, and an `accent` series is drawn in
/// the accent color: the item being edited, or the part that matters. The pointer, or the
/// arrow keys once it is focused, show a readout of the value under it, and a click returns
/// where it landed, so an app can add something there.
/// static float caffeine[96];             // one value every 15 minutes, 06:00 to 06:00
/// cui_dot_series s[] = { { caffeine, "Caffeine" } };
/// cui_dot_chart_result r = cui_dot_chart(ui, "mg", s, 1, 96, .x_min = 6, .x_max = 30,
/// .x_units = CUI_AXIS_HOURS, .unit = "mg");
/// Samples are spread evenly from x_min to x_max; a column between two samples uses the
/// value between them. With a dot chart and an event track of the same width stacked, their
/// x positions line up: both keep the same gutter on the right for the value labels.
pub const DotSeries = struct {
    // `values` (const float *): pointer field, reach it via zui.raw
    name: ?[]const u8 = null,  // names the series in the readout when there are several
    accent: bool = false,  // drawn in the accent color
};

/// C `cui_dropzone_opts` — Dropzone: drop files from the OS, or click to browse. Returns the number
/// of files dropped on it this frame (read them with cui_dropped_file), -1
/// when clicked (open a file dialog), 0 otherwise. accept filters by
/// extension, e.g. "png;jpg;pdf".
pub const DropzoneOpts = struct {
    title: ?[]const u8 = null,  // default "Drop files here"
    description: ?[]const u8 = null,  // default "or click to browse"
    icon: ?[]const u8 = null,
    accept: ?[]const u8 = null,  // extensions it takes, separated by semicolons, e.g. "png;jpg;pdf"; `NULL` takes any file
    height: f32 = 0,  // default 160
    width: Size = .fit,
    compact: bool = false,  // one row instead of a tall area
};

/// C `cui_emoji_picker_opts` — Emoji picker: search, groups with tabs, recent emoji, skin tones and a preview with the
/// name. Returns the emoji picked this frame (UTF-8, valid until the next frame) or NULL.
/// Put it in a popover to open it from a button.
pub const EmojiPickerOpts = struct {
    width: Size = .fit,  // default up to 360
    height: f32 = 0,  // the grid; default 280
    size: f32 = 0,  // emoji size; default 26
    // `recent` (char *): pointer field, reach it via zui.raw
    recent_cap: usize = 0,  // size of the `recent` buffer in bytes; it holds the recent emoji newest first, space separated
    // `tone` (int *): pointer field, reach it via zui.raw
    placeholder: ?[]const u8 = null,  // "Search emoji"
    empty_text: ?[]const u8 = null,  // "No emoji found"
    hint: ?[]const u8 = null,  // the preview with nothing to show: "Pick an emoji"
    // `group_names` (const char *const *): pointer field, reach it via zui.raw
    no_search: bool = false,  // hides the search field
    no_preview: bool = false,  // hides the row at the bottom that shows the hovered emoji and its name
    no_tone: bool = false,  // hides the skin tone button
};

pub const EmptyOpts = struct {
    icon: ?[]const u8 = null,
    description: ?[]const u8 = null,
    action: ?[]const u8 = null,  // label of a button under the text; the call returns true when it is clicked
};

/// C `cui_event_track_opts` — Event track: moments on a time axis, as dots you drag along it. A click on an empty
/// spot adds an event there and a double-click on one removes it. You own the array: the
/// track keeps it sorted, edits it in place and never grows it past `capacity`.
/// static double cups[8] = { 8, 11, 12.25 };   // hours
/// static int ncups = 3, sel = -1;
/// cui_event_track(ui, "cups", cups, &ncups, 8, 6, 30, .step = 0.25,
/// .units = CUI_AXIS_HOURS, .selected = &sel);
/// Keys, once it is focused: Left and Right move the selected event a step (Shift: ten),
/// Up and Down select the previous and next event, Enter adds one a step after the selected
/// one, Delete or Backspace removes it, and Esc clears the selection.
pub const EventTrackOpts = struct {
    width: Size = .fit,
    step: f64 = 0,  // events snap to multiples of this from `min`; 0 does not snap
    units: AxisUnits = .number,
    format: ?[]const u8 = null,  // labels with CUI_AXIS_NUMBER, default "%g"
    label_step: f64 = 0,  // spacing of the axis labels; 0 picks one that fits
    // `selected` (int *): pointer field, reach it via zui.raw
    no_add: bool = false,  // clicks and Enter do not add events
    no_remove: bool = false,  // double-clicks and Delete do not remove events
    no_axis: bool = false,  // hides the axis labels under the dots
    // `label` (cui_axis_label_fn): unsupported field type, reach it via zui.raw
    // `label_user` (void *): pointer field, reach it via zui.raw
};

pub const EventTrackResult = struct {
    changed: bool = false,  // an event was moved, added or removed this frame
    added: i32 = 0,  // index of the event added this frame, or -1
    removed: i32 = 0,  // index the removed event had, or -1
    selected: i32 = 0,  // the selected event after this frame, or -1
    dragging: bool = false,  // an event is being dragged
};

/// C `cui_expandable_card_opts` — Expandable card: a card whose header opens a body with a height spring.
pub const ExpandableCardOpts = struct {
    description: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    badge: ?[]const u8 = null,  // small badge in the header before the chevron, colored by `badge_tone`; `NULL` for none
    badge_tone: Tone = .neutral,
};

/// C `cui_expandable_text_opts` — Text clamped to a few lines with a fade and Show more / Show less.
pub const ExpandableTextOpts = struct {
    lines: i32 = 0,  // lines shown while collapsed, default 3
    size: f32 = 0,
    color: ?Color = null,
    fade_to: ?Color = null,  // color the last line fades into; set it to the surface behind the text, default the background
};

pub const FaderOpts = struct {
    label: ?[]const u8 = null,  // under a vertical fader, before a horizontal one; the id when NULL
    format: ?[]const u8 = null,  // default "%.1f"
    unit: ?[]const u8 = null,
    length: f32 = 0,  // track length, default 160
    horizontal: bool = false,  // the track runs left to right, with the label before it, instead of bottom to top
    step: f32 = 0,
    reset: f32 = 0,  // double-click value, default 0 (clamped to the range)
    ticks: []const f32 = &.{},  // values to mark and label beside the track, e.g. dB marks; at most 32
    // `meter` (const float *): pointer field, reach it via zui.raw
    meter_channels: i32 = 0,  // entries in `meter`, up to 8; a dB fader's range sets the meter's scale
    hide_value: bool = false,
    disabled: bool = false,
};

pub const FeatureFlagsOpts = struct {
    width: Size = .fit,
    height: f32 = 0,
};

pub const FeatureFlagsResult = struct {
    flag: i32 = 0,
    env: i32 = 0,
};

pub const FileBrowserOpts = struct {
    width: Size = .fit,  // default fill and 380
    height: Size = .fit,  // default fill and 380
    filter: ?[]const u8 = null,  // patterns that files must match, e.g. "*.png;*.jpg"; folders always show
    folders_only: bool = false,  // lists folders and leaves the files out
    hidden: bool = false,  // show hidden files
    no_places: bool = false,  // the sidebar of places
    // `places` (const char *const *): pointer field, reach it via zui.raw
    place_count: i32 = 0,  // entries in `places`; when places is NULL: home, desktop, documents, downloads and native drives/mounts
    // `list` (cui_file_list_fn): unsupported field type, reach it via zui.raw
    // `list_user` (void *): pointer field, reach it via zui.raw
    max_entries: i32 = 0,  // default 20,000
};

pub const FileBrowserResult = struct {
    picked: ?[]const u8 = null,  // a file double-clicked or Entered, as a full path; valid this frame
    selected: ?[]const u8 = null,  // the selected entry as a full path, or NULL; valid this frame
    navigated: bool = false,  // the folder in *path changed
    @"error": bool = false,  // the folder could not be read
};

pub const FilePickerOpts = struct {
    title: ?[]const u8 = null,  // default "Open", "Save" or "Choose a folder"
    save: bool = false,  // a name field and Save
    folders: bool = false,  // choose a folder
    start: ?[]const u8 = null,  // the folder to start in, default the current directory
    name: ?[]const u8 = null,  // save: the name to start with
    filter: ?[]const u8 = null,  // e.g. "*.png;*.jpg"
    filter_label: ?[]const u8 = null,  // e.g. "Images"
    // `list` (cui_file_list_fn): unsupported field type, reach it via zui.raw
    // `list_user` (void *): pointer field, reach it via zui.raw
};

/// C `cui_filter_field` — Filter bar: a search field, a chip per active filter (click it to pick
/// values) and "+ Filter" to add one. selected[i] is a bit mask of the
/// chosen options of fields[i]. Returns true when anything changed.
pub const FilterField = struct {
    name: ?[]const u8 = null,  // the field's name, on its chip and in the "+ Filter" menu
    icon: ?[]const u8 = null,
    // `options` (const char *const *): pointer field, reach it via zui.raw
    option_count: i32 = 0,  // number of `options`
};

pub const FlameOpts = struct {
    width: Size = .fit,  // default fill
    height: f32 = 0,  // default: fits the rows (up to 360)
    row_height: f32 = 0,  // default 20
    min_range: f64 = 0,  // deepest zoom in seconds, default 1e-8
};

pub const FlameResult = struct {
    selection_changed: bool = false,  // *selected changed (click or keys)
    view_changed: bool = false,  // *view changed (zoom, pan, fit, animation)
    hovered: i32 = 0,  // span under the pointer, or -1
    zoomed: i32 = 0,  // span zoomed to this frame (double-click, Enter), or -1
};

/// C `cui_flame_span` — ---- Flame graph ----
/// Flame graph / profiler timeline: time runs left to right, call depth top to
/// bottom (row d holds the spans at depth d). You own the spans, the view and
/// the selection; the component pans and zooms *view and writes *selected.
/// static cui_flame_view view;              (zeroed: fits every span)
/// static int selected = -1;
/// cui_flame_sort(spans, count);            (once, after recording)
/// cui_flame_result r = cui_flame_graph(ui, "profile", spans, count, &view, &selected);
/// if (r.selection_changed && selected >= 0) show_details(&spans[selected]);
/// Times are seconds (any origin; the ruler counts from the earliest span).
/// Spans must be sorted by depth, then start (cui_flame_sort does it), and
/// spans of one depth must not overlap: a child lies within its parent. Only
/// the spans in view are visited (binary searches per row), so captures of
/// 100k spans stay fast; spans thinner than a pixel merge into a neutral run.
/// The spans need to be valid only during the call. color_key picks the color
/// (0: hashed from the name), so the same function keeps its color.
/// Mouse: the wheel zooms around the pointer, Shift+wheel or a sideways scroll
/// pans, drag pans (sideways and, for deep stacks, up and down). Click selects
/// a span (empty space clears), double-click zooms to fit it (on empty space:
/// fits everything). Hover shows a tooltip: name, duration and its share of
/// the parent (or of the view, at depth 0).
/// Keys when focused: Left/Right move to the previous/next span in the row,
/// Up to the parent, Down to the first child (the view follows); Shift+Left/
/// Right pan; + and - zoom; Enter or Space zooms to the selection; Home or F
/// fits everything; Esc fits everything, or when already fitted clears the
/// selection. Zooming to a span or fitting animates (snaps with reduced
/// motion). Not included: an aggregated (merged call tree) flame graph mode.
pub const FlameSpan = struct {
    name: ?[]const u8 = null,  // drawn in the span when it fits, and in its tooltip
    start: f64 = 0,  // seconds, end >= start
    end: f64 = 0,  // seconds, end >= start
    depth: i32 = 0,  // row, 0 = top
    color_key: u32 = 0,  // 0: hashed from name
};

pub const FormatBarOpts = struct {
    styles: []const TextStyle = &.{},  // `NULL`: Header, Title, Subtitle and Normal text
    colors: []const Tone = &.{},  // the color grid; `NULL`: eight tones, the text color first
    footer: ?[]const u8 = null,  // a muted line under the styles, default "Text options"; "" leaves it out
    footer_keys: ?[]const u8 = null,  // keycaps beside it, default "Ctrl Alt 0" ("" for none); a hint, the shortcut is yours
    delete_question: ?[]const u8 = null,  // default "Delete this text?"
    no_delete: bool = false,  // leaves out the delete button
    no_more: bool = false,  // leaves out the "..." button
};

/// C `cui_funnel_opts` — Funnel: stages narrowing by value, with the conversion between them.
pub const FunnelOpts = struct {
    width: Size = .fit,
    height: f32 = 0,
    format: ?[]const u8 = null,
    color: ?Color = null,
};

pub const GanttOpts = struct {
    day_width: f32 = 0,  // points per day, default 30
    row_height: f32 = 0,  // points per task row, default 40
    height: Size = .fit,
    today: i32 = 0,  // day to mark as today, counted from `origin`, with an accent line and a "Today" chip; 0 marks none
    read_only: bool = false,
};

/// C `cui_gauge_band` — Radial gauge: one value as a large number on an arc, for dashboards (load, speed,
/// temperature, a score against a goal). Three styles:
/// CUI_GAUGE_SEGMENTS  a ring of short segments, lit in each band's tone up to the value,
/// with the current band's name as a chip under the label
/// CUI_GAUGE_ARC       a track and a value arc with round caps, min and max at the ends,
/// and a marker at `target`
/// CUI_GAUGE_RING      a slim full ring from the top, with `detail` under it
/// CUI_GAUGE_AUTO (the default) picks the segments when `bands` are given and the arc
/// otherwise. The arc fills to new values with a spring.
/// static const cui_gauge_band bands[] = { { 60, CUI_TONE_SUCCESS }, { 85, CUI_TONE_WARNING, "Elevated" }, { 100, CUI_TONE_DANGER, "High" } };
/// cui_radial_gauge(ui, "cpu", load, 0, 100, .unit = "%", .label = "CPU load", .bands = bands, .band_count = 3);
/// cui_radial_gauge(ui, "disk", 38, 0, 100, .unit = "%", .label = "Disk", .style = CUI_GAUGE_RING, .detail = "190 of 500 GB");
pub const GaugeBand = struct {
    to: f32 = 0,  // the band runs from the band before (or min) up to here
    tone: Tone = .neutral,  // its color
    name: ?[]const u8 = null,  // shown as a chip while the value is in this band (segments style); `NULL` for none
};

pub const GradientOpts = struct {
    width: Size = .fit,  // default fill
    height: f32 = 0,  // ramp height, default 28
    // `selected` (int *): pointer field, reach it via zui.raw
};

pub const GradientResult = struct {
    changed: bool = false,  // a stop moved, changed color, or was added or removed
    added: i32 = 0,  // index of the stop added this frame, or -1
    removed: i32 = 0,  // index the removed stop had, or -1
    selected: i32 = 0,  // the selected stop
};

pub const GradientSliderOpts = struct {
    track: GradientTrack = .hue,  // the built-in track, default the hue wheel; ignored when `stops` is set
    stops: []const GradientStop = &.{},  // your own track, positions 0..1
    color: ?Color = null,  // CUI_GRADIENT_OPACITY: the color it fades in; unset: the accent
    // `color_out` (cui_color *): pointer field, reach it via zui.raw
    step: f32 = 0,  // snap to multiples of step from min; 0 = continuous
    format: ?[]const u8 = null,  // printf format for the value; default "%.0f°" for hue, "%.0f K" for temperature, a percent of the range for opacity, "%.0f" for stops
    value: ?[]const u8 = null,  // text at the right of the label instead of the formatted value
    swatch: bool = false,  // a dot in the color under the thumb after the track
    tool: ?[]const u8 = null,  // icon of a button after the track, e.g. a picker; a click returns CUI_WELL_ACTION
    tool_tooltip: ?[]const u8 = null,  // names the tool button
    tool_on: bool = false,  // shows the tool button pressed, e.g. while picking
    plain: bool = false,  // no well around it
    disabled: bool = false,
};

/// C `cui_gradient_stop` — Gradient editor: a color ramp over a checkerboard (so alpha shows) with
/// the stops underneath. You own the stops; the editor edits them in place
/// and keeps them sorted by position. Drag a stop to move it (it may pass its
/// neighbours), drag it off the ramp or press Delete to remove it (never
/// fewer than two), click the ramp or the empty track to add a stop with the
/// color found there. Double click a stop (or Enter on a focused one) to open
/// the color picker; the row under the ramp shows the selected stop's color,
/// location and opacity. Stops are focusable: Tab moves through them, Left and
/// Right nudge (Shift for fine steps).
pub const GradientStop = struct {
    pos: f32 = 0,  // position along the ramp, 0..1
    color: ?Color = null,
};

/// C `cui_gradient_text_opts` — Text painted with a gradient from one color to another; animate makes it drift.
pub const GradientTextOpts = struct {
    font: i32 = 0,  // default `CUI_FONT_BODY` (0)
    size: f32 = 0,
    from: ?Color = null,  // color at the left edge; default the accent, or the text color under the neutral accent
    to: ?Color = null,  // color at the right edge, default `from` blended toward the foreground color
    animate: bool = false,  // the gradient drifts along the text
    width: Size = .fit,
};

pub const GraphEdge = struct {
    from: i32 = 0,  // index of the node the arrow starts at
    to: i32 = 0,  // index of the node the arrow points to
};

/// C `cui_graph_node` — ---- Dependency graph ----
/// Nodes and directed edges laid out in layers (each edge points to a later
/// layer, cycles are broken), for build targets, packages, services or call
/// graphs. The layout is computed when the graph changes. Wheel zooms, drag
/// pans, click selects; hovering a node lights up what it depends on and what
/// depends on it. F fits the graph.
pub const GraphNode = struct {
    label: ?[]const u8 = null,
    detail: ?[]const u8 = null,  // smaller second line under the label, e.g. the node's kind; `NULL` for none
    tone: Tone = .neutral,
};

pub const GraphOpts = struct {
    width: Size = .fit,
    height: f32 = 0,
    top_down: bool = false,  // layers stack from top to bottom instead of running side by side
    // `selected` (int *): pointer field, reach it via zui.raw
};

pub const GraphResult = struct {
    clicked: i32 = 0,  // node clicked this frame, or -1
    activated: i32 = 0,  // node double-clicked or chosen with Enter this frame, or -1
    hovered: i32 = 0,  // node under the pointer, or -1
};

/// C `cui_grid_column` — ------------------------------------------------------------------------
/// Data grid
/// ------------------------------------------------------------------------
/// A virtualized table for large data: sticky header, resizable and sortable
/// columns, checkbox selection (click, Ctrl+click, Shift+click, Ctrl+A),
/// keyboard navigation and editable cells. Build only the rows in
/// [first, last):
/// int first, last;
/// if (cui_data_grid_begin(ui, "people", cols, 4, count, &first, &last, .selected = sel)) {
/// for (int r = first; r < last; r++) {
/// cui_data_grid_row(ui, r);
/// cui_data_grid_cell_text(ui, people[r].name);
/// ...
/// }
/// cui_data_grid_end(ui);
/// }
pub const GridColumn = struct {
    title: ?[]const u8 = null,  // text of the column's header
    width: f32 = 0,  // initial width in points, default 150
    @"align": TextAlign = .start,
    sortable: bool = false,
    fixed: bool = false,  // not resizable
    priority: i32 = 0,  // 0 always shown; when the grid is too narrow, columns with a priority hide, the highest number first, until the rest fit
};

pub const GridOpts = struct {
    width: Size = .fit,  // default fill
    height: Size = .fit,  // default fill
    row_height: f32 = 0,  // default 40
    // `selected` (bool *): pointer field, reach it via zui.raw
    sort: ?*c.cui_table_sort = null,  // optional; a click on a sortable header updates it and the header shows its arrow. Sort the rows yourself
    striped: bool = false,
    // `cursor` (int *): pointer field, reach it via zui.raw
    hide_checkboxes: bool = false,  // with selected: rows still select (click, Shift, Ctrl) but no checkbox column
    // `anchor` (int *): pointer field, reach it via zui.raw
};

/// C `cui_heatmap_opts` — ------------------------------------------------------------------------
/// More charts
/// ------------------------------------------------------------------------
/// Every chart below has a hover tooltip, animates in once, follows the theme
/// and returns the index of the mark that was clicked, or -1. Colors default
/// to the series palette; numbers use `format` (printf, default compact).
/// Heatmap: a rows x cols matrix (values[row * cols + col]) in five steps from
/// the empty surface to the accent, with the range and a Less / More key below.
pub const HeatmapOpts = struct {
    // `row_labels` (const char *const *): pointer field, reach it via zui.raw
    // `col_labels` (const char *const *): pointer field, reach it via zui.raw
    cell: f32 = 0,  // cell size, default fits the width
    min: f32 = 0,  // value range, default the data's
    max: f32 = 0,  // value range, default the data's
    color: ?Color = null,  // the top step, default the accent; the steps mix toward it from the empty surface
    format: ?[]const u8 = null,
    width: Size = .fit,
};

/// C `cui_hex_range` — ---- Hex viewer ----
/// Hex viewer: offsets, bytes in hex and the same bytes as ASCII, in the code
/// font, for binary tools, emulators and debuggers. You own the bytes (they
/// are read during the call, never kept) and, optionally, the selection:
/// static cui_hex_selection sel;
/// static const cui_hex_range marks[] = {
/// { 0, 8, CUI_TONE_INFO, "PNG signature" },
/// { 8, 25, CUI_TONE_VIOLET, "IHDR chunk" },
/// };
/// cui_hex_result r = cui_hex_view(ui, "hex", file, file_size, &sel,
/// .base = 0x80000000u, .ranges = marks, .range_count = 2);
/// if (r.selection_changed) show_inspector(file + sel.start, sel.length);
/// Only the rows in view are built, so a file of many megabytes scrolls as
/// fast as a short one (the scroll position is kept in rows, so very large
/// files stay exact). Rows hold 16 bytes (8 or 32 with bytes_per_row) with a
/// small gap every 8. When the view is too narrow it drops to fewer bytes per
/// row (down to 8), then hides the ASCII column, then tightens its margins,
/// then shows 4 bytes per row; it never scrolls sideways. Hovering a byte marks it in both columns, and a
/// byte inside a highlighted range shows the range's label as a tooltip.
/// Click a byte to select it, drag or Shift+click for a range. With the view
/// focused: arrows move the cursor byte, Shift+arrows extend, Page Up/Down
/// move by a screen, Home/End go to the start/end of the row and Ctrl+Home/End
/// to the start/end of the data, Ctrl+A selects everything, Esc clears the
/// selection. Ctrl+C copies the selection as hex ("89 50 4E 47") and
/// Ctrl+Shift+C as ASCII (other bytes as '.'), up to 4 MiB of bytes.
/// With .edit set the view is editable: typing hex digits overwrites the byte
/// at the cursor, high digit first, then moves on. Edits never change the size.
pub const HexRange = struct {
    offset: usize = 0,
    length: usize = 0,
    tone: Tone = .neutral,  // tints the range's background
    label: ?[]const u8 = null,  // tooltip for the range; may be NULL
};

pub const HexResult = struct {
    selection: HexSelection = .{},  // after this frame (the same as *sel when you pass one)
    selection_changed: bool = false,  // by the pointer, the keys or cui_hex_view_goto
    edited: bool = false,  // bytes in .edit were overwritten this frame
    edit_offset: usize = 0,  // with `edited`: offset of the first byte overwritten this frame
    edit_length: usize = 0,  // with `edited`: bytes from `edit_offset` up to the last one overwritten
    hovered: i64 = 0,  // byte under the pointer, or -1
    copied: bool = false,  // Ctrl+C or Ctrl+Shift+C put the selection on the clipboard
};

/// C `cui_hex_selection` — The selected bytes. length 0 means nothing is selected; cursor is the byte
/// the keys move from and is one end of a selection. Set it yourself to select
/// from code.
pub const HexSelection = struct {
    start: usize = 0,  // offset of the first selected byte
    length: usize = 0,  // bytes selected; 0 means nothing is selected
    cursor: usize = 0,  // the byte the keys move from; one end of the selection
};

pub const HexViewOpts = struct {
    width: Size = .fit,  // default fill
    height: f32 = 0,  // default: the rows, up to 320; negative fills the space
    base: u64 = 0,  // address shown for byte 0 in the offset column
    bytes_per_row: i32 = 0,  // 8, 16 (default) or 32
    ranges: []const HexRange = &.{},  // byte ranges to highlight, each with a tone and a tooltip label
    // `edit` (uint8_t *): pointer field, reach it via zui.raw
    no_ascii: bool = false,  // hide the ASCII column
    no_header: bool = false,  // hide the column header (00 01 .. 0F)
    size: f32 = 0,  // font size, default 12
};

/// C `cui_histogram_opts` — Range slider over a histogram of the data it filters.
pub const HistogramOpts = struct {
    height: f32 = 0,
    format: ?[]const u8 = null,
};

/// C `cui_histogram_series` — ---- Time histogram ----
/// Event counts over time, stacked by series (log levels, status classes), as
/// above a log search. Drag across it to select a time range, click to clear.
/// Hover a bar for its time and counts. Times are Unix seconds.
pub const HistogramSeries = struct {
    name: ?[]const u8 = null,  // shown in the legend and in the hover tooltip
    // `counts` (const float *): pointer field, reach it via zui.raw
    tone: Tone = .neutral,
};

/// C `cui_hold_opts` — Hold to confirm: a destructive action that fills while held and fires when
/// full. Returns true once.
pub const HoldOpts = struct {
    duration: f32 = 0,  // seconds the button must be held before it fires, default 1.2
    icon: ?[]const u8 = null,
    variant: ButtonVariant = .default,
};

/// C `cui_hover_card_opts` — ------------------------------------------------------------------------
/// Disclosure
/// ------------------------------------------------------------------------
/// Hover card: rich content that appears when the pointer rests on the
/// previous component, and stays while the pointer is over either.
pub const HoverCardOpts = struct {
    placement: Placement = .bottom_start,
    width: f32 = 0,
    delay: f32 = 0,  // seconds the pointer must rest on the component before the card shows, default 0.45
};

pub const ImageOpts = struct {
    width: Size = .fit,
    height: Size = .fit,
    radius: f32 = 0,  // corner radius in points
    tint: ?Color = null,  // color the image is multiplied by; unset draws it as it is
};

pub const ImageViewerOpts = struct {
    width: Size = .fit,  // default the width it gets and 360
    height: Size = .fit,  // default the width it gets and 360
    max_zoom: f32 = 0,  // default 16 (1600%)
    no_toolbar: bool = false,  // the zoom buttons and percentage in the corner
    checkerboard: bool = false,  // a grid behind transparent images
};

/// C `cui_inline_edit_opts` — ------------------------------------------------------------------------
/// More inputs
/// ------------------------------------------------------------------------
/// Inline edit: text that turns into a field in place. Click (or Enter when
/// focused) to edit, Enter or clicking away saves, Esc cancels. Returns
/// CUI_CHANGED when an edit is committed.
pub const InlineEditOpts = struct {
    font: i32 = 0,  // font of the text and of the field, default `CUI_FONT_MEDIUM`
    size: f32 = 0,
    placeholder: ?[]const u8 = null,
    width: Size = .fit,
};

pub const InputEvent = struct {
    kind: InputEventKind = .mouse_move,
    position: Vec2 = .{ .x = 0, .y = 0 },  // mouse move only
    delta: Vec2 = .{ .x = 0, .y = 0 },  // scroll only, same units as cui_input_scroll
    button: MouseButton = .left,  // mouse button only
    key: Key = .none,  // key only
    mods: i32 = 0,  // key only; track modifier-only events too
    down: bool = false,  // key/button only
    focused: bool = false,  // window focus only
    text: ?[]const u8 = null,  // text only; NUL terminated, borrowed
};

/// C `cui_inspector_opts` — Tool panels: property inspector, log console
/// ------------------------------------------------------------------------
/// Property inspector: labelled rows in folding groups, a label column on the
/// left (drag the line between the columns to resize it) and an editor on the
/// right. Every row returns true when its value changed. Groups end at the
/// next group or at cui_inspector_end.
/// static bool transform_open = true;
/// if (cui_inspector_begin(ui, "props")) {
/// if (cui_inspector_group(ui, "Transform", &transform_open)) {
/// cui_prop_vec3(ui, "Position", pos);
/// cui_prop_float(ui, "Scale", &scale, .min = 0.01f, .max = 100, .step = 0.01f);
/// }
/// cui_inspector_end(ui);
/// }
/// Number rows are scrub fields: drag the field or its label sideways (Shift
/// for fine steps), click to type, arrows step. Rows can also be used outside
/// an inspector.
pub const InspectorOpts = struct {
    width: Size = .fit,  // default fill
    label_width: f32 = 0,  // initial label column in points, default 38% of the width
};

/// C `cui_json_opts` — JSON viewer: a collapsible tree with typed colors and item counts.
/// Returns false when the text is not valid JSON (and shows the error).
pub const JsonOpts = struct {
    expand_depth: i32 = 0,  // levels of the tree that start open, default 2
    max_height: f32 = 0,  // points; taller content scrolls. 0 shows everything
};

pub const KanbanColumnOpts = struct {
    dot: ?Color = null,  // a small dot of this color before the title; unset for none
    limit: i32 = 0,  // work in progress limit: the count reads "3 / 5" and turns red above it; 0 for none
    width: f32 = 0,
};

/// C `cui_key_combo` — Shortcut recorder: click and press a key combination to record it.
/// Backspace clears, Esc cancels. Returns true when the combination changed.
/// cui_shortcut_label formats a combination ("Ctrl Shift K").
pub const KeyCombo = struct {
    mods: i32 = 0,
    key: Key = .none,
};

/// C `cui_keymap_binding` — ---- Keymap ----
/// A keyboard with your shortcuts on it: each bound key shows its action and
/// the color of its category, for the modifiers chosen above it. Keys bound
/// twice are marked as conflicts. Hover a key for every binding on it; click it
/// to get the key (to rebind it). The keyboard keeps its own layout in a
/// right-to-left interface and scales to the width it gets.
pub const KeymapBinding = struct {
    combo: KeyCombo = .{},  // the modifiers and key the action is bound to
    action: ?[]const u8 = null,  // name of the action, shown on the key and in its tooltip
    category: i32 = 0,  // index into the categories, colors the key
};

pub const KeymapOpts = struct {
    width: Size = .fit,
    // `categories` (const char *const *): pointer field, reach it via zui.raw
    category_count: i32 = 0,  // number of `categories`
    // `mods` (int *): pointer field, reach it via zui.raw
    no_function_row: bool = false,  // leaves out the row of function keys
};

pub const KeymapResult = struct {
    clicked: Key = .none,  // key clicked this frame, or `CUI_KEY_NONE`
    conflicts: i32 = 0,  // bindings that repeat a combination another binding already uses
};

/// C `cui_knob_opts` — Knob, fader and level meter: the controls of audio, synth and mixer panels.
/// cui_knob(ui, "Cutoff", &cutoff, 20, 20000, .format = "%.0f", .unit = "Hz", .reset = 1000);
/// cui_knob(ui, "Pan", &pan, -1, 1, .bipolar = true, .format = "%+.2f");
/// cui_fader(ui, "Vocals", &gain_db, -60, 6, .unit = "dB", .ticks = marks, .tick_count = 6);
/// cui_level_meter(ui, "vu", peaks, 2, .scale = true);   // peaks: linear sample peaks, 1.0 = 0 dBFS
/// Knobs turn by dragging up and down (Shift for fine steps); the wheel turns a
/// focused knob or fader. Double-click, Delete or Backspace go back to `reset`
/// (0 unless set, kept within the range: 0 dB, the middle of -1..1, or the
/// minimum of 20..20000). Arrows step, Shift+arrows and Page Up/Down step ten
/// times as far, Home and End go to the ends.
pub const KnobOpts = struct {
    label: ?[]const u8 = null,  // under the knob; the id when NULL
    format: ?[]const u8 = null,  // printf format for the value, default "%.0f"
    unit: ?[]const u8 = null,  // after the value, e.g. "Hz" or "dB"
    size: f32 = 0,  // diameter, default 48
    step: f32 = 0,  // 0 = continuous (keys move 1% of the range)
    reset: f32 = 0,  // double-click value, default 0 (clamped to the range)
    bipolar: bool = false,  // the arc grows from the middle: pan, EQ gain
    log_scale: bool = false,  // equal turns multiply the value: frequency, time (min > 0)
    hide_value: bool = false,
    disabled: bool = false,
    color: ?Color = null,  // the value arc, default the control color
};

pub const KvEditorOpts = struct {
    key_placeholder: ?[]const u8 = null,  // default "Key"
    value_placeholder: ?[]const u8 = null,  // default "Value"
    no_toggles: bool = false,  // no checkboxes: every pair is on
    no_secrets: bool = false,  // no eye button
    read_only: bool = false,
    width: Size = .fit,  // default fill
};

/// C `cui_kv_pair` — ------------------------------------------------------------------------
/// Developer tools
/// ------------------------------------------------------------------------
/// ---- Key-value editor ----
/// Rows of key = value pairs: HTTP headers, query parameters, environment
/// variables. You own the array and it is edited in place. The checkbox turns
/// a pair on or off, typing in the empty row at the end adds a pair, the x
/// removes one. Secret values show as dots with an eye to reveal them. A key
/// used twice, or one with a space, is marked. On a phone each key sits above
/// its value. Returns true when anything changed.
/// static cui_kv_pair headers[16] = { { "Accept", "application/json", true } };
/// static int n = 1;
/// cui_kv_editor(ui, "headers", headers, &n, 16);
pub const KvPair = struct {
    // `char key[64]` (arr): unsupported field type, reach it via zui.raw
    // `char value[256]` (arr): unsupported field type, reach it via zui.raw
    enabled: bool = false,  // the pair is in use; its checkbox toggles this
    secret: bool = false,  // the value shows as dots, with an eye to reveal it; the lock button toggles this
};

/// C `cui_level_meter_opts` — Level meter: bars that jump up to each new peak and fall back at `decay`
/// dB per second, with a peak mark that holds for `hold` seconds and a clip
/// light that stays on until clicked. Levels are linear sample peaks (1.0 is
/// 0 dBFS); green runs to -18 dB, amber to -6 dB, red above.
pub const LevelMeterOpts = struct {
    min_db: f32 = 0,  // default -60 and +6
    max_db: f32 = 0,  // default -60 and +6
    length: f32 = 0,  // default 160
    thickness: f32 = 0,  // each channel's bar, default 6
    horizontal: bool = false,  // bars run left to right instead of bottom to top
    scale: bool = false,  // dB labels beside the bars
    segmented: bool = false,  // LED segments instead of a solid bar
    hold: f32 = 0,  // peak hold, seconds; default 1.5, < 0 none
    decay: f32 = 0,  // fall rate, dB per second; default 20
};

/// C `cui_list_item_opts` — List item: a selectable row with optional icon, subtitle and trailing text.
pub const ListItemOpts = struct {
    icon: ?[]const u8 = null,
    subtitle: ?[]const u8 = null,  // second line under the title, smaller; makes the row taller
    trailing: ?[]const u8 = null,  // muted text at the right edge, e.g. a time or a count
    selected: bool = false,  // drawn with the active background
    avatar: ?[]const u8 = null,  // a name: shows that person's avatar (initials) in place of the icon
};

pub const LiveCursorsOpts = struct {
    // `view` (const cui_node_view *): pointer field, reach it via zui.raw
    no_glide: bool = false,  // jump to each new position
};

/// C `cui_live_user` — Live cursors: other people's pointers over the previous component (a canvas,
/// a document, a node editor), each an arrow in their color with a name flag
/// and an optional chat bubble. You pass where each pointer is whenever it
/// changes; the cursors glide there, at the same speed at any frame rate.
/// Positions are points from the component's top-left corner, or canvas
/// points under `view` (the node editor's pan and zoom). Cursors only draw:
/// they take no input and no focus.
/// cui_node_editor_end(ui);
/// cui_live_cursors(ui, "cursors", people, 3, .view = &view);
pub const LiveUser = struct {
    name: ?[]const u8 = null,  // on the flag, and the identity that keeps a cursor gliding: keep it stable
    color: ?Color = null,  // the cursor, flag and avatar; unset: `tone`
    tone: Tone = .neutral,  // the color as a tone of the theme when `color` is unset; 0: a tone chosen from the name
    x: f32 = 0,  // where the pointer is
    y: f32 = 0,  // where the pointer is
    says: ?[]const u8 = null,  // a chat bubble under the flag; `NULL` for none
    speaking: bool = false,  // presence pill: a ring and moving level bars on this person
    away: bool = false,  // the pointer is hidden (it left the canvas); still in the presence pill
    avatar: usize = 0,  // presence pill: a picture instead of the initials
};

pub const LoaderOpts = struct {
    style: LoaderStyle = .dots,
    size: f32 = 0,
    color: ?Color = null,
};

pub const LogBuffer = struct {
    now: f64 = 0,  // timestamp given to the next appended line (seconds)
    lines: ?*c.cui_log_line = null,  // the line records given to `cui_log_init`
    line_cap: i32 = 0,  // how many records `lines` has room for
    // `text` (char *): pointer field, reach it via zui.raw
    text_cap: u32 = 0,  // size of `text` in bytes
    first: i32 = 0,  // ring of lines: oldest record and how many
    count: i32 = 0,  // ring of lines: oldest record and how many
    text_end: u32 = 0,  // where the next line's text goes
    total: u64 = 0,  // lines ever appended; line i of the buffer is number total - count + i
    // `int level_count[CUI_LOG_LEVEL_COUNT]` (arr): unsupported field type, reach it via zui.raw
};

pub const LogLine = struct {
    offset: u32 = 0,  // where the line's text starts in the buffer's `text`
    len: u32 = 0,  // bytes of text, not counting the terminator
    time: f64 = 0,  // the timestamp it was appended with, in seconds
    level: u8 = 0,  // a `cui_log_level`
};

pub const LogViewOpts = struct {
    width: Size = .fit,  // default fill
    height: f32 = 0,  // default 320; negative fills the space
    timestamps: bool = false,  // show each line's time as HH:MM:SS.mmm
    no_toolbar: bool = false,  // just the lines
    size: f32 = 0,  // font size, default 12
};

/// C `cui_markdown_opts` — ---- Markdown view ----
/// Markdown view: renders your markdown text (UTF-8) as native content, every
/// frame, without keeping a copy:
/// static char notes[4096] = "## Release 2.4\n- [ ] Tag the release\n";
/// cui_markdown_result r = cui_markdown(ui, "notes", notes);
/// if (r.link) show_status(r.link);              (never opened for you)
/// cui_markdown_apply_task(notes, &r);           (a checkbox was clicked)
/// Supported: ATX headings (# to ######) and setext headings (=== and ---
/// under a line), paragraphs (single newlines are soft breaks; two trailing
/// spaces, a trailing backslash or <br> break the line), **bold**, *italic*
/// (and _ forms), ~~strikethrough~~, `inline code`, [links](url) and
/// ![images](url) (shown as links to the image), <https://autolinks>, bare
/// https:// and www. links, backslash escapes, &amp; &lt; &gt; &quot; &#39;
/// &nbsp;, bullet (- * +) and ordered (1. or 1)) lists nested by indentation,
/// task items (- [ ] and - [x]), block quotes, fenced code blocks (``` or ~~~
/// with a language, drawn by cui_code_block with its highlighter), indented
/// code, horizontal rules (--- *** ___) and pipe tables with an alignment row
/// (drawn with cui_table, scrolling sideways when narrower than their columns).
/// Everything else (HTML, reference links, footnotes, math) shows as plain
/// text. Containers nest at most 12 deep; deeper content shows as text.
/// With .streaming set (text still arriving, as in an AI reply), an unclosed
/// **, *, ~~, `, [link] or (url) at the very end renders as if it were
/// closed, markers that may still grow are held back, and an unfinished
/// table row or heading underline waits for its line, so appending text never
/// flickers between styles. An unclosed code fence always runs to the end.
/// Links use the accent color with an underline that firms up on hover, show
/// their URL as a tooltip, take Tab focus and activate with Enter. Text is not
/// selectable (CUI text has no selection yet); code blocks have a copy button.
/// Parsing allocates only from the frame arena (about 16 bytes a line and a
/// few dozen per inline marker), so a long reply re-parses every frame.
pub const MarkdownOpts = struct {
    width: Size = .fit,  // default fill
    fit_content: bool = false,  // as wide as the content needs, up to the space there is (chat bubbles)
    length: i32 = 0,  // bytes of text to show, default strlen (text then need not end in a NUL)
    size: f32 = 0,  // body text size, default theme text_body
    color: ?Color = null,  // body text color, default foreground; links then take it too, underlined
    streaming: bool = false,  // text is still arriving
    compact: bool = false,  // smaller headings and tighter spacing, for chat bubbles
};

pub const MarkdownResult = struct {
    link: ?[]const u8 = null,  // URL of the link clicked (or activated with Enter) this frame, or NULL; frame memory
    hovered_link: ?[]const u8 = null,  // URL of the link under the pointer, or NULL; frame memory
    task_offset: i32 = 0,  // a task box was toggled: byte offset in text of the character between its brackets, else -1
    task_line: i32 = 0,  // that item's 1 based line in text, 0 when none
    task_checked: bool = false,  // the state the box was toggled to
    height: f32 = 0,  // height of the view in the latest layout
};

/// C `cui_menu_bar_menu_opts` — One menu of the bar. Returns true while its items should be built; call
/// cui_menu_bar_menu_end only then.
pub const MenuBarMenuOpts = struct {
    mnemonic: u8 = 0,  // letter that opens the menu with Alt; 0 uses the first letter or digit of the label
    width: f32 = 0,
    disabled: bool = false,
};

/// C `cui_menu_bar_opts` — ------------------------------------------------------------------------
/// App chrome: menu bar, toolbar, status bar, document tabs
/// ------------------------------------------------------------------------
/// Menu bar: File / Edit / View along the top of a window. Each menu holds
/// the usual menu items (cui_menu_item, cui_menu_separator, cui_menu_label).
/// Once a menu is open, hovering another one switches to it. Alt (on its own)
/// or F10 focuses the bar; arrows move between menus and items, Enter
/// chooses, Esc steps back. Alt + a menu's mnemonic letter opens it (the
/// first letter of its label unless `mnemonic` says otherwise).
pub const MenuBarOpts = struct {
    no_border: bool = false,
};

pub const MenuItemOpts = struct {
    icon: ?[]const u8 = null,
    shortcut: ?[]const u8 = null,
    danger: bool = false,
    disabled: bool = false,
    checked: bool = false,  // a check mark at the right edge of the item
    font: i32 = 0,  // the label's font, default CUI_FONT_BODY: a style menu shows each style in its own
    text_size: f32 = 0,  // the label's size in points, default the body size; the item grows to fit it
};

/// C `cui_menu_opts` — Dropdown menu: a button that opens a menu. Items return true when chosen.
pub const MenuOpts = struct {
    icon: ?[]const u8 = null,
    variant: ButtonVariant = .default,
    placement: Placement = .bottom_start,
    width: f32 = 0,
    icon_only: bool = false,  // an icon button (the ellipsis unless `icon` is set) with the label as its tooltip
};

/// C `cui_meter_part` — Pattern meter: a stacked usage bar (storage, budgets, quotas) whose parts differ in color
/// and in the density of their dots, so it still reads in grayscale, in print and without
/// telling hues apart. One dot of space parts the parts, and the rest of `total` is free
/// space in the track color. Hovering a part, or its legend entry, steps the others back and
/// shows its name, value and share above the bar; the keyboard does the same with Left and
/// Right. Returns the part shown, or -1.
pub const MeterPart = struct {
    name: ?[]const u8 = null,  // in the legend and the readout
    value: f32 = 0,  // in the meter's units
    color: ?Color = null,  // default: the series palette, in order
    density: f32 = 0,  // share of dots lit, 0..1; 0 takes the next of 1, 0.66, 0.42, 0.24, 0.14, 0.08
};

pub const MetricOpts = struct {
    delta: f32 = 0,  // change shown beside the value with a trend arrow, as a percentage (4.2 shows +4.2%); 0 hides it
    delta_label: ?[]const u8 = null,  // text shown instead of the percentage, e.g. "+12 this week"; `delta` still sets arrow and color
    spark: []const f32 = &.{},  // values for a sparkline under the value; needs at least 2
    icon: ?[]const u8 = null,
    width: Size = .fit,
    lower_is_better: bool = false,  // build times, errors, latency: a fall is good news, shown in green
};

/// C `cui_model` — Model picker: the current model on a button; a list with details opens.
pub const Model = struct {
    name: ?[]const u8 = null,  // shown on the button and as the row's heading in the list
    detail: ?[]const u8 = null,  // smaller muted line under the name in the list, e.g. what the model is good at
    badge: ?[]const u8 = null,  // small accent badge after the name, e.g. "New"; `NULL` for none
    icon: ?[]const u8 = null,
};

pub const ModelPickerOpts = struct {
    ghost: bool = false,  // no border or fill on the button until hovered, for use inside another control
    placement: Placement = .bottom_start,
};

/// C `cui_money_opts` — Money field: shows the amount with thousands separators, edits as plain
/// digits, keeps a fixed number of decimals.
pub const MoneyOpts = struct {
    label: ?[]const u8 = null,
    symbol: ?[]const u8 = null,  // currency symbol before the amount, default "$"
    code: ?[]const u8 = null,  // currency code after the amount, e.g. "USD"
    decimals: i32 = 0,
    width: Size = .fit,
    hint: ?[]const u8 = null,  // helper text below the field
};

/// C `cui_month_event` — Month calendar: a month grid with events. All-day and multi-day events
/// are bars across the days they cover; timed events are a dot, a time and a
/// title. A day with more than fits says "+N more" and opens a list of them.
/// On a narrow screen the cells show colored dots and the selected day's
/// events are listed under the grid.
/// static cui_date month = { 2026, 11, 1 }, day;
/// cui_month_result r = cui_month_calendar(ui, "cal", &month, events, count, .selected = &day);
/// if (r.event >= 0) open_event(r.event);
/// if (r.day_activated) new_event_on(day);
/// With the grid focused the arrows move the selected day (into the next or
/// previous month), Page Up and Page Down change month, Home goes to today
/// and Enter activates the selected day even when the pointer rests on another day.
pub const MonthEvent = struct {
    title: ?[]const u8 = null,  // shown on the event's bar, or after the time of a timed event
    start: Date = .{},  // inclusive; an unset or earlier end means one day
    end: Date = .{},  // inclusive; an unset or earlier end means one day
    time: f32 = 0,  // hour of a timed event (9.5 is 9:30); ignored when all_day
    all_day: bool = false,  // a bar, like every event that spans days
    tone: Tone = .neutral,
};

pub const MonthOpts = struct {
    selected: ?*c.cui_date = null,  // the selected day: yours to read and set
    first_weekday: i32 = 0,  // 0 Monday (default) .. 6 Sunday
    cell_height: f32 = 0,  // default 104, 44 on a phone
    // `month_names` (const char *const *): pointer field, reach it via zui.raw
    // `day_names` (const char *const *): pointer field, reach it via zui.raw
    hour12: bool = false,  // 9:30a rather than 9:30
    today: Date = .{},  // overrides the system date when set (another time zone, tests)
};

pub const MonthResult = struct {
    event: i32 = 0,  // clicked event, or -1
    day_clicked: bool = false,  // a day was clicked or moved to with the keys (see selected)
    day_activated: bool = false,  // double-clicked or Enter: add an event there
    month_changed: bool = false,  // the arrows, Today or the keys changed *month
};

/// C `cui_multi_select_opts` — ------------------------------------------------------------------------
/// Pickers
/// ------------------------------------------------------------------------
/// Multi-select: a field with chips for the chosen items and a list with
/// checkboxes (and search). selected[i] is true for chosen items.
pub const MultiSelectOpts = struct {
    label: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    // `icons` (const char *const *): pointer field, reach it via zui.raw
    searchable: bool = false,  // a search field at the top of the list that filters the items as you type
    max_chips: i32 = 0,  // chips before "+N", default 3
    width: Size = .fit,
};

/// C `cui_nav_opts` — Sidebar navigation item with a gliding selection highlight shared by all
/// items in the same group.
pub const NavOpts = struct {
    icon: ?[]const u8 = null,
    badge: ?[]const u8 = null,  // small text at the right edge of the item, e.g. a count
    selected: bool = false,  // the current page: medium weight text, and the group's highlight glides to it
    group: ?[]const u8 = null,  // items with the same group name share one highlight; `NULL` puts them in one common group
};

/// C `cui_net_request` — ---- Network waterfall ----
/// HTTP requests as a table with a timing bar each: queued, DNS, connect, TLS,
/// waiting for the first byte and downloading, on one time scale with the
/// page's DOMContentLoaded and load lines. Hover a bar for the breakdown.
/// Narrow panels drop the type and size columns. Only the rows in view are
/// built. Up and Down move the selection.
pub const NetRequest = struct {
    name: ?[]const u8 = null,  // path or URL; the last part is shown
    method: ?[]const u8 = null,  // "GET"
    status: i32 = 0,  // 0 while pending or when it failed
    @"type": ?[]const u8 = null,  // "fetch", "script", "image"...
    size: f64 = 0,  // bytes transferred
    start: f64 = 0,  // seconds from the start of the page
    // `float timing[6]` (arr): unsupported field type, reach it via zui.raw
};

pub const NodeEditorOpts = struct {
    width: Size = .fit,  // default: fill the width, 440 tall
    height: Size = .fit,  // default: fill the width, 440 tall
    min_zoom: f32 = 0,  // default 0.25 .. 2
    max_zoom: f32 = 0,  // default 0.25 .. 2
    no_grid: bool = false,
    minimap: bool = false,  // an overview of the graph in the bottom right corner; click it to move there
};

/// C `cui_node_opts` — A node at canvas position (*x, *y), updated while it is dragged. Returns
/// true while the node is selected.
pub const NodeOpts = struct {
    width: f32 = 0,
    icon: ?[]const u8 = null,
};

/// C `cui_node_view` — ---- Node editor ----
/// Node editor: nodes with input and output pins on a canvas that pans and
/// zooms, joined by curved links. You own the nodes, pins and links; the
/// editor moves the node positions you pass and reports what the user did:
/// if (cui_node_editor_begin(ui, "graph", &view, .height = CUI_PX(480))) {
/// for (each node n) {
/// cui_node_begin(ui, n->id, &n->x, &n->y, n->title);
/// cui_node_input(ui, n->in_pin, "Color", .type = 1);
/// cui_node_content(ui) { cui_slider(ui, "##fac", &n->factor, 0, 1); }
/// cui_node_output(ui, n->out_pin, "Result", .type = 1);
/// cui_node_end(ui);
/// }
/// for (each link l) cui_node_link(ui, l->id, l->from_pin, l->to_pin);
/// int a, b, id;
/// while (cui_node_link_created(ui, &a, &b)) add_link(a, b);   (output pin, input pin)
/// while (cui_node_link_removed(ui, &id)) remove_link(id);
/// while (cui_node_deleted(ui, &id)) remove_node(id);
/// cui_node_editor_end(ui);
/// }
/// Node, pin and link ids are your own integers (pin ids unique in the
/// editor). Scroll to zoom around the pointer; pan with the middle button or
/// Space and drag. Drag a card to move it (with the rest of the selection),
/// click to select, Shift or Ctrl to add, drag on the empty canvas for a
/// marquee. Drag from a pin to make a link; drag a link's input end off its
/// pin to detach it. Delete removes the selection, F frames every node.
pub const NodeView = struct {
    x: f32 = 0,  // where the canvas origin sits, in points from the editor's left edge; panning changes it
    y: f32 = 0,  // where the canvas origin sits, in points from the editor's top edge
    zoom: f32 = 0,  // scale of the canvas; 0 means 1. Kept between `min_zoom` and `max_zoom`
};

pub const NowPlayingOpts = struct {
    width: Size = .fit,
    compact: bool = false,  // smaller artwork and padding, and no previous button
};

/// C `cui_option_action_opts` — Option field with action: a compact segmented choice and the icon button of the action it
/// feeds (save as png, jpg or webp, then download). Returns CUI_WELL_* flags.
/// if (cui_option_action(ui, "Save as", formats, 3, &fmt, CUI_ICON_DOWNLOAD, .tooltip = "Download") & CUI_WELL_ACTION) save(fmt);
pub const OptionActionOpts = struct {
    tooltip: ?[]const u8 = null,  // names the action button
    action_on: bool = false,  // shows the action button pressed
    action_disabled: bool = false,
    value: ?[]const u8 = null,  // text at the right of the label
    plain: bool = false,
};

/// C `cui_palette_strip_opts` — Palette strip: a joined row of color swatches (up to 16). A click on a swatch locks or
/// unlocks it, and the shuffle button after the row recolors the unlocked ones. The swatch
/// under the pointer widens and shows its hex code. Tab reaches the swatches, Left and
/// Right move between them, Space or Enter locks. Returns CUI_WELL_CHANGED when a lock or a
/// color changed and CUI_WELL_ACTION when shuffle was pressed.
/// static uint32_t seed = 7;
/// cui_palette_strip(ui, "Color palette", colors, locked, 5, .seed = &seed);
pub const PaletteStripOpts = struct {
    // `seed` (uint32_t *): pointer field, reach it via zui.raw
    value: ?[]const u8 = null,  // text at the right of the label, e.g. "Click a swatch to lock it"
    no_shuffle: bool = false,  // no shuffle button
    height: f32 = 0,  // default 32
    plain: bool = false,
};

/// C `cui_path_bar_opts` — Path bar: a breadcrumb for file and scene paths. Segments are clickable,
/// the last one is the current place. Middle segments that do not fit
/// collapse into a "..." menu. With .menus, the chevron after segment k opens
/// a menu you fill with the children of segment k (cui_path_bar_menu_begin).
/// Click the empty part (or the current segment), or press Ctrl+L, to type a
/// path: Enter submits it, Esc or clicking away cancels.
pub const PathBarOpts = struct {
    icon: ?[]const u8 = null,  // before the first segment
    text: ?[]const u8 = null,  // what editing starts with, default the segments joined by "/"
    placeholder: ?[]const u8 = null,
    size: ControlSize = .md,
    width: Size = .fit,  // default fill
    menus: bool = false,  // separators open a menu of the next segment's siblings
    no_edit: bool = false,  // no text mode
};

pub const PathBarResult = struct {
    clicked: i32 = 0,  // segment clicked (here or in the "..." menu), else -1
    submitted: ?[]const u8 = null,  // the typed path after Enter, else NULL; valid this frame
    editing: bool = false,  // the bar is showing its text field for typing a path
};

pub const PatternMeterOpts = struct {
    total: f32 = 0,  // the whole bar; 0 means the sum of the parts (no free space)
    label: ?[]const u8 = null,  // the title over the bar, e.g. "Storage"
    unit: ?[]const u8 = null,  // after every value, e.g. "GB"
    format: ?[]const u8 = null,  // printf format of a value, default "%g"
    free_label: ?[]const u8 = null,  // the legend entry of the free space, default "Free"; "" leaves it out
    grayscale: bool = false,  // every part in the foreground color, told apart by density alone
    no_legend: bool = false,
    height: f32 = 0,  // points, default 18
    width: Size = .fit,  // default: fill
};

/// C `cui_pin_opts` — A row with a pin on the left (input) or right (output). type picks the pin
/// color from the series palette and limits links to pins of the same type
/// (0 connects to anything). Returns true when the pin has a link.
pub const PinOpts = struct {
    @"type": i32 = 0,  // 0 links to any pin; another number links only to pins of that type and picks their color
};

pub const PipelineJob = struct {
    name: ?[]const u8 = null,  // shown on the job's row and in its tooltip
    stage: i32 = 0,  // index into the stage names
    status: JobStatus = .pending,
    duration: f32 = 0,  // seconds; negative when it has not run
    allow_failure: bool = false,  // a failure does not fail the stage
};

pub const PipelineOpts = struct {
    width: Size = .fit,
    // `selected` (int *): pointer field, reach it via zui.raw
};

pub const PipelineResult = struct {
    clicked: i32 = 0,  // job clicked this frame (or chosen with Enter or Space), or -1
    hovered: i32 = 0,  // job under the pointer, or -1
};

/// C `cui_plan_step` — Agent plan: steps with their status on a connected rail, and progress.
/// Reduced motion holds the running glyph still, including in tool calls.
pub const PlanStep = struct {
    title: ?[]const u8 = null,  // the step's text; shimmers while the step is running
    detail: ?[]const u8 = null,  // smaller muted line under the title (red when the step failed); may be `NULL`
    status: TaskStatus = .pending,
};

/// C `cui_platform_iface` — Platform services. The built-in backends set these.
pub const PlatformIface = struct {
    // `user` (void *): pointer field, reach it via zui.raw
    // `void (*set_clipboard)(void *user, const char *utf8)`: function-pointer field, set via zui.raw if needed
    // `const char *(*get_clipboard)(void *user)`: function-pointer field, set via zui.raw if needed
    // `void (*set_cursor)(void *user, cui_cursor cursor)`: function-pointer field, set via zui.raw if needed
    // `void (*set_text_input_rect)(void *user, cui_rect caret)`: function-pointer field, set via zui.raw if needed
    // `bool (*draw_emoji)(void *user, const char *utf8, int len, int px, unsigned char *rgba)`: function-pointer field, set via zui.raw if needed
};

/// C `cui_popover_opts` — Popover anchored to the previous component. Toggle it with
/// cui_popover_toggle / cui_popover_open.
pub const PopoverOpts = struct {
    placement: Placement = .bottom_start,
    width: f32 = 0,
    pad: f32 = 0,
    gap: f32 = 0,
};

/// C `cui_presence_pill_opts` — Presence pill: who is here, as overlapping avatars in their colors. Whoever is
/// speaking gets a ring, and the pill shows moving level bars and their name.
pub const PresencePillOpts = struct {
    size: f32 = 0,  // avatar size, default 26
    max_visible: i32 = 0,  // default 5; the rest become "+n"
};

/// C `cui_presence_user` — Presence: who is here now. Overlapping avatars with a colored ring each,
/// that spread out on hover and name themselves.
pub const PresenceUser = struct {
    name: ?[]const u8 = null,  // shown in the tooltip, and as initials when there is no avatar
    color: ?Color = null,
    avatar: usize = 0,  // picture to show instead of the initials
    idle: bool = false,  // away: the avatar dims, its ring turns gray and the tooltip adds "(away)"
};

pub const ProblemsOpts = struct {
    width: Size = .fit,
    height: f32 = 0,
    no_toolbar: bool = false,  // hides the severity toggles and the filter field above the list
};

pub const ProblemsResult = struct {
    selected: i32 = 0,  // diagnostic selected, or -1
    activated: i32 = 0,  // diagnostic opened this frame (Enter, double-click), or -1
    shown: i32 = 0,  // diagnostics that pass the filters
};

/// C `cui_progress_opts` — ------------------------------------------------------------------------
/// Feedback and display
/// ------------------------------------------------------------------------
pub const ProgressOpts = struct {
    indeterminate: bool = false,  // no value: a segment (or with `dither`, a soft band of dots) travels the track
    tone: Tone = .neutral,
    height: f32 = 0,  // points, default 6 (8 with `dither`)
    label: ?[]const u8 = null,  // a row above the bar with this name
    show_value: bool = false,  // a whole percentage at the end of that row
    width: Size = .fit,
    dither: bool = false,  // drawn in dots: the fill dissolves over 60 points past its edge, and the pattern drifts forward while the bar is not full; reduced motion holds it still
};

/// C `cui_prompt_suggestion` — Prompt suggestions: cards to start a conversation with.
pub const PromptSuggestion = struct {
    icon: ?[]const u8 = null,
    title: ?[]const u8 = null,  // the card's heading, in medium weight
    detail: ?[]const u8 = null,  // smaller muted text under the title; may be `NULL`
};

pub const PromptSuggestionsOpts = struct {
    columns: i32 = 0,  // cards per row, default 2
};

pub const PropOpts = struct {
    min: f32 = 0,  // number and vector rows; both 0 = unbounded
    max: f32 = 0,  // number and vector rows; both 0 = unbounded
    step: f32 = 0,  // drag and arrow step, default 1/100 of the range (0.1 unbounded)
    format: ?[]const u8 = null,  // printf format, default from the step ("%.2f" for 0.01)
    suffix: ?[]const u8 = null,  // unit after the value, e.g. "px" or "deg"
    placeholder: ?[]const u8 = null,  // text rows
    tooltip: ?[]const u8 = null,  // shown on the label
    disabled: bool = false,
    checkbox: bool = false,  // bool rows: a checkbox instead of a switch
};

pub const QueryField = struct {
    name: ?[]const u8 = null,  // shown in the field select and in the text `cui_query_text` writes
    @"type": QueryType = .text,
    // `choices` (const char *const *): pointer field, reach it via zui.raw
    choice_count: i32 = 0,  // number of `choices`
};

pub const QueryNode = struct {
    depth: i32 = 0,  // 0 for the outer group
    group: bool = false,  // a group of the nodes after it that are one level deeper; otherwise a rule
    any: bool = false,  // group: any rule (or) instead of all (and)
    field: i32 = 0,  // rule: index into the fields
    op: i32 = 0,  // rule: see cui_query_op_name
    // `char value[64]` (arr): unsupported field type, reach it via zui.raw
};

pub const QueryOpts = struct {
    width: Size = .fit,
    max_depth: i32 = 0,  // how deep groups may nest, default 3
    read_only: bool = false,
};

/// C `cui_radar_opts` — Radar chart: series over shared axes (series[i].values[axis]), light fills with crisp
/// outlines on hairline rings. The last series shows its points, or the one nearest the
/// pointer, with a chip of the hovered value.
pub const RadarOpts = struct {
    size: f32 = 0,
    max: f32 = 0,  // value at the outer ring; 0 picks a round number above the largest value
    format: ?[]const u8 = null,
    no_legend: bool = false,
};

pub const RadialGaugeOpts = struct {
    label: ?[]const u8 = null,  // under the value
    format: ?[]const u8 = null,  // the value, the ends and the target, default whole numbers with large ones shortened (1.8k)
    unit: ?[]const u8 = null,  // after the value, smaller and muted
    size: f32 = 0,  // width, default 200; the height follows the sweep
    sweep: f32 = 0,  // degrees of arc, default 270 (90 to 300); the ring is always a full turn
    bands: []const GaugeBand = &.{},  // colored stretches of the arc, each from the one before up to its `to`; at most 16
    ticks: i32 = 0,  // -1 hides the min and max labels at the ends of the arc
    target: f32 = 0,  // a marker on the arc, when show_target is set
    show_target: bool = false,  // draws the marker at `target`, labelled with its value (arc style)
    no_needle: bool = false,  // kept for older code; no style has a needle
    style: GaugeStyle = .auto,  // CUI_GAUGE_AUTO picks segments with `bands`, else the arc
    detail: ?[]const u8 = null,  // a muted line under the gauge, e.g. "190 of 500 GB"; `NULL` for none
    color: ?Color = null,  // the value's color; unset: the band the value is in, else the accent (the ring: the first series color)
};

pub const RadioCardsOpts = struct {
    columns: i32 = 0,  // cards per row; 0 puts up to 3 choices in one row and more in 2 columns
};

/// C `cui_ratio_slider_opts` — Ratio slider: a whole split into two named parts, with a bar between them to drag.
/// *ratio is the first part's share, 0..1. Both names and percentages stay readable: the
/// split stops where a part would get too narrow for them. Arrows move one step (Shift:
/// ten), Home and End go to the limits.
/// cui_ratio_slider(ui, "COFFEE", "MILK", &coffee, .tone = CUI_TONE_WARNING);
pub const RatioSliderOpts = struct {
    tone: Tone = .neutral,  // color of the first part; 0 uses the accent
    step: f32 = 0,  // arrow key step as a share, default 0.01 (one percent)
    height: f32 = 0,  // default 52
    width: Size = .fit,  // default fill
    disabled: bool = false,
};

/// C `cui_readout_opts` — Readout: one figure as an instrument shows it. A small label, the value in the
/// monospaced font with its unit, and a muted line of context under it.
/// cui_readout(ui, "STILL IN YOU AT 23:00", "54", .unit = "MG", .detail = "under the 50 MG line by 00:10");
pub const ReadoutOpts = struct {
    unit: ?[]const u8 = null,  // after the value, smaller and muted, e.g. "MG"
    detail: ?[]const u8 = null,  // a muted line under the value; `NULL` for none
    size: ControlSize = .md,  // the value's size: CUI_SIZE_SM 17, CUI_SIZE_MD 28 (default), CUI_SIZE_LG 44 points
    tone: Tone = .neutral,  // the value's color; 0 is the foreground
    accent: bool = false,  // the value in the accent color
    @"align": TextAlign = .start,  // default start
    width: Size = .fit,  // default fit
};

/// C `cui_reasoning_opts` — ------------------------------------------------------------------------
/// AI interfaces
/// ------------------------------------------------------------------------
/// Reasoning: a model's thinking. While thinking, the header shimmers and
/// counts the seconds; afterwards it reads "Thought for 12s" and the body
/// folds away. Click the header to open or close it. Put text inside.
pub const ReasoningOpts = struct {
    thinking: bool = false,  // still thinking: the header shimmers and the body opens; it folds when this turns false
    seconds: f32 = 0,  // time spent, for the header: "Thinking for 12s", then "Thought for 12s"
    title: ?[]const u8 = null,  // header text to show instead of the "Thinking" and "Thought for" lines
};

pub const RegexMatch = struct {
    start: i32 = 0,  // bytes
    end: i32 = 0,  // bytes
    groups: i32 = 0,  // capture groups in the pattern
    // `int group_start[CUI_REGEX_GROUPS], group_end[CUI_REGEX_GROUPS]` (arr): unsupported field type, reach it via zui.raw
    // `char group_name[CUI_REGEX_GROUPS][24]` (arr): unsupported field type, reach it via zui.raw
};

/// C `cui_regex_tester_opts` — A pattern field with flags over a test text: every match is highlighted in
/// the text and its groups in their own colors, and the list below shows each
/// match with its groups. Errors show under the pattern. Both buffers are
/// yours and edited in place.
pub const RegexTesterOpts = struct {
    width: Size = .fit,
    height: f32 = 0,  // of the test text, default 180
    // `flags` (int *): pointer field, reach it via zui.raw
};

pub const RegexTesterResult = struct {
    valid: bool = false,  // the pattern is valid and matching finished in time
    matches: i32 = 0,  // matches found in the test text
    @"error": ?[]const u8 = null,  // why, when `valid` is false; otherwise `NULL`
};

pub const RequestBarOpts = struct {
    width: Size = .fit,
    loading: bool = false,  // a request is in flight: the button reads Cancel and Enter does not send
    placeholder: ?[]const u8 = null,
};

pub const RequestBarResult = struct {
    send: bool = false,  // Send was pressed, or Enter in the URL: start the request
    cancel: bool = false,  // Cancel was pressed while `loading`
    changed: bool = false,  // the method or the URL was edited this frame
};

pub const ResponseActionsOpts = struct {
    copy_text: ?[]const u8 = null,  // the text the copy button copies; `NULL` leaves the button out
    // `vote` (int *): pointer field, reach it via zui.raw
    no_regenerate: bool = false,  // hides the regenerate button
    no_share: bool = false,  // hides the share button
};

/// C `cui_result_card_opts` — Result card: a picture with rounded corners, an optional status chip in the
/// top corner, and a title and caption on a soft fade at the bottom, for a
/// render, an export or a generated image. Put its actions under it in a
/// floating toolbar (cui_toolbar with CUI_TOOLBAR_FLOATING, cycle pickers for
/// choices like 2x or PNG). The picture fills the card and is cropped to it.
/// The card is focusable; a click, Enter or Space returns true (open it large).
pub const ResultCardOpts = struct {
    caption: ?[]const u8 = null,  // under the title, wraps
    badge: ?[]const u8 = null,  // the status chip, e.g. "Done in 4.2 s"; `NULL` for none
    badge_tone: Tone = .neutral,  // the chip's dot, default success
    image_w: i32 = 0,  // the picture's size in pixels, to crop it without stretching; 0: stretched
    image_h: i32 = 0,  // the picture's size in pixels, to crop it without stretching; 0: stretched
    width: Size = .fit,  // default fill, up to 320
    aspect: f32 = 0,  // height over width, default 1.25
};

/// C `cui_rings_opts` — Activity rings: concentric progress rings; values past 1 keep winding.
pub const RingsOpts = struct {
    size: f32 = 0,
    thickness: f32 = 0,  // width of each ring in points; 0 uses a tenth of `size`, at least 8
    center: ?[]const u8 = null,  // large text in the middle of the rings, e.g. a total
    caption: ?[]const u8 = null,  // small muted text under `center`; shown only with `center`
    legend: bool = false,  // names and shares beside the rings
};

/// C `cui_ruler_opts` — Ruler slider: a tape measure that slides under a fixed marker, with
/// momentum and snapping to step.
pub const RulerOpts = struct {
    step: f32 = 0,
    major_every: i32 = 0,  // every Nth tick is long and labelled, default 10; Shift+arrows move this many steps
    spacing: f32 = 0,  // points between two ticks (one `step` apart), default 9
    format: ?[]const u8 = null,
    unit: ?[]const u8 = null,
    width: Size = .fit,
};

/// C `cui_sankey_link` — Sankey: flows between nodes; columns follow the links from the sources. Slim nodes in
/// the colors you give them, flows shaded from source to target color, and hovering a node
/// or a flow lights its whole path upstream and downstream.
pub const SankeyLink = struct {
    from: i32 = 0,  // index of the node the flow leaves
    to: i32 = 0,  // index of the node the flow enters
    value: f32 = 0,  // size of the flow: sets the link's thickness
};

pub const SankeyOpts = struct {
    width: Size = .fit,
    height: f32 = 0,
    format: ?[]const u8 = null,
    node_width: f32 = 0,  // width of the node bars in points, default 6
    // `node_colors` (const cui_color *): pointer field, reach it via zui.raw
};

pub const ScatterOpts = struct {
    width: Size = .fit,
    height: f32 = 0,
    x_label: ?[]const u8 = null,  // title under the x axis; also names the x value in the tooltip
    y_label: ?[]const u8 = null,  // title above the y axis; also names the y value in the tooltip
    x_format: ?[]const u8 = null,  // printf format for the x axis labels and the tooltip
    y_format: ?[]const u8 = null,  // printf format for the y axis labels and the tooltip
    no_legend: bool = false,
};

/// C `cui_scatter_series` — Scatter (or bubble) chart: points per series, optional sizes.
pub const ScatterSeries = struct {
    name: ?[]const u8 = null,  // shown in the legend, which appears with two or more series
    points: []const Vec2 = &.{},  // the points, x and y in data units
    // `sizes` (const float *): pointer field, reach it via zui.raw
    color: ?Color = null,
};

/// C `cui_schedule_opts` — ---- Schedule picker ----
/// A cron schedule edited the friendly way: every N minutes, hourly at a
/// minute, daily at a time, weekly on chosen days, monthly on a day, or a
/// custom expression. It reads and writes `cron` (five fields: minute hour
/// day month weekday) and shows what it means and when it runs next. Weekday
/// and month names come from cui_set_strings.
pub const ScheduleOpts = struct {
    width: Size = .fit,
    now: i64 = 0,  // the next runs are counted from here, Unix seconds; 0: the clock
    utc: bool = false,  // times in UTC instead of local time
    next_count: i32 = 0,  // runs listed, default 3, 0 hides them
};

pub const ScheduleResult = struct {
    changed: bool = false,  // `cron` was edited this frame
    valid: bool = false,  // `cron` is a valid expression
    next: i64 = 0,  // the next run, Unix seconds, 0 none
};

/// C `cui_scrub_opts` — Scrub field: drag sideways anywhere on it to change the value (Shift for
/// fine steps), or click to type a number. Arrow keys step when focused.
pub const ScrubOpts = struct {
    step: f32 = 0,  // default (max - min) / 100
    format: ?[]const u8 = null,  // default "%.0f"
    suffix: ?[]const u8 = null,  // e.g. "px" or "%"
    icon: ?[]const u8 = null,  // shown instead of the label
    width: Size = .fit,
};

/// C `cui_seed_field_opts` — Seed field: a random seed in the monospaced font. The dice rolls a new one, its digits
/// rolling into place, and the lock keeps it fixed (the dice is off while locked). Returns
/// CUI_WELL_CHANGED when the seed or the lock changed and CUI_WELL_ACTION on a roll.
/// cui_seed_field(ui, "Seed", &seed, &fixed, .value = fixed ? "Same image every run" : "Random each run");
pub const SeedFieldOpts = struct {
    value: ?[]const u8 = null,  // text at the right of the label
    random_text: ?[]const u8 = null,  // the mode word in the field while unlocked, default "random"
    fixed_text: ?[]const u8 = null,  // and while locked, default "fixed"
    plain: bool = false,
};

/// C `cui_segmented_opts` — Segmented control: a row of options with a gliding highlight.
pub const SegmentedOpts = struct {
    size: ControlSize = .md,
    full_width: bool = false,
    // `icons` (const char *const *): pointer field, reach it via zui.raw
};

/// C `cui_select_opts` — ------------------------------------------------------------------------
/// Select, combobox, date picker
/// ------------------------------------------------------------------------
pub const SelectOpts = struct {
    label: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    // `icons` (const char *const *): pointer field, reach it via zui.raw
    searchable: bool = false,  // combobox: filter options by typing
    disabled: bool = false,
    width: Size = .fit,
};

/// C `cui_selection_action` — Selection bar: a floating bar that slides up under the previous component
/// (a list, a table, a grid) while something in it is selected: "3 selected"
/// with a clear button, then labeled actions. Esc clears the selection too.
/// Give it the count, or your array of flags in `selected` and it counts and
/// clears them itself.
/// static const cui_selection_action acts[] = { { CUI_ICON_MOVE, "Move" }, { CUI_ICON_TRASH_2, "Delete", CUI_TONE_DANGER } };
/// int a = cui_selection_bar(ui, "bulk", 0, acts, 2, .selected = picked, .item_count = n);
/// if (a == 1) delete_picked();
pub const SelectionAction = struct {
    icon: ?[]const u8 = null,
    label: ?[]const u8 = null,
    tone: Tone = .neutral,  // CUI_TONE_DANGER for a destructive action
};

pub const SelectionBarOpts = struct {
    // `selected` (bool *): pointer field, reach it via zui.raw
    item_count: i32 = 0,  // how many flags `selected` holds
    count_format: ?[]const u8 = null,  // default "%d selected"
    anchor: u32 = 0,  // the component it sits under; 0: the previous component
    no_escape: bool = false,  // Esc does not clear
};

/// C `cui_selection_ring_opts` — Selection ring: a ring in someone's color around the previous component, for
/// "this item is selected by Kate", with an optional name flag on its corner.
pub const SelectionRingOpts = struct {
    name: ?[]const u8 = null,  // a small flag at the top end corner; `NULL` for none
    radius: f32 = 0,  // the ring's corner radius; 0 follows the component's corners
};

/// C `cui_series` — Charts
pub const Series = struct {
    name: ?[]const u8 = null,  // shown in the legend and in the hover tooltip
    values: []const f32 = &.{},  // the series' data, one value per point
    color: ?Color = null,  // default: series palette
};

pub const SheetOpts = struct {
    side: Side = .right,
    size: f32 = 0,
    description: ?[]const u8 = null,
};

pub const ShortcutRecorderOpts = struct {
    placeholder: ?[]const u8 = null,
    width: Size = .fit,
};

/// C `cui_signature_opts` — ------------------------------------------------------------------------
/// Capture
/// ------------------------------------------------------------------------
/// Signature pad: draw with the mouse or a pen. The strokes are kept for you;
/// read them with cui_signature_points (stroke_ends[i] is one past the last
/// point of stroke i).
pub const SignatureOpts = struct {
    width: Size = .fit,
    height: f32 = 0,
    placeholder: ?[]const u8 = null,
    ink: ?Color = null,  // color of the strokes, default the foreground color
};

/// C `cui_skeleton_group_opts` — Skeleton group: placeholders for content that is loading, built inside it with
/// cui_skeleton (in rows and columns as the content will be), share one shine that passes
/// over them together. With `dither` they are drawn in dots and a band of brighter dots
/// travels over them, asking for 20 frames a second while on screen; reduced motion holds
/// the band still. Groups nest.
/// cui_skeleton_group(ui, .dither = true) {
/// cui_row(ui, .gap = 10) { cui_skeleton(ui, CUI_PX(20), 20); cui_skeleton(ui, CUI_PCT(55), 6); }
/// cui_skeleton(ui, CUI_FILL, 6);
/// }
pub const SkeletonGroupOpts = struct {
    dither: bool = false,  // in dots, with a band of brighter dots passing over them
    width: Size = .fit,  // default: fill
    gap: f32 = 0,  // between what is built inside, default 8
};

/// C `cui_source` — Sources: cards for the documents an answer used, and inline citations
/// that show a card on hover. Both return true / the index when clicked.
pub const Source = struct {
    title: ?[]const u8 = null,  // the card's heading; `NULL` shows the URL's domain
    url: ?[]const u8 = null,  // the address: its domain is shown, and the whole URL as the card's tooltip
    snippet: ?[]const u8 = null,  // an excerpt, shown in the hover card of a citation
};

/// C `cui_speed_action` — Speed dial: a round floating action button that fans out related actions.
/// Returns the chosen action index, or -1.
pub const SpeedAction = struct {
    icon: ?[]const u8 = null,
    label: ?[]const u8 = null,
};

pub const SpeedDialOpts = struct {
    icon: ?[]const u8 = null,
    placement: Placement = .bottom_start,
    tooltip: ?[]const u8 = null,
};

pub const SpinnerOpts = struct {
    style: SpinnerStyle = .arc,
    color: ?Color = null,  // default the secondary text color for the ring, the text color for dots
    track: ?Color = null,  // the dots' base (a comet's ring, a dot matrix's dots), default `color` at 12%
};

/// C `cui_split_bar_opts` — Split bar: one bar split into parts, with a legend of values and shares.
pub const SplitBarOpts = struct {
    width: Size = .fit,
    height: f32 = 0,
    format: ?[]const u8 = null,
    no_legend: bool = false,
};

/// C `cui_split_button_opts` — ------------------------------------------------------------------------
/// More actions
/// ------------------------------------------------------------------------
/// Split button: a main action with a menu of related actions on the chevron.
/// Returns 0 when the main part is clicked, 1 + i when menu item i is chosen
/// and -1 otherwise.
pub const SplitButtonOpts = struct {
    variant: ButtonVariant = .default,  // default primary
    size: ControlSize = .md,
    icon: ?[]const u8 = null,
    // `item_icons` (const char *const *): pointer field, reach it via zui.raw
    disabled: bool = false,
};

/// C `cui_spotlight_opts` — Spotlight card: a soft light follows the pointer across the card and lights
/// the nearest stretch of its border. beam sends a light around the edge.
pub const SpotlightOpts = struct {
    width: Size = .fit,
    height: Size = .fit,
    pad: f32 = 0,
    gap: f32 = 0,
    color: ?Color = null,
    beam: bool = false,  // a light travels around the card's edge all the time
};

/// C `cui_stack_frame` — ---- Stack trace ----
/// An exception and its call stack: the error's type and message, then each
/// frame's function and position. Runs of library frames fold into one row.
/// A frame with source opens to show the lines around it, the failing line
/// marked; the first frame of your own code starts open. A button copies the
/// whole trace as text.
pub const StackFrame = struct {
    function: ?[]const u8 = null,  // name of the function; `NULL` or "" shows as <anonymous>
    file: ?[]const u8 = null,  // path shown with the line and column; on a phone only the file's name
    line: i32 = 0,  // 1 based; 0 leaves it out
    column: i32 = 0,  // 1 based; 0 leaves it out
    external: bool = false,  // library or runtime code
    // `source` (const char *const *): pointer field, reach it via zui.raw
    source_count: i32 = 0,  // number of lines in `source`
    source_first: i32 = 0,  // line number of source[0]
};

pub const StackTraceOpts = struct {
    width: Size = .fit,
    title: ?[]const u8 = null,  // "TypeError"
    message: ?[]const u8 = null,  // "Cannot read properties of undefined"
    lang: ?[]const u8 = null,  // highlights the source, as the code block
};

pub const StackTraceResult = struct {
    clicked: i32 = 0,
};

/// C `cui_status_bar_opts` — Status bar: a thin bar along the bottom of a window, with a hairline on
/// top and no fill of its own (put it in a box with the background you want).
/// Items go left to right; cui_status_bar_spacer sends the rest to the right
/// edge.
pub const StatusBarOpts = struct {
    no_border: bool = false,
};

pub const StatusButtonOpts = struct {
    busy_label: ?[]const u8 = null,  // default label + "..."
    success_label: ?[]const u8 = null,  // default "Done"
    error_label: ?[]const u8 = null,  // default "Failed"
    icon: ?[]const u8 = null,
    variant: ButtonVariant = .default,  // default primary
    size: ControlSize = .md,
};

pub const StatusItemOpts = struct {
    icon: ?[]const u8 = null,
    tone: Tone = .neutral,
    tooltip: ?[]const u8 = null,
    disabled: bool = false,
};

/// C `cui_status_progress_opts` — A small progress bar with an optional label. value is 0..1.
pub const StatusProgressOpts = struct {
    label: ?[]const u8 = null,
    indeterminate: bool = false,
    width: f32 = 0,
};

/// C `cui_status_spinner_opts` — Status spinner: a dither ring while the status is busy that resolves when the work ends: it
/// fills to a disc in the success color with a check, or the danger color with a cross, holds
/// it for a moment and dissolves away. It keeps its space throughout. Returns true while it
/// shows something, so an app can stop calling it after a result.
/// cui_status_spinner(ui, "save", saving ? CUI_STATUS_BUSY : ok ? CUI_STATUS_SUCCESS : CUI_STATUS_ERROR);
/// Idle shows nothing. Reduced motion shows the ring still and the result at once.
pub const StatusSpinnerOpts = struct {
    size: f32 = 0,  // points, default 20
    color: ?Color = null,  // the ring while busy, default the text color
    keep: bool = false,  // the check or cross stays instead of dissolving away
};

pub const StatusTagOpts = struct {
    size: ControlSize = .md,  // CUI_SIZE_SM is 24 points high, for tables and tag groups; default 30
    removable: bool = false,  // the tag becomes a button that shows an x on hover: the call returns true when it is clicked, or on Enter, Delete or Backspace
    icon: ?[]const u8 = null,  // instead of the state's icon
    tone: Tone = .neutral,  // instead of the state's color; 0 keeps it (gray for CUI_TAG_CUSTOM)
    id: ?[]const u8 = null,  // identity of a removable tag when two share a label
};

/// C `cui_step_slider_opts` — Step slider: a few discrete stops marked with dots; the thumb snaps to each and glides
/// between them. Arrows move one stop, Home and End go to the ends. Returns CUI_WELL_* flags.
/// cui_step_slider(ui, "Variations", &n, 1, 4, .tool = CUI_ICON_REFRESH_CW, .tool_tooltip = "Generate");
pub const StepSliderOpts = struct {
    // `labels` (const char *const *): pointer field, reach it via zui.raw
    format: ?[]const u8 = null,  // printf format for the value, default "%d"
    value: ?[]const u8 = null,  // text at the right of the label instead
    tool: ?[]const u8 = null,  // icon of a button after the track; a click returns CUI_WELL_ACTION
    tool_tooltip: ?[]const u8 = null,
    tool_on: bool = false,
    plain: bool = false,
    disabled: bool = false,
};

/// C `cui_strings` — Text the components show, for another language. CUI keeps the pointer (the
/// table must outlive its use) and reads it every frame, so switching language
/// is one call. An entry left NULL falls back to English, so a partial table is
/// fine. Weeks start on Monday, as in every CUI calendar. NULL restores English.
/// static const cui_strings es = { .month = { "enero", "febrero", ... }, .today = "Hoy" };
/// cui_set_strings(ui, &es);
/// Used by the date picker, date range picker, month and week calendars, gantt,
/// calendar heatmap and file browser. A component's own option (such as the
/// month calendar's month_names) wins over the table.
pub const Strings = struct {
    // `const char *month[12]` (arr): unsupported field type, reach it via zui.raw
    // `const char *month_short[12]` (arr): unsupported field type, reach it via zui.raw
    // `const char *weekday[7]` (arr): unsupported field type, reach it via zui.raw
    // `const char *weekday_short[7]` (arr): unsupported field type, reach it via zui.raw
    // `const char *weekday_min[7]` (arr): unsupported field type, reach it via zui.raw
    today: ?[]const u8 = null,  // "Today"
};

/// C `cui_swipe_action` — Swipe actions: drag a row sideways (or swipe on a trackpad) to reveal
/// actions behind it. A long swipe triggers the first action. The row content
/// goes between begin and end; end returns the chosen action: 0..left_count-1
/// for left actions, 100 + i for right actions, or -1.
pub const SwipeAction = struct {
    icon: ?[]const u8 = null,
    label: ?[]const u8 = null,
    tone: Tone = .neutral,
};

/// C `cui_tab_bar_item` — Bottom tab bar for compact layouts, with a pill that glides to the selection.
pub const TabBarItem = struct {
    icon: ?[]const u8 = null,
    label: ?[]const u8 = null,
    badge: i32 = 0,  // a count on the icon ("9+" above 9); 0 for none
};

pub const TabBarOpts = struct {
    width: Size = .fit,
    labels_on_selected_only: bool = false,  // only the selected tab shows its label; the others show just their icon
};

/// C `cui_table_column` — Table: sortable headers and selectable rows show keyboard focus.
pub const TableColumn = struct {
    title: ?[]const u8 = null,  // text of the column's header
    width: Size = .fit,  // default fill
    @"align": TextAlign = .start,
    sortable: bool = false,
};

pub const TableOpts = struct {
    sort: ?*c.cui_table_sort = null,  // optional, updated when a sortable header is clicked
    height: Size = .fit,  // scrolls when set
    striped: bool = false,
    compact: bool = false,  // rows at least 36 points tall instead of 44
    selectable: bool = false,  // rows take keyboard focus and show the hand cursor (pass the chosen row's state to `cui_table_row`)
};

pub const TableSort = struct {
    column: i32 = 0,
    descending: bool = false,
};

pub const TabsOpts = struct {
    variant: TabsVariant = .underline,
    // `icons` (const char *const *): pointer field, reach it via zui.raw
    full_width: bool = false,
};

/// C `cui_tag_opts` — Tag input: tags are stored comma separated in buf. Enter or comma adds the
/// typed tag, Backspace on an empty field removes the last one.
pub const TagOpts = struct {
    label: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    max_tags: i32 = 0,  // most tags the field holds; once reached it takes no more typing. 0 means no limit
    width: Size = .fit,
};

pub const TerminalBuffer = struct {
    // `text` (char *): pointer field, reach it via zui.raw
    text_cap: u32 = 0,  // size of `text` in bytes
    lines: ?*c.cui_terminal_line = null,  // the line records given to `cui_terminal_init`
    line_cap: i32 = 0,  // how many records `lines` has room for; 0 when the buffer cannot be used
    first: i32 = 0,  // ring of lines; the last one is still being written
    count: i32 = 0,  // ring of lines; the last one is still being written
    end: u32 = 0,  // where the next byte goes
    total: u64 = 0,  // lines ever started
    mode: u8 = 0,  // parser: text, escape, CSI or OSC
    seq_n: u8 = 0,  // bytes of `seq` read so far
    // `char seq[30]` (arr): unsupported field type, reach it via zui.raw
    cr: bool = false,  // a \r was seen: the next character starts the line over
};

/// C `cui_terminal_line` — ---- Terminal ----
/// Terminal: program output with ANSI colors over an input line with a
/// prompt and history, for consoles, REPLs and build tools. Output goes into
/// a buffer you own (appending never allocates; the oldest lines go when it
/// is full) and is parsed as it arrives: \n starts a line, \r returns to its
/// start (progress bars redraw in place), \t, \b, and ESC [ ... m sets
/// colors and styles (16 colors, 256 and 24-bit; bold, dim, italic,
/// underline, inverse). Other escape sequences are skipped.
/// static char text[512 * 1024]; static cui_terminal_line lines[8192];
/// static cui_terminal_buffer term;
/// cui_terminal_init(&term, text, sizeof text, lines, 8192);    // once
/// cui_terminal_write(&term, output, n);                          // as output arrives
/// cui_terminal_result r = cui_terminal(ui, "term", &term, .height = 360);
/// if (r.command) run_command(r.command);                         // echoed for you
/// Long lines wrap. The view follows the newest line until you scroll up.
/// Drag to select, Ctrl+C copies the selection (or, with none, sets
/// r.interrupt), Ctrl+L clears, Up and Down walk the history and clicking the
/// output puts the keyboard in the input line. Only the rows in view are
/// drawn. Text is left to right, one cell per character.
pub const TerminalLine = struct {
    offset: u32 = 0,  // where the line's bytes start in the buffer's `text`
    len: u32 = 0,  // bytes of the line, with its color sequences
    cols: u32 = 0,  // character cells the line takes, before wrapping
};

pub const TerminalOpts = struct {
    width: Size = .fit,  // default fill
    height: f32 = 0,  // default 320; negative fills the space
    size: f32 = 0,  // font size, default 13
    prompt: ?[]const u8 = null,  // default "$ "
    no_input: bool = false,  // output only
};

pub const TerminalResult = struct {
    command: ?[]const u8 = null,  // the line entered (Enter), already echoed; valid this frame
    interrupt: bool = false,  // Ctrl+C with nothing selected
};

pub const TestExplorerOpts = struct {
    width: Size = .fit,
    height: f32 = 0,
};

pub const TestExplorerResult = struct {
    selected: i32 = 0,  // items, or -1
    activated: i32 = 0,  // items, or -1
    run: i32 = 0,  // item whose run button was pressed this frame, or -1
    run_all: bool = false,  // the Run all button was pressed this frame
    passed: i32 = 0,  // tests, not suites
    failed: i32 = 0,  // tests, not suites
    skipped: i32 = 0,  // tests, not suites
    total: i32 = 0,  // tests, not suites
};

/// C `cui_test_item` — ---- Test explorer ----
/// Test results as a tree: suites fold, each test shows its status and time,
/// and a failure shows its message under it. A suite's status sums up its
/// tests. The toolbar runs everything, counts results and filters by status
/// and by name. Hover a row for its run button. Only the rows in view are
/// built. Up and Down move, Left and Right fold, Enter activates. Items are in
/// tree order with their depth; the statuses are the pipeline's.
pub const TestItem = struct {
    name: ?[]const u8 = null,  // name of the suite or test; the toolbar's field filters by it
    depth: i32 = 0,  // 0 for the top suites
    status: JobStatus = .pending,  // a suite's own status is ignored when it has tests
    duration: f32 = 0,  // seconds, negative when it has not run
    message: ?[]const u8 = null,  // why it failed, may be NULL
};

/// C `cui_text_fx_opts` — ------------------------------------------------------------------------
/// Motion and text effects
/// ------------------------------------------------------------------------
/// All of these respect reduced motion: they show their final state.
pub const TextFxOpts = struct {
    font: i32 = 0,  // default `CUI_FONT_BODY` (0)
    size: f32 = 0,
    color: ?Color = null,
    width: Size = .fit,
    nowrap: bool = false,  // keeps the text on one line instead of wrapping it
    speed: f32 = 0,  // shimmer: sweeps per second; typewriter: characters per second
    delay: f32 = 0,  // seconds before it starts
    caret: bool = false,  // typewriter: a blinking caret while typing
};

/// C `cui_text_mark` — ---- Code editor ----
/// Code editor: editable code with the code block's highlighting, a line
/// number gutter and a monospace grid, for shader editors, script consoles
/// and config files. You own the text: a NUL terminated buffer and its
/// capacity, edited in place.
/// static char src[64 * 1024] = "void main() {\n}\n";
/// cui_code_editor_result r = cui_code_editor(ui, "shader", src, sizeof src,
/// .lang = "c", .height = 360);
/// if (r.changed) recompile(src);
/// cui_textf(ui, "Ln %d, Col %d", r.line, r.column);
/// With .lang = "text", indentation is preserved without syntax colors;
/// tabs advance to the next tab_size column stop.
/// Lines never wrap; long ones scroll sideways while the gutter stays. Only
/// the lines in view are tokenized and drawn, so files of tens of thousands
/// of lines stay fast. An edit that would not fit in the capacity is refused
/// whole (r.refused). Keys when focused: arrows, Ctrl+arrows by word, Home
/// (first character, then column 0), End, Page Up/Down, Ctrl+Home/End;
/// Shift extends; Ctrl+A; Ctrl+C/X/V (the whole line without a selection);
/// Ctrl+Z, Ctrl+Shift+Z or Ctrl+Y; Tab and Shift+Tab indent and outdent the
/// selected lines; Enter keeps the indentation (a level deeper after an
/// opening bracket, or a colon in Python); Ctrl+F finds, Ctrl+G goes to a
/// line; Esc closes the bar, else clears the selection, else lets the next
/// Tab move focus. Double-click selects a word, triple-click or the gutter a
/// line. Read only keeps selection, copy and find.
/// a highlighted range of bytes: color 0 is the accent, 1 to 6 the series colors
pub const TextMark = struct {
    start: i32 = 0,
    end: i32 = 0,
    color: i32 = 0,
};

pub const TextMetrics = struct {
    width: f32 = 0,
    height: f32 = 0,
    ascent: f32 = 0,
    descent: f32 = 0,
    line_height: f32 = 0,
};

/// C `cui_text_style` — One text style of the style menu.
pub const TextStyle = struct {
    name: ?[]const u8 = null,  // "Header"
    size: f32 = 0,  // the size it sets in your document, shown in the readout, e.g. 44
    preview_size: f32 = 0,  // the size of its name in the menu, in points
    font: i32 = 0,  // the font of its name in the menu
};

/// C `cui_ticker_item` — Ticker: items that scroll by continuously, pausing on hover.
pub const TickerItem = struct {
    label: ?[]const u8 = null,
    value: ?[]const u8 = null,  // text after the label in medium weight, e.g. a price; may be `NULL`
    delta: f32 = 0,  // percent change, shown with a trend arrow in green or red; 0 hides it
    lower_is_better: bool = false,  // a fall in `delta` is good news: it shows green, and a rise red
};

pub const TickerOpts = struct {
    speed: f32 = 0,  // points per second, default 40
    height: f32 = 0,
};

/// C `cui_tile_opts` — Control tile: a large toggle with an icon, a label and a state line.
pub const TileOpts = struct {
    icon: ?[]const u8 = null,
    detail: ?[]const u8 = null,  // the state line under the label, default "On" or "Off"
    color: ?Color = null,
    width: Size = .fit,
    wide: bool = false,  // icon beside the text in a lower tile, instead of above it
};

pub const TimeHistogramOpts = struct {
    width: Size = .fit,
    height: f32 = 0,  // default 140
    utc: bool = false,  // label times in UTC instead of local time
};

pub const TimeHistogramResult = struct {
    selection_changed: bool = false,  // `*sel_start` or `*sel_end` changed this frame (a drag, or a click that cleared it)
    hovered: i32 = 0,  // bucket, or -1
};

/// C `cui_time_opts` — Time picker: a field that opens hour and minute columns. hour is 0..23.
pub const TimeOpts = struct {
    label: ?[]const u8 = null,
    twelve_hour: bool = false,  // shows 1 to 12 with AM and PM (as in "2:30 PM"); `*hour` stays 0..23
    minute_step: i32 = 0,  // minutes between the entries of the minute column, default 5
    width: Size = .fit,
};

pub const TimelineEditorOpts = struct {
    start: f32 = 0,  // the sequence in seconds; both 0 = 0..10
    end: f32 = 0,  // the sequence in seconds; both 0 = 0..10
    fps: f32 = 0,  // frames per second, default 30: snapping, stepping and frame labels
    ruler: i32 = 0,  // cui_timeline_ruler
    view: ?*c.cui_timeline_view = null,  // NULL keeps it in the editor
    // `in` (float *): pointer field, reach it via zui.raw
    // `out` (float *): pointer field, reach it via zui.raw
    // `current_track` (int *): pointer field, reach it via zui.raw
    // `current_key` (int *): pointer field, reach it via zui.raw
    width: Size = .fit,  // default fill
    height: f32 = 0,  // default: fits every track (up to 360)
    row_height: f32 = 0,  // default 26
    track_width: f32 = 0,  // track list, default 184; narrower (then icons only) on a narrow editor
    toggles: bool = false,  // hide and lock buttons on every track
    free_drag: bool = false,  // drags and scrubbing do not snap to frames
};

pub const TimelineEditorResult = struct {
    changed: bool = false,  // keys or clips moved, were added or removed, or a track flag changed
    time_changed: bool = false,  // *time moved (scrub, ruler click, keys)
    scrubbing: bool = false,  // the playhead is being dragged
    play_toggled: bool = false,  // Space: start or stop playback
    selection_changed: bool = false,  // a key or clip was selected or unselected this frame
    view_changed: bool = false,  // the visible time range or the row scroll changed (zoom, pan, fit)
    keys_moved: bool = false,  // selected keys moved this frame (drag or Alt+arrows)
    added_track: i32 = 0,  // the key added this frame (double click), or -1
    added_key: i32 = 0,  // the key added this frame (double click), or -1
    removed_keys: i32 = 0,  // how many were removed this frame (Delete)
    removed_clips: i32 = 0,  // how many were removed this frame (Delete)
    clip_track: i32 = 0,  // the clip moved or trimmed this frame, or -1
    clip: i32 = 0,  // the clip moved or trimmed this frame, or -1
    toggled: i32 = 0,  // the track whose collapsed, muted or locked flag changed, or -1
    current_track: i32 = 0,  // track of the key last clicked or added, or -1
    current_key: i32 = 0,  // index of that key in its track, or -1
    hovered_track: i32 = 0,  // the key under the pointer, or -1
    hovered_key: i32 = 0,  // the key under the pointer, or -1
};

/// C `cui_timeline_opts` — Activity timeline item.
pub const TimelineOpts = struct {
    time: ?[]const u8 = null,  // muted text at the right of the title, e.g. "2h ago"
    description: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    tone: Tone = .neutral,
    last: bool = false,  // the final item: no connector line below its dot and no space after it
};

pub const TimelineView = struct {
    start: f32 = 0,  // visible time range; end <= start fits the sequence
    end: f32 = 0,  // visible time range; end <= start fits the sequence
    scroll: f32 = 0,  // rows scrolled off the top, in points
};

pub const ToastOpts = struct {
    description: ?[]const u8 = null,
    tone: Tone = .neutral,
    duration: f32 = 0,  // seconds, default 4; negative = until dismissed
    action: ?[]const u8 = null,  // optional action button label
    show_timer: bool = false,  // a draining line shows how long the action stays (undo)
};

/// C `cui_toc_item` — Table of contents for a scroll area: highlights the section in view on a
/// progress rail, and scrolls to a section when clicked. Put
/// cui_toc_anchor(ui, "anchor") at each heading inside the scroll area, and
/// call cui_toc in the same scope as the scroll area. Returns the active index.
pub const TocItem = struct {
    title: ?[]const u8 = null,  // the entry's text in the list
    anchor: ?[]const u8 = null,  // the name given to `cui_toc_anchor` at that section's heading
    level: i32 = 0,  // indentation: 0 for a top level section, up to 4 (12 points each)
};

/// C `cui_toggle_group_opts` — Toggle group: a row of toggles (bold, italic...). values[i] is toggled
/// when item i is clicked; with exclusive set exactly one stays on. Labels
/// become tooltips when icon_only is set. Left and Right move focus one item.
/// Returns true when a value changed.
pub const ToggleGroupOpts = struct {
    // `icons` (const char *const *): pointer field, reach it via zui.raw
    exclusive: bool = false,  // clicking an item turns it on and every other one off, like radio buttons
    icon_only: bool = false,  // items that have an icon show only the icon, with their label as the tooltip
    size: ControlSize = .md,
};

pub const ToolCallOpts = struct {
    status: TaskStatus = .pending,
    icon: ?[]const u8 = null,
    detail: ?[]const u8 = null,  // muted text after the tool's name, e.g. the file or query it works on
    input: ?[]const u8 = null,  // what was sent to the tool; the row then opens to show it (as JSON when it parses)
    output: ?[]const u8 = null,  // what the tool returned, shown when open; labelled "Error" when the status is failed
    seconds: f32 = 0,  // how long the call took, shown at the end of the row unless it is pending; 0 hides it
};

pub const ToolOpts = struct {
    label: ?[]const u8 = null,  // text on the button (icon may be NULL); also its name in the overflow menu
    tooltip: ?[]const u8 = null,  // the name of an icon only button
    shortcut: ?[]const u8 = null,  // shown in the tooltip, e.g. "Ctrl B"
    // `toggle` (bool *): pointer field, reach it via zui.raw
    disabled: bool = false,
    tone: Tone = .neutral,  // icon and label color: always on a plain button (CUI_TONE_DANGER for delete), only while on for a toggle
    flyout: bool = false,  // the corner mark that says the button opens more options (cui_flyout_mark)
};

pub const ToolbarOpts = struct {
    no_border: bool = false,  // plain style: no hairline under the strip
    style: ToolbarStyle = .plain,
};

/// C `cui_toolbar_radio_opts` — An inset set of icons of which one is on, like a segmented control. Left and
/// Right move the choice. Returns true when *index changed. In the overflow menu
/// each icon is an item named by its label.
pub const ToolbarRadioOpts = struct {
    // `labels` (const char *const *): pointer field, reach it via zui.raw
};

pub const TourOpts = struct {
    width: f32 = 0,  // the card, default 300
    padding: f32 = 0,  // room around the target inside the spotlight, default 6
    block_target: bool = false,  // the spotlighted control ignores the pointer too
    next_label: ?[]const u8 = null,  // default "Next", "Back", "Done"
    back_label: ?[]const u8 = null,  // default "Next", "Back", "Done"
    done_label: ?[]const u8 = null,  // default "Next", "Back", "Done"
    count_format: ?[]const u8 = null,  // the step count, default "%d of %d" (step, then total)
};

/// C `cui_tour_step` — Guided tour: a spotlight on one control at a time, with a card beside it
/// that says what the control does, for onboarding and "what's new". The
/// rest of the window dims; the spotlight glides from one control to the
/// next. Call it after the controls it points at, every frame while *step is
/// 0 or more; it sets *step to -1 when the tour ends. Right or Enter go to the
/// next step, Left goes back and Esc ends the tour.
/// static int step = 0;
/// cui_button(ui, "Export");  steps[1].target = cui_last_id(ui);
/// ...
/// if (step >= 0) cui_tour(ui, "intro", steps, 4, &step);
pub const TourStep = struct {
    target: u32 = 0,  // the control to point at (cui_last_id after it); 0: a card in the middle
    title: ?[]const u8 = null,  // heading of the step's card; `NULL` or "" leaves it out
    body: ?[]const u8 = null,  // the explanation under the title; wraps to the card's width
    placement: Placement = .bottom_start,  // the card's side of the target, default below it
};

pub const TraceLink = struct {
    from: i32 = 0,  // indices into the spans: from the end of `from` to the start of `to`
    to: i32 = 0,  // indices into the spans: from the end of `from` to the start of `to`
    tone: Tone = .neutral,  // the curve's color; CUI_TONE_NEUTRAL (0): the emphasis color
    width: f32 = 0,  // line width in points; 0: 1.25
    dashed: bool = false,  // a weaker or inferred dependency
};

pub const TraceMarker = struct {
    name: ?[]const u8 = null,
    time: f64 = 0,
    tone: Tone = .neutral,
};

pub const TraceOpts = struct {
    width: Size = .fit,
    height: f32 = 0,  // default 320
    row_height: f32 = 0,  // default 20
    markers: []const TraceMarker = &.{},  // moments drawn as lines across every lane, named in a strip under the ruler
    links: []const TraceLink = &.{},  // dependencies drawn as curves between spans
};

pub const TraceResult = struct {
    selection_changed: bool = false,  // `*selected` changed this frame (click or keys)
    view_changed: bool = false,  // time range, scroll position, or measurement in `*view` changed
    hovered: i32 = 0,  // span under the pointer, or -1
    hovered_link: i32 = 0,  // link under the pointer (when no span is), or -1
};

pub const TraceSpan = struct {
    name: ?[]const u8 = null,  // drawn in the span when it fits, and in its tooltip
    start: f64 = 0,  // when the span begins, in seconds
    end: f64 = 0,  // when the span ends, in seconds; end >= start
    track: i32 = 0,  // index into the tracks: the lane the span is drawn in
    depth: i32 = 0,  // row within the lane, 0 = top; a child lies within its parent
    color_key: u32 = 0,  // picks the color; 0: hashed from the name
};

pub const TreeNode = struct {
    parent: i32 = 0,  // -1 for a top level node
    first_child: i32 = 0,  // -1 when it has none, or none loaded yet
    next_sibling: i32 = 0,  // -1 for the last one
    flags: u32 = 0,  // CUI_TREE_*
};

/// C `cui_tree_opts` — Tree view node.
pub const TreeOpts = struct {
    icon: ?[]const u8 = null,
    leaf: bool = false,  // a node without children: no chevron, a file icon, and `*open` is left alone
    selected: bool = false,  // drawn with the active background and medium weight text
};

pub const TreeTableEvents = struct {
    activated: i32 = 0,  // node chosen with Enter or a double click, else -1
    expanded: i32 = 0,  // a node opened or closed this frame, else -1
    collapsed: i32 = 0,  // a node opened or closed this frame, else -1
    load: []const i32 = &.{},  // nodes to load children for (each now has CUI_TREE_LOADING), valid this frame
    selection_changed: bool = false,  // a node's `CUI_TREE_SELECTED` flag changed this frame
    sort_changed: bool = false,  // re-sort every sibling list by *sort
    // `dropped` (const int *): pointer field, reach it via zui.raw
    drop_count: i32 = 0,  // number of nodes in `dropped`, 0 without a drop
    drop_target: i32 = 0,  // they go CUI_TREE_DROP_BEFORE, _INSIDE (as the last children) or _AFTER this node, else -1
    drop_where: i32 = 0,  // they go CUI_TREE_DROP_BEFORE, _INSIDE (as the last children) or _AFTER this node, else -1
};

pub const TreeTableOpts = struct {
    width: Size = .fit,  // default fill
    height: Size = .fit,  // default fill
    row_height: f32 = 0,  // default 32
    root: i32 = 0,  // the first top level node, default 0
    sort: ?*c.cui_table_sort = null,  // sortable headers set it; sort each level yourself (cui_tree_sort)
    // `cursor` (int *): pointer field, reach it via zui.raw
    guides: bool = false,  // quiet vertical lines for each indentation level
    // `const char *(*label)(void *user, int node)`: function-pointer field, set via zui.raw if needed
    // `user` (void *): pointer field, reach it via zui.raw
    draggable: bool = false,  // rows drag to move nodes; the drop arrives in cui_tree_table_events
    // `bool (*can_drop)(void *user, int target, int where)`: function-pointer field, set via zui.raw if needed
};

pub const TreemapOpts = struct {
    width: Size = .fit,
    height: f32 = 0,  // default 300
    format: ?[]const u8 = null,  // the values, e.g. "%.0f KB"
    // `selected` (int *): pointer field, reach it via zui.raw
};

pub const UptimeOpts = struct {
    width: Size = .fit,
    last_day: Date = .{},
};

pub const UptimeResult = struct {
    service: i32 = 0,
    day: i32 = 0,
};

/// C `cui_uptime_service` — ---- Uptime bars ----
/// A status page: each service with its current state, its uptime over the
/// period, and one bar per day colored by availability (gray without data).
/// Hover a bar for its day and uptime. On a narrow panel only the most recent
/// days that fit are shown.
pub const UptimeService = struct {
    name: ?[]const u8 = null,  // shown above the service's bars
    days: []const f32 = &.{},  // oldest first: the fraction of the day it was up, 0..1; negative: no data
};

/// C `cui_user_menu_opts` — User menu: an avatar, a name and a line of detail that opens a menu of
/// account actions. Put menu items between begin and end.
pub const UserMenuOpts = struct {
    detail: ?[]const u8 = null,  // second line under the name, e.g. an email address; also in the menu's header
    status: ?[]const u8 = null,  // status dot on the avatar: "online", "busy", "away" or anything else (gray)
    avatar: usize = 0,  // picture for the avatar instead of the name's initials
    compact: bool = false,  // only the avatar as the button, as wide as it needs; the menu then opens below it
    placement: Placement = .bottom_start,
    width: f32 = 0,
};

/// C `cui_veil_opts` — Veil: covers what is built inside it (a picture, a secret such as an API key, a spoiler)
/// with a slowly moving dither in muted tones that keeps its space. A click, or Enter or
/// Space, reveals it: the veil dissolves dot by dot in about a quarter of a second, and
/// comes back the same way when *revealed is set to false again. While covered, the content
/// takes no clicks and no keyboard focus. Reduced motion holds the noise still and reveals at once.
/// static bool shown;
/// cui_veil(ui, "photo", &shown, .label = "Sensitive image", .hint = "Click to show", .toggle = true) {
/// cui_image(ui, tex, .width = CUI_PX(240), .height = CUI_PX(150));
/// }
/// cui_veil_begin_ex returns true on the frame a click or a key changed *revealed.
pub const VeilOpts = struct {
    label: ?[]const u8 = null,  // a line in the middle of the veil, e.g. "Sensitive image"; `NULL` for none
    hint: ?[]const u8 = null,  // a smaller line under it, e.g. "Click to show"
    toggle: bool = false,  // a click on the revealed content covers it again
    radius: f32 = 0,  // corners of the veil, default 0
    color: ?Color = null,  // the veil's ground, default the muted surface; its dots are a step toward the text color
    width: Size = .fit,  // default: the content's width
};

/// C `cui_viz_item` — Treemap: rectangles with areas proportional to their values, on neutral tiles graded
/// by size, each with its label, value and share. The accent marks only the hovered or
/// selected tile; an item's own `color` fills its tile instead.
pub const VizItem = struct {
    label: ?[]const u8 = null,
    value: f32 = 0,  // the item's amount: its area, length or share, by chart (activity rings: 1 is a full turn)
    color: ?Color = null,
};

pub const VoiceNoteOpts = struct {
    mine: bool = false,  // a message you sent: tinted with the accent and placed at the end of the row
    width: Size = .fit,  // default 330 points, narrower in a narrower container
};

/// C `cui_voice_orb_opts` — Deprecated: use the voice session (cui_voice_session), the voice waveform
/// (cui_voice_wave) or the composer's recorder instead. Kept so existing code
/// builds; it gets no new features.
/// Voice orb: a living shape for voice modes. level is the input or output
/// loudness (0..1). Returns true when clicked.
pub const VoiceOrbOpts = struct {
    size: f32 = 0,
    color: ?Color = null,
};

pub const VoiceSessionOpts = struct {
    // `owners` (const uint8_t *): pointer field, reach it via zui.raw
    label: ?[]const u8 = null,  // text for the state instead of "Listening", "Thinking...", "Speaking", "Muted" or "Waiting"
    transcript: ?[]const u8 = null,  // the words of the current turn spoken so far, under the strip; `NULL` for none
    upcoming: ?[]const u8 = null,  // the rest of the turn, not spoken yet: dimmed after `transcript`
    speaker: VoiceOwner = .you,  // whose turn the transcript is, named before it
    you: ?[]const u8 = null,  // your name in the legend and the transcript, default "You"
    assistant: ?[]const u8 = null,  // the assistant's name, default "Assistant"
    // `muted` (bool *): pointer field, reach it via zui.raw
    no_end: bool = false,  // leaves the End button out
    width: Size = .fit,  // default fill
};

pub const VoiceWaveOpts = struct {
    clip: bool = false,  // the whole clip resampled to the width, instead of the newest levels scrolling in
    // `progress` (float *): pointer field, reach it via zui.raw
    // `owners` (const uint8_t *): pointer field, reach it via zui.raw
    owner: VoiceOwner = .you,  // whose voice it is: you in the foreground color, the reply in the accent
    color: ?Color = null,  // lit dots in this color instead of the owner's
    pitch: f32 = 0,  // distance between dot centers in points, default 3.6; the strip is 14 pitches tall
    step: f32 = 0,  // how far an arrow key seeks, as a fraction of the clip, default 0.05
    width: Size = .fit,  // default fill
};

/// C `cui_waffle_opts` — Waffle: a 10 x 10 grid of squares split by share, with a legend.
pub const WaffleOpts = struct {
    cell: f32 = 0,  // size of a square in points, default 18
    columns: i32 = 0,  // squares per row, at most 60; default 10
    rows: i32 = 0,  // rows of squares, at most 60; default 10
    format: ?[]const u8 = null,
};

pub const WaterfallOpts = struct {
    width: Size = .fit,
    height: f32 = 0,
    // `selected` (int *): pointer field, reach it via zui.raw
    dom_loaded: f64 = 0,  // seconds; 0: no line
    loaded: f64 = 0,  // seconds; 0: no line
};

pub const WaterfallResult = struct {
    clicked: i32 = 0,  // request clicked this frame, or -1
    activated: i32 = 0,  // request double-clicked or chosen with Enter this frame, or -1
    hovered: i32 = 0,  // request under the pointer, or -1
};

/// C `cui_waveform_opts` — Waveform: bars from peaks (0..1). With progress, the played part is
/// colored and clicking or dragging seeks; returns true when it did.
pub const WaveformOpts = struct {
    width: Size = .fit,
    height: f32 = 0,
    bar: f32 = 0,  // width of each bar in points, default 3
    gap: f32 = 0,
    color: ?Color = null,
};

pub const WeekOpts = struct {
    start_hour: f32 = 0,  // first hour shown, default 7; set together with `end_hour`
    end_hour: f32 = 0,  // last hour shown, default 21; used only when it is greater than `start_hour`
    hour_height: f32 = 0,  // points per hour, default 52
    height: Size = .fit,
    read_only: bool = false,
};

/// C `cui_wheel_opts` — Wheel picker: a drum of options that you drag, scroll or arrow through.
/// Several side by side make a date or time reel.
/// join_left / join_right square off the selection band so wheels placed
/// side by side share one continuous band.
pub const WheelOpts = struct {
    rows: i32 = 0,  // rows in view, made odd so the selected one sits in the middle; default 5
    width: Size = .fit,
    loop: bool = false,  // the items wrap around: after the last comes the first again
    join_left: bool = false,  // squares off the left end of the selection band, to join a wheel on that side
    join_right: bool = false,  // squares off the right end of the selection band, to join a wheel on that side
};
// ==== END GEN:TYPES ====

// ==== GEN:FREE ====

fn zui_end_adapter_accordion_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_accordion_end(h);
}


fn zui_end_adapter_button_group_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_button_group_end(h);
}


fn zui_end_adapter_card_stack_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_card_stack_end(h);
}


fn zui_end_adapter_card_stack_item_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_card_stack_item_end(h);
}


fn zui_end_adapter_carousel_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_carousel_end(h);
}


fn zui_end_adapter_carousel_slide_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_carousel_slide_end(h);
}


fn zui_end_adapter_context_menu_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_context_menu_end(h);
}


fn zui_end_adapter_data_grid_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_data_grid_end(h);
}


fn zui_end_adapter_dialog_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_dialog_end(h);
}


fn zui_end_adapter_dialog_footer_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_dialog_footer_end(h);
}


fn zui_end_adapter_dock_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_dock_end(h);
}


fn zui_end_adapter_dock_panel_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_dock_panel_end(h);
}


fn zui_end_adapter_dockspace_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_dockspace_end(h);
}


fn zui_end_adapter_expandable_card_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_expandable_card_end(h);
}


fn zui_end_adapter_hover_card_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_hover_card_end(h);
}


fn zui_end_adapter_inspector_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_inspector_end(h);
}


fn zui_end_adapter_kanban_card_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_kanban_card_end(h);
}


fn zui_end_adapter_kanban_column_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_kanban_column_end(h);
}


fn zui_end_adapter_menu_bar_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_menu_bar_end(h);
}


fn zui_end_adapter_menu_bar_menu_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_menu_bar_menu_end(h);
}


fn zui_end_adapter_menu_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_menu_end(h);
}


fn zui_end_adapter_node_content_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_node_content_end(h);
}


fn zui_end_adapter_node_editor_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_node_editor_end(h);
}


fn zui_end_adapter_node_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_node_end(h);
}


fn zui_end_adapter_path_bar_menu_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_path_bar_menu_end(h);
}


fn zui_end_adapter_popover_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_popover_end(h);
}


fn zui_end_adapter_reasoning_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_reasoning_end(h);
}


fn zui_end_adapter_reorder_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_reorder_end(h);
}


fn zui_end_adapter_reorder_item_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_reorder_item_end(h);
}


fn zui_end_adapter_sheet_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_sheet_end(h);
}


fn zui_end_adapter_skeleton_group_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_skeleton_group_end(h);
}


fn zui_end_adapter_spotlight_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_spotlight_end(h);
}


fn zui_end_adapter_status_bar_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_status_bar_end(h);
}


fn zui_end_adapter_swipe_item_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_swipe_item_end(h);
}


fn zui_end_adapter_table_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_table_end(h);
}


fn zui_end_adapter_toolbar_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_toolbar_end(h);
}


fn zui_end_adapter_toolbar_group_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_toolbar_group_end(h);
}


fn zui_end_adapter_tree_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_tree_end(h);
}


fn zui_end_adapter_tree_table_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_tree_table_end(h);
}


fn zui_end_adapter_user_menu_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_user_menu_end(h);
}


fn zui_end_adapter_veil_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_veil_end(h);
}


fn zui_end_adapter_virtual_list_end(h: ?*c.cui_ctx) callconv(.c) void {
    _ = c.cui_virtual_list_end(h);
}


pub fn accent_name(accent: Accent) []const u8 {
    return spanOrEmpty(c.cui_accent_name(enumOrInt(c.cui_accent, accent)));
}


/// Color helpers. Mixing is done in OKLab, like CSS color-mix(in oklab).
pub fn oklch(l: f32, color: f32, h_degrees: f32, alpha_mult: f32) Color {
    return colorFromC(c.cui_oklch(l, color, h_degrees, alpha_mult));
}


pub fn mix(a: Color, b: Color, t: f32) Color {
    return colorFromC(c.cui_mix(colorToC(a), colorToC(b), t));
}


pub fn alpha(color: Color, alpha_multiplier: f32) Color {
    return colorFromC(c.cui_alpha(colorToC(color), alpha_multiplier));
}


pub fn date_today() Date {
    return cvtBackStruct(Date, c.cui_date_today());
}


/// Moves nodes, each with its subtree, before, into (after the last child) or
/// after target, keeping their order, and relinks the nodes. Returns the new
/// first top level node. A target that is one of the nodes or inside one,
/// or a node listed twice, moves nothing. Flags stay as they are: open the target yourself if you
/// want the moved nodes in view.
pub fn tree_move(nodes: []c.cui_tree_node, root: i32, move: []const i32, move_count: i32, target: i32, where: i32) i32 {
    return c.cui_tree_move(@ptrCast(nodes.ptr), @intCast(nodes.len), root, move.ptr, move_count, target, where);
}


pub fn fs_list(user: ?*anyopaque, path: [:0]const u8, out: *c.cui_file_entry, cap: i32, names: [:0]u8, names_cap: usize, hidden: bool) i32 {
    return c.cui_fs_list(user, path.ptr, @ptrCast(out), cap, names.ptr, names_cap, hidden);
}


pub fn diff_compute(old_text: [:0]const u8, old_len: usize, new_text: [:0]const u8, new_len: usize, flags: u32, hunks: *c.cui_diff_hunk, cap: i32, stats: *c.cui_diff_stats) i32 {
    return c.cui_diff_compute(old_text.ptr, old_len, new_text.ptr, new_len, flags, @ptrCast(hunks), cap, @ptrCast(stats));
}


pub fn diff_words(old_line: [:0]const u8, old_len: i32, new_line: [:0]const u8, new_len: i32, old_ranges: *c.cui_diff_range, old_count: *i32, new_ranges: *c.cui_diff_range, new_count: *i32, cap: i32) bool {
    return c.cui_diff_words(old_line.ptr, old_len, new_line.ptr, new_len, @ptrCast(old_ranges), @ptrCast(old_count), @ptrCast(new_ranges), @ptrCast(new_count), cap);
}


/// Resamples a clip to `columns` levels the way the clip strip does (the loudest
/// level of each stretch; a stretch with no audio stays CUI_VOICE_SILENT), for
/// keeping a short waveform with a message. Returns the number written.
pub fn voice_resample(levels: []const f32, out: *f32, columns: i32) i32 {
    return c.cui_voice_resample(levels.ptr, @intCast(levels.len), @ptrCast(out), columns);
}


pub fn date_to_days(d: Date) i32 {
    const zp0_c = cvtFree(c.cui_date, d);
    return c.cui_date_to_days(zp0_c);
}


pub fn date_from_days(days: i32) Date {
    return cvtBackStruct(Date, c.cui_date_from_days(days));
}


pub fn path_has_extension(path: [:0]const u8, accept: [:0]const u8) bool {
    return c.cui_path_has_extension(path.ptr, accept.ptr);
}


pub fn key_name(key: Key) []const u8 {
    return spanOrEmpty(c.cui_key_name(enumOrInt(c.cui_key, key)));
}


pub fn log_init(buf: *c.cui_log_buffer, lines: *c.cui_log_line, line_cap: i32, text: [:0]u8, text_cap: usize) void {
    c.cui_log_init(@ptrCast(buf), @ptrCast(lines), line_cap, text.ptr, text_cap);
}


/// Appends len bytes (-1: up to the terminator) stamped with time.
pub fn log_append_text(buf: *c.cui_log_buffer, level: LogLevel, time: f64, text: []const u8) void {
    c.cui_log_append_text(@ptrCast(buf), enumOrInt(c.cui_log_level, level), time, text.ptr, @intCast(text.len));
}


pub fn log_clear(buf: *c.cui_log_buffer) void {
    c.cui_log_clear(@ptrCast(buf));
}


pub fn terminal_init(t: *c.cui_terminal_buffer, text: [:0]u8, text_cap: usize, lines: *c.cui_terminal_line, line_cap: i32) void {
    c.cui_terminal_init(@ptrCast(t), text.ptr, text_cap, @ptrCast(lines), line_cap);
}


pub fn terminal_write(t: *c.cui_terminal_buffer, data: []const u8) void {
    c.cui_terminal_write(@ptrCast(t), data.ptr, @intCast(data.len));
}


pub fn terminal_clear(t: *c.cui_terminal_buffer) void {
    c.cui_terminal_clear(@ptrCast(t));
}


/// Sorts spans into the order the graph needs: by depth, then start (longer
/// first on ties).
pub fn flame_sort(spans: []c.cui_flame_span) void {
    c.cui_flame_sort(@ptrCast(spans.ptr), @intCast(spans.len));
}


/// The curve's value at x: exactly what the editor draws. keys sorted by x.
pub fn curve_eval(keys: []const CurveKey, x: f32) f32 {
    const zp0_c = std.heap.page_allocator.alloc(c.cui_curve_key, keys.len) catch @panic("zui: oom");
    defer std.heap.page_allocator.free(zp0_c);
    for (keys, 0..) |*it, ii| zp0_c[ii] = cvtFree(c.cui_curve_key, it.*);
    return c.cui_curve_eval(zp0_c.ptr, @intCast(keys.len), x);
}


/// The color at t: exactly what the ramp shows (each channel, alpha too,
/// interpolated in sRGB between the stops on either side; the end colors
/// continue past the first and last stop).
pub fn gradient_eval(stops: []const GradientStop, t: f32) Color {
    const zp0_c = std.heap.page_allocator.alloc(c.cui_gradient_stop, stops.len) catch @panic("zui: oom");
    defer std.heap.page_allocator.free(zp0_c);
    for (stops, 0..) |*it, ii| zp0_c[ii] = cvtFree(c.cui_gradient_stop, it.*);
    return colorFromC(c.cui_gradient_eval(zp0_c.ptr, @intCast(stops.len), t));
}


/// the operators of a type: text "is", "is not", "contains", "does not contain",
/// "starts with", "ends with"; number "=", "!=", ">", ">=", "<", "<="; choice
/// "is", "is not"; bool "is true", "is false". NULL past the last.
pub fn query_op_name(@"type": QueryType, op: i32) []const u8 {
    return spanOrEmpty(c.cui_query_op_name(enumOrInt(c.cui_query_type, @"type"), op));
}


pub fn query_text(fields: []const c.cui_query_field, nodes: []const c.cui_query_node, out: [:0]u8, cap: usize) usize {
    return c.cui_query_text(@ptrCast(fields.ptr), @intCast(fields.len), @ptrCast(nodes.ptr), @intCast(nodes.len), out.ptr, cap);
}


/// values[i] is the record's value for field i, as text ("1", "true", "open").
pub fn query_match(fields: []const c.cui_query_field, nodes: []const c.cui_query_node, values: []const []const u8) bool {
    var zp4_total: usize = 0;
    for (values) |v| zp4_total += v.len + 1;
    const zp4_blob = std.heap.page_allocator.alloc(u8, zp4_total + 1) catch @panic("zui: oom");
    defer std.heap.page_allocator.free(zp4_blob);
    const zp4_c = std.heap.page_allocator.alloc([*c]const u8, values.len + 1) catch @panic("zui: oom");
    defer std.heap.page_allocator.free(zp4_c);
    var zp4_off: usize = 0;
    for (values, 0..) |v, ii| {
        @memcpy(zp4_blob[zp4_off..zp4_off + v.len], v);
        zp4_blob[zp4_off + v.len] = 0;
        zp4_c[ii] = @ptrCast(zp4_blob[zp4_off..zp4_off + v.len :0].ptr);
        zp4_off += v.len + 1;
    }
    zp4_c[values.len] = null;
    return c.cui_query_match(@ptrCast(fields.ptr), @intCast(fields.len), @ptrCast(nodes.ptr), @intCast(nodes.len), zp4_c.ptr);
}


/// The first time after `after` (Unix seconds) the expression matches, in the
/// time zone that is utc_offset minutes east of UTC. Supports *, lists,
/// ranges, steps and the names JAN-DEC and SUN-SAT. False when it is invalid
/// or never runs in the next five years.
pub fn cron_next(cron: [:0]const u8, after: i64, utc_offset: i32, next: *i64) bool {
    return c.cui_cron_next(cron.ptr, after, utc_offset, @ptrCast(next));
}


pub fn trace_sort(spans: []c.cui_trace_span) void {
    c.cui_trace_sort(@ptrCast(spans.ptr), @intCast(spans.len));
}


pub fn http_reason(status: i32) []const u8 {
    return spanOrEmpty(c.cui_http_reason(status));
}


pub fn http_method_name(method: i32) []const u8 {
    return spanOrEmpty(c.cui_http_method_name(method));
}


pub fn url_params(url: [:0]const u8, pairs: *c.cui_kv_pair, cap: i32) i32 {
    return c.cui_url_params(url.ptr, @ptrCast(pairs), cap);
}


pub fn url_set_params(url: [:0]u8, cap: usize, pairs: []const c.cui_kv_pair) bool {
    return c.cui_url_set_params(url.ptr, cap, @ptrCast(pairs.ptr), @intCast(pairs.len));
}
// ==== END GEN:FREE ====

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
    /// printf format for the value, e.g. "%d pts"; default "%.0f"
    format: ?[]const u8 = null,
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

    /// Persistent per-id storage for your own components (zeroed on first
    /// use; unused state is freed after ~300 frames).
    pub fn state(self: *Ui, comptime T: type, id: u32) *T {
        const p = c.cui_state(self.h, id, @sizeOf(T));
        return @ptrCast(@alignCast(p));
    }

    /// Builds a NUL-terminated pointer array in the frame arena
    /// (for C `const char *const *` parameters and fields).
    pub fn strArr(self: *Ui, items: []const []const u8) [*c][*c]const u8 {
        const n = if (items.len == 0) 1 else items.len;
        const arr = self.arena.allocator().alloc([*c]const u8, n) catch
            @panic("zui: out of memory in the frame string arena");
        for (items, 0..) |it, i|
            arr[i] = @ptrCast(self.tmpStr(it).ptr);
        return @ptrCast(arr.ptr);
    }

    /// Converts a slice of friendly structs into a C array in the frame arena.
    pub fn structArr(self: *Ui, comptime C: type, items: anytype) [*c]C {
        const n = if (items.len == 0) 1 else items.len;
        const arr = self.arena.allocator().alloc(C, n) catch
            @panic("zui: out of memory in the frame string arena");
        for (items, 0..) |it, i|
            arr[i] = self.cvtOpts(C, it);
        return @ptrCast(arr.ptr);
    }

    // ---- queries (tooltips, popovers, tests) ---------------------------------

    /// The id of the most recent component.
    pub fn lastId(self: *Ui) u32 {
        return c.cui_last_id(self.h);
    }

    /// Rectangle of the most recent component, after layout.
    pub fn lastRect(self: *Ui) Rect {
        const r = c.cui_last_rect(self.h);
        return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    }

    /// Rectangle of any component or box id from the latest layout.
    pub fn getRect(self: *Ui, id: u32) Rect {
        const r = c.cui_get_rect(self.h, id);
        return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    }

    /// True while the pointer is over the most recent component.
    pub fn lastHovered(self: *Ui) bool {
        return c.cui_last_hovered(self.h);
    }

    pub fn makeId(self: *Ui, str: []const u8) u32 {
        return c.cui_make_id(self.h, self.tmpStr(str).ptr);
    }

    /// Scrolls the named scroll area so `y` is at its top.
    pub fn scrollTo(self: *Ui, scroll_id: []const u8, y: f32) void {
        c.cui_scroll_to(self.h, self.tmpStr(scroll_id).ptr, y);
    }

    // ---- input simulation (headless tests; the app layer feeds these too) ----

    pub fn mouseMove(self: *Ui, x: f32, y: f32) void {
        c.cui_input_mouse_move(self.h, x, y);
    }

    pub fn mouseLeave(self: *Ui) void {
        c.cui_input_mouse_leave(self.h);
    }

    pub fn mouseButton(self: *Ui, b: MouseButton, down: bool) void {
        c.cui_input_mouse_button(self.h, enumOrInt(c.cui_mouse_button, b), down);
    }

    /// Scroll wheel input in lines; +dy scrolls up.
    pub fn scrollWheel(self: *Ui, dx: f32, dy: f32) void {
        c.cui_input_scroll(self.h, dx, dy);
    }

    /// Feeds UTF-8 text to the focused text field.
    pub fn typeText(self: *Ui, utf8: []const u8) void {
        c.cui_input_text(self.h, self.tmpStr(utf8).ptr);
    }

    /// Key event. `key_code` is a C `cui_key` value (see zui.raw; the
    /// constants live at `zui.raw.cui_key.CUI_KEY_*` or as raw ints).
    pub fn key(self: *Ui, key_code: c.cui_key, down: bool, mods: c_int) void {
        c.cui_input_key(self.h, key_code, down, mods);
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

    // ---- custom drawing (callback APIs, hand-wrapped) -----------------------

    /// A box you paint yourself. `paint` runs after layout with the final
    /// rectangle; it may call the `ui.draw_*` helpers and text. Returns
    /// interaction info (hover/press/click and the pointer position).
    pub fn canvas(
        self: *Ui,
        id: []const u8,
        width: Size,
        height: Size,
        ctx: anytype,
        comptime paint_fn: anytype,
    ) CanvasResult {
        const Ctx = @TypeOf(ctx);
        const Blob = struct { ui: *Ui, ctx: Ctx };
        const T = struct {
            fn call(hc: ?*c.cui_ctx, r: c.cui_rect, u: ?*anyopaque) callconv(.c) void {
                _ = hc;
                const b: *Blob = @ptrCast(@alignCast(u.?));
                @call(.auto, paint_fn, .{ b.ui, rectFromC(r), b.ctx });
            }
        };
        var blob = Blob{ .ui = self, .ctx = ctx };
        const w_c = width.toC();
        const h_c = height.toC();
        const r = c.cui_canvas(self.h, self.tmpStr(id).ptr, w_c, h_c, T.call, &blob, @sizeOf(Blob));
        return cvtBackStruct(CanvasResult, r);
    }

    /// The signature pad's strokes so far: point array and the index where
    /// each new stroke starts, valid for the frame. Returns the point count.
    pub fn signaturePoints(self: *Ui, id: []const u8, points_out: *[]const Vec2, stroke_ends_out: *[]const i32) i32 {
        var pts: [*c]const c.cui_vec2 = null;
        var ends: [*c]const c_int = null;
        var n: c_int = 0;
        const r = c.cui_signature_points(self.h, self.tmpStr(id).ptr, &pts, &ends, &n);
        const count: usize = @intCast(n);
        const pv = self.arena.allocator().alloc(Vec2, count) catch @panic("zui: oom");
        for (0..count) |i| pv[i] = .{ .x = pts[i].x, .y = pts[i].y };
        const ev = self.arena.allocator().alloc(i32, count) catch @panic("zui: oom");
        for (0..count) |i| ev[i] = @intCast(ends[i]);
        points_out.* = pv;
        stroke_ends_out.* = ev;
        return r;
    }

    // ==== GEN:METHODS ====

// Generated component methods. C cui_foo_ex -> foo; begin/end pairs
// became scopes closed with `defer ui.end()` (CUI__SCOPE_IF ones return
// bool and only open when true, matching the C macros).

pub fn viewport_size(self: *Ui) Vec2 {
    return vecFromC(c.cui_viewport_size(self.h));
}

pub fn dpi_scale(self: *Ui) f32 {
    return c.cui_dpi_scale(self.h);
}

/// Valid inside route: whether this key-down repeats a physical held key.
pub fn input_repeated(self: *Ui) bool {
    return c.cui_input_repeated(self.h);
}

/// Held state eligible for default actions. cui_key_down remains physical state.
pub fn key_action_down(self: *Ui, key_arg: Key) bool {
    return c.cui_key_action_down(self.h, enumOrInt(c.cui_key, key_arg));
}

pub fn dropped_file(self: *Ui, index: i32) []const u8 {
    return spanOrEmpty(c.cui_dropped_file(self.h, index));
}

pub fn file_drag_active(self: *Ui) bool {
    return c.cui_file_drag_active(self.h);
}

/// Request a cursor during component submission or painting. The last request
/// wins. At end of frame the platform hook receives it; the next frame starts
/// with CUI_CURSOR_ARROW.
pub fn set_cursor(self: *Ui, cursor: Cursor) void {
    c.cui_set_cursor(self.h, enumOrInt(c.cui_cursor, cursor));
}

pub fn get_cursor(self: *Ui) Cursor {
    return @enumFromInt(enumToInt(c.cui_get_cursor(self.h)));
}

/// The system clipboard, for a menu or status bar item that copies or pastes ("Copy path").
/// They go through the platform's clipboard hooks, as the copy button and text fields do:
/// without a hook, setting does nothing and getting returns "". The returned text stays
/// valid until the next call.
pub fn set_clipboard_text(self: *Ui, s: []const u8) void {
    c.cui_set_clipboard_text(self.h, self.tmpStr(s).ptr);
}

pub fn get_clipboard_text(self: *Ui) []const u8 {
    return spanOrEmpty(c.cui_get_clipboard_text(self.h));
}

/// Queries, useful for app level shortcuts.
pub fn key_pressed(self: *Ui, key_arg: Key) bool {
    return c.cui_key_pressed(self.h, enumOrInt(c.cui_key, key_arg));
}

pub fn key_down(self: *Ui, key_arg: Key) bool {
    return c.cui_key_down(self.h, enumOrInt(c.cui_key, key_arg));
}

pub fn shortcut(self: *Ui, mods: i32, key_arg: Key) bool {
    return c.cui_shortcut(self.h, mods, enumOrInt(c.cui_key, key_arg));
}

pub fn key_mods(self: *Ui) i32 {
    return c.cui_key_mods(self.h);
}

pub fn mouse_pos(self: *Ui) Vec2 {
    return vecFromC(c.cui_mouse_pos(self.h));
}

pub fn mouse_down(self: *Ui, b: MouseButton) bool {
    return c.cui_mouse_down(self.h, enumOrInt(c.cui_mouse_button, b));
}

pub fn mouse_clicked(self: *Ui, b: MouseButton) bool {
    return c.cui_mouse_clicked(self.h, enumOrInt(c.cui_mouse_button, b));
}

/// True when a text field has keyboard focus (so the app should not treat
/// typing as shortcuts).
pub fn wants_keyboard(self: *Ui) bool {
    return c.cui_wants_keyboard(self.h);
}

pub fn wants_mouse(self: *Ui) bool {
    return c.cui_wants_mouse(self.h);
}

pub fn set_theme(self: *Ui, mode: ThemeMode) void {
    c.cui_set_theme(self.h, enumOrInt(c.cui_theme_mode, mode));
}

pub fn get_theme_mode(self: *Ui) ThemeMode {
    return @enumFromInt(enumToInt(c.cui_get_theme_mode(self.h)));
}

pub fn set_accent(self: *Ui, accent: Accent) void {
    c.cui_set_accent(self.h, enumOrInt(c.cui_accent, accent));
}

pub fn get_accent(self: *Ui) Accent {
    return @enumFromInt(enumToInt(c.cui_get_accent(self.h)));
}

/// The active theme. Edit it to customize; changes apply next frame. Theme
/// changes through cui_set_theme/cui_set_accent animate smoothly.
pub fn theme_get(self: *Ui) ?*c.cui_theme {
    return c.cui_theme_get(self.h);
}

pub fn set_reduced_motion(self: *Ui, reduced: bool) void {
    c.cui_set_reduced_motion(self.h, reduced);
}

pub fn color_of(self: *Ui, color: Color) Color {
    return colorFromC(c.cui_color_of(self.h, colorToC(color)));
}

pub fn get_strings(self: *Ui) ?*const c.cui_strings {
    return c.cui_get_strings(self.h);
}

pub fn token_color(self: *Ui, token: Token) Color {
    return colorFromC(c.cui_token_color(self.h, enumOrInt(c.cui_token, token)));
}

/// Load a TrueType/OpenType font. The data must stay alive if copy is false.
/// Returns a font id, or -1 on failure.
pub fn font_load_memory(self: *Ui, data: []const u8, copy: bool) i32 {
    return c.cui_font_load_memory(self.h, data.ptr, @intCast(data.len), copy);
}

pub fn font_load_file(self: *Ui, path: []const u8) i32 {
    return c.cui_font_load_file(self.h, self.tmpStr(path).ptr);
}

/// Replace one of the built-in roles (e.g. use your brand font as CUI_FONT_BODY).
pub fn font_set_role(self: *Ui, role: i32, font: i32) void {
    c.cui_font_set_role(self.h, role, font);
}

/// Glyphs missing from `font` are looked up in `fallback` (e.g. CJK, emoji).
pub fn font_add_fallback(self: *Ui, font: i32, fallback: i32) void {
    c.cui_font_add_fallback(self.h, font, fallback);
}

/// CUI_TEXT_SHAPING optionally shapes static RTL lines; see docs/integration.md.
/// Container direction sets the paragraph base. Editing and explicit bidi formatting
/// are unsupported; the shaper implements an experimental OpenType subset.
pub fn measure_text(self: *Ui, font: i32, size_arg: f32, s: []const u8) TextMetrics {
    return cvtBackStruct(TextMetrics, c.cui_measure_text(self.h, font, size_arg, s.ptr, @intCast(s.len)));
}

/// Restrict Tab / Shift+Tab navigation to widgets built inside the active scope
/// (for example, the focused pane in a multi-pane workspace). An inactive scope
/// and its descendants remain clickable but outside the Tab order. With no active
/// scope, Tab visits unscoped controls. An open modal takes precedence.
pub fn push_focus_scope(self: *Ui, id: u32, active: bool) void {
    c.cui_push_focus_scope(self.h, id, active);
}

pub fn pop_focus_scope(self: *Ui) void {
    c.cui_pop_focus_scope(self.h);
}

pub fn label_text(self: *Ui, s: []const u8) void {
    c.cui_label(self.h, self.tmpStr(s).ptr);
}

pub fn segmented(self: *Ui, id: []const u8, items: []const []const u8, index: *i32, opts: SegmentedOpts) bool {
    const zp2_c = self.strArr(items);
    const opts_c = self.cvtOpts(c.cui_segmented_opts, opts);
    return c.cui_segmented_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(items.len), @ptrCast(index), &opts_c);
}

pub fn radio_group(self: *Ui, id: []const u8, items: []const []const u8, index: *i32) bool {
    const zp2_c = self.strArr(items);
    return c.cui_radio_group(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(items.len), @ptrCast(index));
}

/// Range slider with two non-crossing thumbs. Tab focuses the range, Space
/// selects the other thumb, and the slider keys adjust the focused thumb.
pub fn range_slider(self: *Ui, label: []const u8, lo: *f32, hi: *f32, min: f32, max: f32) bool {
    return c.cui_range_slider(self.h, self.tmpStr(label).ptr, @ptrCast(lo), @ptrCast(hi), min, max);
}

pub fn rating(self: *Ui, id: []const u8, value: *i32, max: i32) bool {
    return c.cui_rating(self.h, self.tmpStr(id).ptr, @ptrCast(value), max);
}

pub fn chip(self: *Ui, label: []const u8, selected: *bool, opts: ChipOpts) bool {
    const opts_c = self.cvtOpts(c.cui_chip_opts, opts);
    return c.cui_chip_ex(self.h, self.tmpStr(label).ptr, selected, &opts_c);
}

/// Enter opens the list or picks the highlighted item. A searchable select
/// returns focus to its trigger when its list closes.
pub fn select(self: *Ui, id: []const u8, items: []const []const u8, index: *i32, opts: SelectOpts) bool {
    const zp2_c = self.strArr(items);
    const opts_c = self.cvtOpts(c.cui_select_opts, opts);
    return c.cui_select_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(items.len), @ptrCast(index), &opts_c);
}

pub fn calendar(self: *Ui, id: []const u8, value: *c.cui_date) bool {
    return c.cui_calendar(self.h, self.tmpStr(id).ptr, @ptrCast(value));
}

pub fn date_picker(self: *Ui, id: []const u8, value: *c.cui_date, opts: DateOpts) bool {
    const opts_c = self.cvtOpts(c.cui_date_opts, opts);
    return c.cui_date_picker_ex(self.h, self.tmpStr(id).ptr, @ptrCast(value), &opts_c);
}

pub fn color_picker(self: *Ui, id: []const u8, value: *Color) bool {
    var zp2_c: c.cui_color = colorToC(value.*);
    const result = c.cui_color_picker(self.h, self.tmpStr(id).ptr, &zp2_c);
    value.* = colorFromC(zp2_c);
    return result;
}

pub fn tabs(self: *Ui, id: []const u8, items: []const []const u8, index: *i32, opts: TabsOpts) bool {
    const zp2_c = self.strArr(items);
    const opts_c = self.cvtOpts(c.cui_tabs_opts, opts);
    return c.cui_tabs_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(items.len), @ptrCast(index), &opts_c);
}

pub fn nav_item(self: *Ui, label: []const u8, opts: NavOpts) bool {
    const opts_c = self.cvtOpts(c.cui_nav_opts, opts);
    return c.cui_nav_item_ex(self.h, self.tmpStr(label).ptr, &opts_c);
}

pub fn nav_section(self: *Ui, title: []const u8) void {
    c.cui_nav_section(self.h, self.tmpStr(title).ptr);
}

/// Ancestor links, which show keyboard focus. Returns the clicked index or -1.
pub fn breadcrumb(self: *Ui, items: []const []const u8) i32 {
    const zp1_c = self.strArr(items);
    return c.cui_breadcrumb(self.h, zp1_c, @intCast(items.len));
}

/// Page buttons, which show keyboard focus; page is 0 based. The compact layout is
/// chosen from the parent's inner width.
pub fn pagination(self: *Ui, id: []const u8, page: *i32, page_count: i32) bool {
    return c.cui_pagination(self.h, self.tmpStr(id).ptr, @ptrCast(page), page_count);
}

/// Process steps; labels collapse to fit the width of their own row.
pub fn stepper(self: *Ui, steps: []const []const u8, current: i32) void {
    const zp1_c = self.strArr(steps);
    c.cui_stepper(self.h, zp1_c, @intCast(steps.len), current);
}

pub fn popover(self: *Ui, id: []const u8, opts: PopoverOpts) bool {
    const opts_c = self.cvtOpts(c.cui_popover_opts, opts);
    if (!(c.cui_popover_begin(self.h, self.tmpStr(id).ptr, &opts_c))) return false;
    self.pushEnd(zui_end_adapter_popover_end);
    return true;
}

/// What happened this frame: one of CUI_TOUR_*.
pub fn tour(self: *Ui, id: []const u8, steps: []const TourStep, step: *i32, opts: TourOpts) i32 {
    const zp2_c = self.structArr(c.cui_tour_step, steps);
    const opts_c = self.cvtOpts(c.cui_tour_opts, opts);
    return c.cui_tour_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(steps.len), @ptrCast(step), &opts_c);
}

pub fn popover_open(self: *Ui, id: []const u8) void {
    c.cui_popover_open(self.h, self.tmpStr(id).ptr);
}

pub fn popover_close(self: *Ui, id: []const u8) void {
    c.cui_popover_close(self.h, self.tmpStr(id).ptr);
}

pub fn popover_toggle(self: *Ui, id: []const u8) void {
    c.cui_popover_toggle(self.h, self.tmpStr(id).ptr);
}

pub fn popover_is_open(self: *Ui, id: []const u8) bool {
    return c.cui_popover_is_open(self.h, self.tmpStr(id).ptr);
}

pub fn menu(self: *Ui, label: []const u8, opts: MenuOpts) bool {
    const opts_c = self.cvtOpts(c.cui_menu_opts, opts);
    if (!(c.cui_menu_begin(self.h, self.tmpStr(label).ptr, &opts_c))) return false;
    self.pushEnd(zui_end_adapter_menu_end);
    return true;
}

/// Context menu: opens on right click over the previous component.
pub fn context_menu(self: *Ui, id: []const u8) bool {
    if (!(c.cui_context_menu_begin(self.h, self.tmpStr(id).ptr))) return false;
    self.pushEnd(zui_end_adapter_context_menu_end);
    return true;
}

pub fn menu_item(self: *Ui, label: []const u8, opts: MenuItemOpts) bool {
    const opts_c = self.cvtOpts(c.cui_menu_item_opts, opts);
    return c.cui_menu_item_ex(self.h, self.tmpStr(label).ptr, &opts_c);
}

pub fn menu_separator(self: *Ui) void {
    c.cui_menu_separator(self.h);
}

pub fn menu_label(self: *Ui, s: []const u8) void {
    c.cui_menu_label(self.h, self.tmpStr(s).ptr);
}

/// Tooltip for the previous component. The first hover waits for the delay,
/// measured in elapsed time even when the app sleeps between frames.
pub fn tooltip(self: *Ui, s: []const u8) void {
    c.cui_tooltip(self.h, self.tmpStr(s).ptr);
}

/// Modal dialog. Shown while *open is true; closing sets it to false.
/// Escape leaves a focused text field before it can dismiss the dialog.
pub fn dialog(self: *Ui, title: []const u8, open: *bool, opts: DialogOpts) bool {
    const opts_c = self.cvtOpts(c.cui_dialog_opts, opts);
    if (!(c.cui_dialog_begin(self.h, self.tmpStr(title).ptr, open, &opts_c))) return false;
    self.pushEnd(zui_end_adapter_dialog_end);
    return true;
}

/// A right-aligned row for dialog actions.
pub fn dialog_footer(self: *Ui) void {
    self.pushEnd(zui_end_adapter_dialog_footer_end);
c.cui_dialog_footer_begin(self.h);
}

pub fn sheet(self: *Ui, title: []const u8, open: *bool, opts: SheetOpts) bool {
    const opts_c = self.cvtOpts(c.cui_sheet_opts, opts);
    if (!(c.cui_sheet_begin(self.h, self.tmpStr(title).ptr, open, &opts_c))) return false;
    self.pushEnd(zui_end_adapter_sheet_end);
    return true;
}

/// Queue a toast. Returns a handle; cui_toast_action_clicked(handle) tells
/// whether its action button was pressed before the toast started closing.
pub fn toast(self: *Ui, title: []const u8, opts: ToastOpts) i32 {
    const opts_c = self.cvtOpts(c.cui_toast_opts, opts);
    return c.cui_toast_ex(self.h, self.tmpStr(title).ptr, &opts_c);
}

pub fn toast_action_clicked(self: *Ui, handle: i32) bool {
    return c.cui_toast_action_clicked(self.h, handle);
}

pub fn toast_dismiss(self: *Ui, handle: i32) void {
    c.cui_toast_dismiss(self.h, handle);
}

/// Inline alert. Returns false once dismissed (when dismissible).
pub fn alert(self: *Ui, title: []const u8, opts: AlertOpts) bool {
    const opts_c = self.cvtOpts(c.cui_alert_opts, opts);
    return c.cui_alert_ex(self.h, self.tmpStr(title).ptr, &opts_c);
}

pub fn progress_bar(self: *Ui, value: f32, opts: ProgressOpts) void {
    const opts_c = self.cvtOpts(c.cui_progress_opts, opts);
    c.cui_progress_ex(self.h, value, &opts_c);
}

/// most styles are square; upload and download are 25/32 as wide as tall, transfer 50/32, bounce 40/28, scan 28/32
pub fn spinner(self: *Ui, size_arg: f32, opts: SpinnerOpts) void {
    const opts_c = self.cvtOpts(c.cui_spinner_opts, opts);
    c.cui_spinner_ex(self.h, size_arg, &opts_c);
}

pub fn skeleton(self: *Ui, width: Size, height: f32) void {
    const zp1_c = width.toC();
    c.cui_skeleton(self.h, zp1_c, height);
}

pub fn skeleton_group(self: *Ui, opts: SkeletonGroupOpts) void {
    const opts_c = self.cvtOpts(c.cui_skeleton_group_opts, opts);
    self.pushEnd(zui_end_adapter_skeleton_group_end);
c.cui_skeleton_group_begin_ex(self.h, &opts_c);
}

pub fn badge(self: *Ui, s: []const u8, opts: BadgeOpts) void {
    const opts_c = self.cvtOpts(c.cui_badge_opts, opts);
    c.cui_badge_ex(self.h, self.tmpStr(s).ptr, &opts_c);
}

pub fn avatar(self: *Ui, name: []const u8, opts: AvatarOpts) void {
    const opts_c = self.cvtOpts(c.cui_avatar_opts, opts);
    c.cui_avatar_ex(self.h, self.tmpStr(name).ptr, &opts_c);
}

pub fn avatar_group(self: *Ui, names: []const []const u8, max_visible: i32, size_arg: f32) void {
    const zp1_c = self.strArr(names);
    c.cui_avatar_group(self.h, zp1_c, @intCast(names.len), max_visible, size_arg);
}

/// Empty state. Returns true when its action button is clicked.
pub fn empty_state(self: *Ui, title: []const u8, opts: EmptyOpts) bool {
    const opts_c = self.cvtOpts(c.cui_empty_opts, opts);
    return c.cui_empty_state_ex(self.h, self.tmpStr(title).ptr, &opts_c);
}

pub fn metric(self: *Ui, label: []const u8, value: []const u8, opts: MetricOpts) void {
    const opts_c = self.cvtOpts(c.cui_metric_opts, opts);
    c.cui_metric_ex(self.h, self.tmpStr(label).ptr, self.tmpStr(value).ptr, &opts_c);
}

pub fn meter(self: *Ui, label: []const u8, used: f32, total: f32, unit: []const u8) void {
    c.cui_meter(self.h, self.tmpStr(label).ptr, used, total, self.tmpStr(unit).ptr);
}

/// ------------------------------------------------------------------------
/// Data display
/// ------------------------------------------------------------------------
/// Accordion / disclosure. Content animates its height.
pub fn accordion(self: *Ui, title: []const u8, open: *bool) bool {
    if (!(c.cui_accordion_begin(self.h, self.tmpStr(title).ptr, open))) return false;
    self.pushEnd(zui_end_adapter_accordion_end);
    return true;
}

pub fn tree(self: *Ui, label: []const u8, open: *bool, opts: TreeOpts) bool {
    const opts_c = self.cvtOpts(c.cui_tree_opts, opts);
    if (!(c.cui_tree_begin(self.h, self.tmpStr(label).ptr, open, &opts_c))) return false;
    self.pushEnd(zui_end_adapter_tree_end);
    return true;
}

pub fn tree_clicked(self: *Ui) bool {
    return c.cui_tree_clicked(self.h);
}

pub fn list_item(self: *Ui, title: []const u8, opts: ListItemOpts) bool {
    const opts_c = self.cvtOpts(c.cui_list_item_opts, opts);
    return c.cui_list_item_ex(self.h, self.tmpStr(title).ptr, &opts_c);
}

/// Virtual list: only the visible rows are built, so lists with a million
/// rows stay fast. Fills first/last with the visible range for this row count.
pub fn virtual_list(self: *Ui, id: []const u8, count: i32, row_height: f32, height: Size, first: *i32, last: *i32) void {
    const zp4_c = height.toC();
    self.pushEnd(zui_end_adapter_virtual_list_end);
c.cui_virtual_list_begin(self.h, self.tmpStr(id).ptr, count, row_height, zp4_c, @ptrCast(first), @ptrCast(last));
}

pub fn table(self: *Ui, id: []const u8, columns: []const TableColumn, opts: TableOpts) bool {
    const zp2_c = self.structArr(c.cui_table_column, columns);
    const opts_c = self.cvtOpts(c.cui_table_opts, opts);
    if (!(c.cui_table_begin_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(columns.len), &opts_c))) return false;
    self.pushEnd(zui_end_adapter_table_end);
    return true;
}

/// Begin a row. Returns true when the row is clicked.
pub fn table_row(self: *Ui, selected: bool) bool {
    return c.cui_table_row(self.h, selected);
}

/// Next cell; put any components inside, or use cui_table_cell_text.
pub fn table_cell(self: *Ui) void {
    c.cui_table_cell(self.h);
}

pub fn table_cell_text(self: *Ui, s: []const u8) void {
    c.cui_table_cell_text(self.h, self.tmpStr(s).ptr);
}

pub fn line_chart(self: *Ui, id: []const u8, series: []const Series, opts: ChartOpts) void {
    const zp2_c = self.structArr(c.cui_series, series);
    const opts_c = self.cvtOpts(c.cui_chart_opts, opts);
    c.cui_line_chart_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(series.len), &opts_c);
}

pub fn bar_chart(self: *Ui, id: []const u8, series: []const Series, opts: ChartOpts) void {
    const zp2_c = self.structArr(c.cui_series, series);
    const opts_c = self.cvtOpts(c.cui_chart_opts, opts);
    c.cui_bar_chart_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(series.len), &opts_c);
}

pub fn donut_chart(self: *Ui, id: []const u8, values: []const f32, labels: []const []const u8, opts: ChartOpts) void {
    const zp3_c = self.strArr(labels);
    const opts_c = self.cvtOpts(c.cui_chart_opts, opts);
    c.cui_donut_chart_ex(self.h, self.tmpStr(id).ptr, values.ptr, zp3_c, @intCast(labels.len), &opts_c);
}

pub fn sparkline(self: *Ui, values: []const f32, width: Size, height: f32, color: Color) void {
    const zp3_c = width.toC();
    c.cui_sparkline(self.h, values.ptr, @intCast(values.len), zp3_c, height, colorToC(color));
}

pub fn gauge(self: *Ui, label: []const u8, value: f32, size_arg: f32) void {
    c.cui_gauge(self.h, self.tmpStr(label).ptr, value, size_arg);
}

pub fn pattern_meter(self: *Ui, id: []const u8, parts: []const MeterPart, opts: PatternMeterOpts) i32 {
    const zp2_c = self.structArr(c.cui_meter_part, parts);
    const opts_c = self.cvtOpts(c.cui_pattern_meter_opts, opts);
    return c.cui_pattern_meter_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(parts.len), &opts_c);
}

/// Images
pub fn image_create(self: *Ui, w: i32, h: i32, rgba_arg: []const u8) usize {
    return c.cui_image_create(self.h, w, h, rgba_arg.ptr);
}

/// Update a rectangle within an existing RGBA8 texture and request a redraw. stride is
/// the byte distance between source rows: at least w * 4, or 0 for tightly packed.
pub fn image_update(self: *Ui, tex: usize, x: i32, y: i32, w: i32, h: i32, rgba_arg: []const u8, stride: i32) void {
    c.cui_image_update(self.h, tex, x, y, w, h, rgba_arg.ptr, stride);
}

pub fn image_load(self: *Ui, path: []const u8, w: *i32, h: *i32) usize {
    return c.cui_image_load(self.h, self.tmpStr(path).ptr, @ptrCast(w), @ptrCast(h));
}

pub fn image_destroy(self: *Ui, tex: usize) void {
    c.cui_image_destroy(self.h, tex);
}

pub fn image_view(self: *Ui, tex: usize, opts: ImageOpts) void {
    const opts_c = self.cvtOpts(c.cui_image_opts, opts);
    c.cui_image_ex(self.h, tex, &opts_c);
}

/// Returns true when the view changed.
pub fn image_viewer(self: *Ui, id: []const u8, tex: usize, image_w: i32, image_h: i32, view: *c.cui_image_view, opts: ImageViewerOpts) bool {
    const opts_c = self.cvtOpts(c.cui_image_viewer_opts, opts);
    return c.cui_image_viewer_ex(self.h, self.tmpStr(id).ptr, tex, image_w, image_h, @ptrCast(view), &opts_c);
}

/// Returns true when the crop changed.
pub fn cropper(self: *Ui, id: []const u8, tex: usize, image_w: i32, image_h: i32, crop: *i32, opts: CropperOpts) bool {
    const opts_c = self.cvtOpts(c.cui_cropper_opts, opts);
    return c.cui_cropper_ex(self.h, self.tmpStr(id).ptr, tex, image_w, image_h, @ptrCast(crop), &opts_c);
}

/// Spotlight style command palette. Returns the index of the chosen command,
/// or -1. Open it with a shortcut: if (cui_shortcut(ui, CUI_MOD_PRIMARY, CUI_KEY_K)) open = true;
pub fn command_palette(self: *Ui, open: *bool, commands: []const Command) i32 {
    const zp2_c = self.structArr(c.cui_command, commands);
    return c.cui_command_palette(self.h, open, zp2_c, @intCast(commands.len));
}

pub fn radio_cards(self: *Ui, id: []const u8, choices: []const Choice, index: *i32, opts: RadioCardsOpts) bool {
    const zp2_c = self.structArr(c.cui_choice, choices);
    const opts_c = self.cvtOpts(c.cui_radio_cards_opts, opts);
    return c.cui_radio_cards_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(choices.len), @ptrCast(index), &opts_c);
}

/// max_tags applies to every tag, including a batch separated by commas.
pub fn tag_input(self: *Ui, id: []const u8, buf: []u8, cap: usize, opts: TagOpts) bool {
    const opts_c = self.cvtOpts(c.cui_tag_opts, opts);
    return c.cui_tag_input_ex(self.h, self.tmpStr(id).ptr, buf.ptr, cap, &opts_c);
}

/// One time code input: `length` boxes; code must hold length + 1 bytes.
/// Returns true when all boxes are filled, including when a paste replaces
/// one complete code with a different complete code.
pub fn otp_input(self: *Ui, id: []const u8, code_arg: []u8, length: i32) bool {
    return c.cui_otp_input(self.h, self.tmpStr(id).ptr, code_arg.ptr, length);
}

/// Connected buttons. Put buttons between begin and end.
pub fn button_group(self: *Ui) void {
    self.pushEnd(zui_end_adapter_button_group_end);
c.cui_button_group_begin(self.h);
}

/// Icon button that copies text to the clipboard and confirms with a check.
/// Keyboard focus stays on the button when the check appears or disappears.
pub fn copy_button(self: *Ui, id: []const u8, s: []const u8) bool {
    return c.cui_copy_button(self.h, self.tmpStr(id).ptr, self.tmpStr(s).ptr);
}

pub fn hold_button(self: *Ui, label: []const u8, opts: HoldOpts) bool {
    const opts_c = self.cvtOpts(c.cui_hold_opts, opts);
    return c.cui_hold_button_ex(self.h, self.tmpStr(label).ptr, &opts_c);
}

/// Password strength meter (0 weak .. 4 strong). Returns the score.
pub fn password_strength(self: *Ui, password: []const u8) i32 {
    return c.cui_password_strength(self.h, self.tmpStr(password).ptr);
}

pub fn timeline_item(self: *Ui, title: []const u8, opts: TimelineOpts) void {
    const opts_c = self.cvtOpts(c.cui_timeline_opts, opts);
    c.cui_timeline_item_ex(self.h, self.tmpStr(title).ptr, &opts_c);
}

/// Reorderable list: drag rows to reorder. `order` holds your item indices in
/// display order and is rewritten when a row is dropped. Build the rows in
/// display order: for (i...) cui_reorder_item(ui, i) { draw item order[i] }.
/// Returns true on the frame the order changes.
pub fn reorder(self: *Ui, id: []const u8, order: *i32, count: i32) void {
    self.pushEnd(zui_end_adapter_reorder_end);
c.cui_reorder_begin(self.h, self.tmpStr(id).ptr, @ptrCast(order), count);
}

pub fn reorder_item(self: *Ui, position: i32) void {
    self.pushEnd(zui_end_adapter_reorder_item_end);
c.cui_reorder_item_begin(self.h, position);
}

/// Circular progress with the value in the middle.
pub fn progress_ring(self: *Ui, label: []const u8, value: f32, size_arg: f32) void {
    c.cui_progress_ring(self.h, self.tmpStr(label).ptr, value, size_arg);
}

pub fn split_button(self: *Ui, label: []const u8, items: []const []const u8, opts: SplitButtonOpts) i32 {
    const zp2_c = self.strArr(items);
    const opts_c = self.cvtOpts(c.cui_split_button_opts, opts);
    return c.cui_split_button_ex(self.h, self.tmpStr(label).ptr, zp2_c, @intCast(items.len), &opts_c);
}

pub fn toggle_group(self: *Ui, id: []const u8, labels: []const []const u8, values: *bool, opts: ToggleGroupOpts) bool {
    const zp2_c = self.strArr(labels);
    const opts_c = self.cvtOpts(c.cui_toggle_group_opts, opts);
    return c.cui_toggle_group_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(labels.len), values, &opts_c);
}

pub fn confirm_button(self: *Ui, label: []const u8, opts: ConfirmOpts) bool {
    const opts_c = self.cvtOpts(c.cui_confirm_opts, opts);
    return c.cui_confirm_button_ex(self.h, self.tmpStr(label).ptr, &opts_c);
}

pub fn status_button(self: *Ui, label: []const u8, status: Status, opts: StatusButtonOpts) bool {
    const opts_c = self.cvtOpts(c.cui_status_button_opts, opts);
    return c.cui_status_button_ex(self.h, self.tmpStr(label).ptr, enumOrInt(c.cui_status, status), &opts_c);
}

pub fn status_spinner(self: *Ui, id: []const u8, status: Status, opts: StatusSpinnerOpts) bool {
    const opts_c = self.cvtOpts(c.cui_status_spinner_opts, opts);
    return c.cui_status_spinner_ex(self.h, self.tmpStr(id).ptr, enumOrInt(c.cui_status, status), &opts_c);
}

pub fn reactions(self: *Ui, id: []const u8, items: []c.cui_reaction) i32 {
    return c.cui_reactions(self.h, self.tmpStr(id).ptr, @ptrCast(items.ptr), @intCast(items.len));
}

pub fn speed_dial(self: *Ui, id: []const u8, actions: []const SpeedAction, opts: SpeedDialOpts) i32 {
    const zp2_c = self.structArr(c.cui_speed_action, actions);
    const opts_c = self.cvtOpts(c.cui_speed_dial_opts, opts);
    return c.cui_speed_dial_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(actions.len), &opts_c);
}

/// Theme switcher: light, dark and (optionally) system, as a compact icon
/// segmented control. mode is 0 light, 1 dark, 2 system. Light and dark are
/// applied for you; for system call cui_set_theme with the OS setting.
/// Returns true when mode changed.
pub fn theme_switcher(self: *Ui, mode: *i32, with_system: bool) bool {
    return c.cui_theme_switcher(self.h, @ptrCast(mode), with_system);
}

/// Sun and moon icon button that toggles the theme with a morph.
pub fn theme_toggle(self: *Ui) bool {
    return c.cui_theme_toggle(self.h);
}

pub fn user_menu(self: *Ui, name: []const u8, opts: UserMenuOpts) bool {
    const opts_c = self.cvtOpts(c.cui_user_menu_opts, opts);
    if (!(c.cui_user_menu_begin(self.h, self.tmpStr(name).ptr, &opts_c))) return false;
    self.pushEnd(zui_end_adapter_user_menu_end);
    return true;
}

pub fn swipe_item(self: *Ui, id: []const u8, left: []const SwipeAction, right: []const SwipeAction) void {
    const zp2_c = self.structArr(c.cui_swipe_action, left);
    const zp4_c = self.structArr(c.cui_swipe_action, right);
    self.pushEnd(zui_end_adapter_swipe_item_end);
c.cui_swipe_item_begin(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(left.len), zp4_c, @intCast(right.len));
}

/// Returns a visible range for the current row count, even after the grid shrinks.
pub fn data_grid(self: *Ui, id: []const u8, columns: []const GridColumn, row_count: i32, first: *i32, last: *i32, opts: GridOpts) void {
    const zp2_c = self.structArr(c.cui_grid_column, columns);
    const opts_c = self.cvtOpts(c.cui_grid_opts, opts);
    self.pushEnd(zui_end_adapter_data_grid_end);
_ = c.cui_data_grid_begin_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(columns.len), row_count, @ptrCast(first), @ptrCast(last), &opts_c);
}

pub fn data_grid_row(self: *Ui, row_arg: i32) bool {
    return c.cui_data_grid_row(self.h, row_arg);
}

pub fn data_grid_cell(self: *Ui) void {
    c.cui_data_grid_cell(self.h);
}

pub fn data_grid_cell_text(self: *Ui, s: []const u8) void {
    c.cui_data_grid_cell_text(self.h, self.tmpStr(s).ptr);
}

/// Editable text cell: double click (or Enter on the cursor row) to edit,
/// Enter or clicking away commits, Esc reverts. True when committed.
pub fn data_grid_cell_edit(self: *Ui, buf: []u8, cap: usize) bool {
    return c.cui_data_grid_cell_edit(self.h, buf.ptr, cap);
}

/// The same editable text, inside the current cell (after an avatar, say).
pub fn data_grid_edit(self: *Ui, buf: []u8, cap: usize) bool {
    return c.cui_data_grid_edit(self.h, buf.ptr, cap);
}

/// Tree cell: indentation, a disclosure chevron and a label, for tree tables
/// (use it in a table or grid cell). Returns true when *open toggled.
pub fn tree_cell(self: *Ui, label: []const u8, depth: i32, has_children: bool, open: *bool, icon_name: []const u8) bool {
    return c.cui_tree_cell(self.h, self.tmpStr(label).ptr, depth, has_children, open, self.tmpStr(icon_name).ptr);
}

pub fn filter_bar(self: *Ui, id: []const u8, fields: []const FilterField, selected: *u32, search_arg: []u8, search_cap: usize) bool {
    const zp2_c = self.structArr(c.cui_filter_field, fields);
    return c.cui_filter_bar(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(fields.len), @ptrCast(selected), search_arg.ptr, search_cap);
}

pub fn tree_table(self: *Ui, id: []const u8, columns: []const GridColumn, nodes: []c.cui_tree_node, opts: TreeTableOpts) void {
    const zp2_c = self.structArr(c.cui_grid_column, columns);
    const opts_c = self.cvtOpts(c.cui_tree_table_opts, opts);
    self.pushEnd(zui_end_adapter_tree_table_end);
c.cui_tree_table_begin_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(columns.len), @ptrCast(nodes.ptr), @intCast(nodes.len), &opts_c);
}

/// The next row in view: returns its node, or -1 when done. Then build its
/// cells: cui_tree_table_name first, then cui_data_grid_cell(_text).
pub fn tree_table_row(self: *Ui) i32 {
    return c.cui_tree_table_row(self.h);
}

/// The first cell: indentation, guides, the chevron, an icon and the name
/// (cut short with a tooltip of the whole name when it does not fit).
pub fn tree_table_name(self: *Ui, label: []const u8, icon_name: []const u8) void {
    c.cui_tree_table_name(self.h, self.tmpStr(label).ptr, self.tmpStr(icon_name).ptr);
}

pub fn tree_table_depth(self: *Ui) i32 {
    return c.cui_tree_table_depth(self.h);
}

pub fn path_bar(self: *Ui, id: []const u8, segments: []const []const u8, opts: PathBarOpts) PathBarResult {
    const zp2_c = self.strArr(segments);
    const opts_c = self.cvtOpts(c.cui_path_bar_opts, opts);
    return cvtBackStruct(PathBarResult, c.cui_path_bar_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(segments.len), &opts_c));
}

/// True while the menu of separator *segment is showing: build menu items
/// for the children of that segment, then call cui_path_bar_menu_end.
pub fn path_bar_menu(self: *Ui, id: []const u8, segment: *i32) void {
    self.pushEnd(zui_end_adapter_path_bar_menu_end);
_ = c.cui_path_bar_menu_begin(self.h, self.tmpStr(id).ptr, @ptrCast(segment));
}

/// path: the folder shown, yours; the browser writes it as you move around.
pub fn file_browser(self: *Ui, id: []const u8, path: []u8, path_cap: usize, opts: FileBrowserOpts) FileBrowserResult {
    const opts_c = self.cvtOpts(c.cui_file_browser_opts, opts);
    return cvtBackStruct(FileBrowserResult, c.cui_file_browser_ex(self.h, self.tmpStr(id).ptr, path.ptr, path_cap, &opts_c));
}

/// True once, with the chosen path in out, when the dialog is confirmed;
/// *open turns false then, or on Cancel and Esc.
pub fn file_picker(self: *Ui, id: []const u8, open: *bool, out: []u8, out_cap: usize, opts: FilePickerOpts) bool {
    const opts_c = self.cvtOpts(c.cui_file_picker_opts, opts);
    return c.cui_file_picker_ex(self.h, self.tmpStr(id).ptr, open, out.ptr, out_cap, &opts_c);
}

pub fn code_block(self: *Ui, id: []const u8, code_arg: []const u8, opts: CodeOpts) void {
    const opts_c = self.cvtOpts(c.cui_code_opts, opts);
    c.cui_code_block_ex(self.h, self.tmpStr(id).ptr, self.tmpStr(code_arg).ptr, &opts_c);
}

pub fn json_view(self: *Ui, id: []const u8, json: []const u8, opts: JsonOpts) bool {
    const opts_c = self.cvtOpts(c.cui_json_opts, opts);
    return c.cui_json_view_ex(self.h, self.tmpStr(id).ptr, self.tmpStr(json).ptr, &opts_c);
}

pub fn markdown(self: *Ui, id: []const u8, s: []const u8, opts: MarkdownOpts) MarkdownResult {
    const opts_c = self.cvtOpts(c.cui_markdown_opts, opts);
    return cvtBackStruct(MarkdownResult, c.cui_markdown_ex(self.h, self.tmpStr(id).ptr, self.tmpStr(s).ptr, &opts_c));
}

pub fn code_editor(self: *Ui, id: []const u8, buf: []u8, cap: usize, opts: CodeEditorOpts) CodeEditorResult {
    const opts_c = self.cvtOpts(c.cui_code_editor_opts, opts);
    return cvtBackStruct(CodeEditorResult, c.cui_code_editor_ex(self.h, self.tmpStr(id).ptr, buf.ptr, cap, &opts_c));
}

/// On the editor's next frame: put the caret at a line and column (1 based),
/// focus the editor and scroll there. Call from the same id scope.
pub fn code_editor_goto(self: *Ui, id: []const u8, line: i32, column_arg: i32) void {
    c.cui_code_editor_goto(self.h, self.tmpStr(id).ptr, line, column_arg);
}

/// On the next frame: select bytes anchor..cursor, focus and scroll there.
pub fn code_editor_select(self: *Ui, id: []const u8, anchor: i32, cursor: i32) void {
    c.cui_code_editor_select(self.h, self.tmpStr(id).ptr, anchor, cursor);
}

/// Opens the find bar with query and selects the next match (NULL closes).
pub fn code_editor_find(self: *Ui, id: []const u8, query: []const u8) void {
    c.cui_code_editor_find(self.h, self.tmpStr(id).ptr, self.tmpStr(query).ptr);
}

pub fn diff_view(self: *Ui, id: []const u8, old_text: []const u8, new_text: []const u8, opts: DiffOpts) DiffResult {
    const opts_c = self.cvtOpts(c.cui_diff_opts, opts);
    return cvtBackStruct(DiffResult, c.cui_diff_view_ex(self.h, self.tmpStr(id).ptr, self.tmpStr(old_text).ptr, self.tmpStr(new_text).ptr, &opts_c));
}

pub fn diff_view_rows(self: *Ui, id: []const u8, rows: *c.cui_diff_row, first: i32, cap: i32) i32 {
    return c.cui_diff_view_rows(self.h, self.tmpStr(id).ptr, @ptrCast(rows), first, cap);
}

pub fn chat_message(self: *Ui, s: []const u8, opts: ChatOpts) void {
    const opts_c = self.cvtOpts(c.cui_chat_opts, opts);
    c.cui_chat_message_ex(self.h, self.tmpStr(s).ptr, &opts_c);
}

pub fn chat_divider(self: *Ui, label: []const u8) void {
    c.cui_chat_divider(self.h, self.tmpStr(label).ptr);
}

pub fn typing_indicator(self: *Ui, name: []const u8) void {
    c.cui_typing_indicator(self.h, self.tmpStr(name).ptr);
}

pub fn comment(self: *Ui, id: []const u8, author: []const u8, s: []const u8, opts: CommentOpts) i32 {
    const opts_c = self.cvtOpts(c.cui_comment_opts, opts);
    return c.cui_comment_ex(self.h, self.tmpStr(id).ptr, self.tmpStr(author).ptr, self.tmpStr(s).ptr, &opts_c);
}

pub fn presence(self: *Ui, id: []const u8, users: []const PresenceUser, max_visible: i32, size_arg: f32) void {
    const zp2_c = self.structArr(c.cui_presence_user, users);
    c.cui_presence(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(users.len), max_visible, size_arg);
}

pub fn carousel(self: *Ui, id: []const u8, count: i32, index: *i32, opts: CarouselOpts) void {
    const opts_c = self.cvtOpts(c.cui_carousel_opts, opts);
    self.pushEnd(zui_end_adapter_carousel_end);
_ = c.cui_carousel_begin(self.h, self.tmpStr(id).ptr, count, @ptrCast(index), &opts_c);
}

pub fn carousel_slide(self: *Ui) void {
    self.pushEnd(zui_end_adapter_carousel_slide_end);
c.cui_carousel_slide_begin(self.h);
}

pub fn image_compare(self: *Ui, id: []const u8, before: usize, after: usize, pos: *f32, opts: CompareOpts) bool {
    const opts_c = self.cvtOpts(c.cui_compare_opts, opts);
    return c.cui_image_compare_ex(self.h, self.tmpStr(id).ptr, before, after, @ptrCast(pos), &opts_c);
}

pub fn card_stack(self: *Ui, id: []const u8, count: i32, opts: CardStackOpts) void {
    const opts_c = self.cvtOpts(c.cui_card_stack_opts, opts);
    self.pushEnd(zui_end_adapter_card_stack_end);
c.cui_card_stack_begin(self.h, self.tmpStr(id).ptr, count, &opts_c);
}

pub fn card_stack_item(self: *Ui, depth: i32) void {
    self.pushEnd(zui_end_adapter_card_stack_item_end);
c.cui_card_stack_item_begin(self.h, depth);
}

pub fn counter(self: *Ui, id: []const u8, value: f64, opts: CounterOpts) void {
    const opts_c = self.cvtOpts(c.cui_counter_opts, opts);
    c.cui_counter_ex(self.h, self.tmpStr(id).ptr, value, &opts_c);
}

pub fn ticker(self: *Ui, id: []const u8, items: []const TickerItem, opts: TickerOpts) void {
    const zp2_c = self.structArr(c.cui_ticker_item, items);
    const opts_c = self.cvtOpts(c.cui_ticker_opts, opts);
    c.cui_ticker_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(items.len), &opts_c);
}

pub fn heatmap(self: *Ui, id: []const u8, values: []const f32, cols: i32, opts: HeatmapOpts) i32 {
    const opts_c = self.cvtOpts(c.cui_heatmap_opts, opts);
    return c.cui_heatmap_ex(self.h, self.tmpStr(id).ptr, values.ptr, @intCast(values.len), cols, &opts_c);
}

pub fn calendar_heatmap(self: *Ui, id: []const u8, start: Date, values: []const f32, days: i32, opts: CalendarHeatmapOpts) i32 {
    const zp2_c = cvtFree(c.cui_date, start);
    const opts_c = self.cvtOpts(c.cui_calendar_heatmap_opts, opts);
    return c.cui_calendar_heatmap_ex(self.h, self.tmpStr(id).ptr, zp2_c, values.ptr, days, &opts_c);
}

pub fn treemap(self: *Ui, id: []const u8, items: []const VizItem, opts: TreemapOpts) i32 {
    const zp2_c = self.structArr(c.cui_viz_item, items);
    const opts_c = self.cvtOpts(c.cui_treemap_opts, opts);
    return c.cui_treemap_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(items.len), &opts_c);
}

pub fn radar_chart(self: *Ui, id: []const u8, series: []const Series, axes: []const []const u8, opts: RadarOpts) i32 {
    const zp2_c = self.structArr(c.cui_series, series);
    const zp4_c = self.strArr(axes);
    const opts_c = self.cvtOpts(c.cui_radar_opts, opts);
    return c.cui_radar_chart_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(series.len), zp4_c, @intCast(axes.len), &opts_c);
}

pub fn funnel(self: *Ui, id: []const u8, stages: []const VizItem, opts: FunnelOpts) i32 {
    const zp2_c = self.structArr(c.cui_viz_item, stages);
    const opts_c = self.cvtOpts(c.cui_funnel_opts, opts);
    return c.cui_funnel_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(stages.len), &opts_c);
}

/// Returns the clicked node index, node_count + the clicked input link index, or -1.
pub fn sankey(self: *Ui, id: []const u8, nodes: []const []const u8, links: []const SankeyLink, opts: SankeyOpts) i32 {
    const zp2_c = self.strArr(nodes);
    const zp4_c = self.structArr(c.cui_sankey_link, links);
    const opts_c = self.cvtOpts(c.cui_sankey_opts, opts);
    return c.cui_sankey_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(nodes.len), zp4_c, @intCast(links.len), &opts_c);
}

pub fn waffle(self: *Ui, id: []const u8, items: []const VizItem, opts: WaffleOpts) i32 {
    const zp2_c = self.structArr(c.cui_viz_item, items);
    const opts_c = self.cvtOpts(c.cui_waffle_opts, opts);
    return c.cui_waffle_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(items.len), &opts_c);
}

pub fn split_bar(self: *Ui, id: []const u8, items: []const VizItem, opts: SplitBarOpts) i32 {
    const zp2_c = self.structArr(c.cui_viz_item, items);
    const opts_c = self.cvtOpts(c.cui_split_bar_opts, opts);
    return c.cui_split_bar_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(items.len), &opts_c);
}

pub fn bar_list(self: *Ui, id: []const u8, items: []const VizItem, opts: BarListOpts) i32 {
    const zp2_c = self.structArr(c.cui_viz_item, items);
    const opts_c = self.cvtOpts(c.cui_bar_list_opts, opts);
    return c.cui_bar_list_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(items.len), &opts_c);
}

pub fn activity_rings(self: *Ui, id: []const u8, rings: []const VizItem, opts: RingsOpts) i32 {
    const zp2_c = self.structArr(c.cui_viz_item, rings);
    const opts_c = self.cvtOpts(c.cui_rings_opts, opts);
    return c.cui_activity_rings_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(rings.len), &opts_c);
}

pub fn scatter_chart(self: *Ui, id: []const u8, series: []const c.cui_scatter_series, opts: ScatterOpts) i32 {
    const opts_c = self.cvtOpts(c.cui_scatter_opts, opts);
    return c.cui_scatter_chart_ex(self.h, self.tmpStr(id).ptr, @ptrCast(series.ptr), @intCast(series.len), &opts_c);
}

pub fn radial_gauge(self: *Ui, id: []const u8, value: f32, min: f32, max: f32, opts: RadialGaugeOpts) void {
    const opts_c = self.cvtOpts(c.cui_radial_gauge_opts, opts);
    c.cui_radial_gauge_ex(self.h, self.tmpStr(id).ptr, value, min, max, &opts_c);
}

/// Returns the candle under the crosshair (pointer or keys), or -1.
pub fn candlestick(self: *Ui, id: []const u8, candles: []const Candle, opts: CandlestickOpts) i32 {
    const zp2_c = self.structArr(c.cui_candle, candles);
    const opts_c = self.cvtOpts(c.cui_candlestick_opts, opts);
    return c.cui_candlestick_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(candles.len), &opts_c);
}

/// Text with a highlight sweeping across it, for "Thinking..." states.
pub fn shimmer_text(self: *Ui, s: []const u8, opts: TextFxOpts) void {
    const opts_c = self.cvtOpts(c.cui_text_fx_opts, opts);
    c.cui_shimmer_text_ex(self.h, self.tmpStr(s).ptr, &opts_c);
}

/// Types the text out. When the text grows (streamed tokens) it carries on
/// from where it was; other changes start over. Returns true once complete.
pub fn typewriter(self: *Ui, id: []const u8, s: []const u8, opts: TextFxOpts) bool {
    const opts_c = self.cvtOpts(c.cui_text_fx_opts, opts);
    return c.cui_typewriter_ex(self.h, self.tmpStr(id).ptr, self.tmpStr(s).ptr, &opts_c);
}

/// Words fade and rise into place one after another, when first shown and
/// again whenever the text changes.
pub fn text_reveal(self: *Ui, id: []const u8, s: []const u8, opts: TextFxOpts) void {
    const opts_c = self.cvtOpts(c.cui_text_fx_opts, opts);
    c.cui_text_reveal_ex(self.h, self.tmpStr(id).ptr, self.tmpStr(s).ptr, &opts_c);
}

/// One word at a time; the next one rolls up into place and the width follows.
pub fn word_rotate(self: *Ui, id: []const u8, words: []const []const u8, interval: f32, opts: TextFxOpts) void {
    const zp2_c = self.strArr(words);
    const opts_c = self.cvtOpts(c.cui_text_fx_opts, opts);
    c.cui_word_rotate_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(words.len), interval, &opts_c);
}

/// A figure whose changed digits roll into place: up when the value rises, down
/// when it falls, a beat apart from the left; unchanged characters stay still.
/// Pass the formatted text ("$64,210", "1.2k"); digits are tabular.
pub fn number_roll(self: *Ui, id: []const u8, s: []const u8, opts: TextFxOpts) void {
    const opts_c = self.cvtOpts(c.cui_text_fx_opts, opts);
    c.cui_number_roll_ex(self.h, self.tmpStr(id).ptr, self.tmpStr(s).ptr, &opts_c);
}

pub fn gradient_text(self: *Ui, s: []const u8, opts: GradientTextOpts) void {
    const opts_c = self.cvtOpts(c.cui_gradient_text_opts, opts);
    c.cui_gradient_text_ex(self.h, self.tmpStr(s).ptr, &opts_c);
}

pub fn spotlight(self: *Ui, id: []const u8, opts: SpotlightOpts) void {
    const opts_c = self.cvtOpts(c.cui_spotlight_opts, opts);
    self.pushEnd(zui_end_adapter_spotlight_end);
c.cui_spotlight_begin(self.h, self.tmpStr(id).ptr, &opts_c);
}

pub fn loader(self: *Ui, opts: LoaderOpts) void {
    const opts_c = self.cvtOpts(c.cui_loader_opts, opts);
    c.cui_loader_ex(self.h, &opts_c);
}

pub fn dock(self: *Ui, id: []const u8, opts: DockOpts) void {
    const opts_c = self.cvtOpts(c.cui_dock_opts, opts);
    self.pushEnd(zui_end_adapter_dock_end);
c.cui_dock_begin(self.h, self.tmpStr(id).ptr, &opts_c);
}

pub fn dock_item(self: *Ui, icon_name: []const u8, label: []const u8, opts: DockItemOpts) bool {
    const opts_c = self.cvtOpts(c.cui_dock_item_opts, opts);
    return c.cui_dock_item_ex(self.h, self.tmpStr(icon_name).ptr, self.tmpStr(label).ptr, &opts_c);
}

pub fn dock_separator(self: *Ui) void {
    c.cui_dock_separator(self.h);
}

pub fn tab_bar(self: *Ui, id: []const u8, items: []const TabBarItem, selected: *i32, opts: TabBarOpts) bool {
    const zp2_c = self.structArr(c.cui_tab_bar_item, items);
    const opts_c = self.cvtOpts(c.cui_tab_bar_opts, opts);
    return c.cui_tab_bar_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(items.len), @ptrCast(selected), &opts_c);
}

pub fn control_tile(self: *Ui, label: []const u8, on: *bool, opts: TileOpts) bool {
    const opts_c = self.cvtOpts(c.cui_tile_opts, opts);
    return c.cui_control_tile_ex(self.h, self.tmpStr(label).ptr, on, &opts_c);
}

pub fn waveform(self: *Ui, id: []const u8, peaks: []const f32, progress: *f32, opts: WaveformOpts) bool {
    const opts_c = self.cvtOpts(c.cui_waveform_opts, opts);
    return c.cui_waveform_ex(self.h, self.tmpStr(id).ptr, peaks.ptr, @intCast(peaks.len), @ptrCast(progress), &opts_c);
}

pub fn now_playing(self: *Ui, id: []const u8, np: *c.cui_now_playing, opts: NowPlayingOpts) i32 {
    const opts_c = self.cvtOpts(c.cui_now_playing_opts, opts);
    return c.cui_now_playing_ex(self.h, self.tmpStr(id).ptr, @ptrCast(np), &opts_c);
}

pub fn reasoning(self: *Ui, id: []const u8, opts: ReasoningOpts) bool {
    const opts_c = self.cvtOpts(c.cui_reasoning_opts, opts);
    if (!(c.cui_reasoning_begin(self.h, self.tmpStr(id).ptr, &opts_c))) return false;
    self.pushEnd(zui_end_adapter_reasoning_end);
    return true;
}

pub fn tool_call(self: *Ui, id: []const u8, name: []const u8, opts: ToolCallOpts) void {
    const opts_c = self.cvtOpts(c.cui_tool_call_opts, opts);
    c.cui_tool_call_ex(self.h, self.tmpStr(id).ptr, self.tmpStr(name).ptr, &opts_c);
}

pub fn agent_plan(self: *Ui, id: []const u8, steps: []const PlanStep, opts: AgentPlanOpts) i32 {
    const zp2_c = self.structArr(c.cui_plan_step, steps);
    const opts_c = self.cvtOpts(c.cui_agent_plan_opts, opts);
    return c.cui_agent_plan_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(steps.len), &opts_c);
}

pub fn agent_status(self: *Ui, s: []const u8, opts: AgentStatusOpts) void {
    const opts_c = self.cvtOpts(c.cui_agent_status_opts, opts);
    c.cui_agent_status_ex(self.h, self.tmpStr(s).ptr, &opts_c);
}

pub fn source_list(self: *Ui, id: []const u8, sources: []const Source) i32 {
    const zp2_c = self.structArr(c.cui_source, sources);
    return c.cui_source_list(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(sources.len));
}

pub fn context_meter(self: *Ui, id: []const u8, used: f32, limit: f32, opts: ContextOpts) void {
    const opts_c = self.cvtOpts(c.cui_context_opts, opts);
    c.cui_context_meter_ex(self.h, self.tmpStr(id).ptr, used, limit, &opts_c);
}

pub fn response_actions(self: *Ui, id: []const u8, opts: ResponseActionsOpts) i32 {
    const opts_c = self.cvtOpts(c.cui_response_actions_opts, opts);
    return c.cui_response_actions_ex(self.h, self.tmpStr(id).ptr, &opts_c);
}

pub fn prompt_suggestions(self: *Ui, id: []const u8, items: []const PromptSuggestion, opts: PromptSuggestionsOpts) i32 {
    const zp2_c = self.structArr(c.cui_prompt_suggestion, items);
    const opts_c = self.cvtOpts(c.cui_prompt_suggestions_opts, opts);
    return c.cui_prompt_suggestions_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(items.len), &opts_c);
}

pub fn model_picker(self: *Ui, id: []const u8, models: []const Model, selected: *i32, opts: ModelPickerOpts) bool {
    const zp2_c = self.structArr(c.cui_model, models);
    const opts_c = self.cvtOpts(c.cui_model_picker_opts, opts);
    return c.cui_model_picker_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(models.len), @ptrCast(selected), &opts_c);
}

pub fn chat_composer(self: *Ui, id: []const u8, buf: []u8, cap: usize, opts: ComposerOpts) i32 {
    const opts_c = self.cvtOpts(c.cui_composer_opts, opts);
    return c.cui_chat_composer_ex(self.h, self.tmpStr(id).ptr, buf.ptr, cap, &opts_c);
}

pub fn voice_orb(self: *Ui, id: []const u8, st: VoiceState, level: f32, opts: VoiceOrbOpts) bool {
    const opts_c = self.cvtOpts(c.cui_voice_orb_opts, opts);
    return c.cui_voice_orb_ex(self.h, self.tmpStr(id).ptr, enumOrInt(c.cui_voice_state, st), level, &opts_c);
}

pub fn voice_wave(self: *Ui, id: []const u8, levels: []const f32, opts: VoiceWaveOpts) bool {
    const opts_c = self.cvtOpts(c.cui_voice_wave_opts, opts);
    return c.cui_voice_wave_ex(self.h, self.tmpStr(id).ptr, levels.ptr, @intCast(levels.len), &opts_c);
}

pub fn voice_note(self: *Ui, id: []const u8, note: *c.cui_voice_note, opts: VoiceNoteOpts) i32 {
    const opts_c = self.cvtOpts(c.cui_voice_note_opts, opts);
    return c.cui_voice_note_ex(self.h, self.tmpStr(id).ptr, @ptrCast(note), &opts_c);
}

pub fn voice_session(self: *Ui, id: []const u8, st: VoiceState, levels: []const f32, opts: VoiceSessionOpts) i32 {
    const opts_c = self.cvtOpts(c.cui_voice_session_opts, opts);
    return c.cui_voice_session_ex(self.h, self.tmpStr(id).ptr, enumOrInt(c.cui_voice_state, st), levels.ptr, @intCast(levels.len), &opts_c);
}

pub fn kanban_begin(self: *Ui, id: []const u8) void {
    c.cui_kanban_begin(self.h, self.tmpStr(id).ptr);
}

pub fn kanban_column(self: *Ui, title: []const u8, card_count: i32, opts: KanbanColumnOpts) void {
    const opts_c = self.cvtOpts(c.cui_kanban_column_opts, opts);
    self.pushEnd(zui_end_adapter_kanban_column_end);
_ = c.cui_kanban_column_begin_ex(self.h, self.tmpStr(title).ptr, card_count, &opts_c);
}

pub fn kanban_card(self: *Ui, card_id: i32) void {
    self.pushEnd(zui_end_adapter_kanban_card_end);
_ = c.cui_kanban_card_begin(self.h, card_id);
}

pub fn kanban_end(self: *Ui, move: *c.cui_kanban_move) bool {
    return c.cui_kanban_end(self.h, @ptrCast(move));
}

/// Returns the activated event index or -1. Read-only events still activate.
/// Pointer activation requires staying within the drag threshold through release.
/// A drag ends when the event list shrinks, the calendar is disabled or
/// `read_only` changes; moving the event again takes a new press.
pub fn week_calendar(self: *Ui, id: []const u8, week_start: Date, events: []c.cui_cal_event, opts: WeekOpts) i32 {
    const zp2_c = cvtFree(c.cui_date, week_start);
    const opts_c = self.cvtOpts(c.cui_week_opts, opts);
    return c.cui_week_calendar_ex(self.h, self.tmpStr(id).ptr, zp2_c, @ptrCast(events.ptr), @intCast(events.len), &opts_c);
}

pub fn month_calendar(self: *Ui, id: []const u8, month: *c.cui_date, events: []const MonthEvent, opts: MonthOpts) MonthResult {
    const zp3_c = self.structArr(c.cui_month_event, events);
    const opts_c = self.cvtOpts(c.cui_month_opts, opts);
    return cvtBackStruct(MonthResult, c.cui_month_calendar_ex(self.h, self.tmpStr(id).ptr, @ptrCast(month), zp3_c, @intCast(events.len), &opts_c));
}

/// Returns the activated task index or -1. Read-only tasks still activate.
/// A drag ends when the task list shrinks, the chart is disabled or
/// `read_only` changes; moving the bar again takes a new press.
pub fn gantt(self: *Ui, id: []const u8, tasks: []c.cui_gantt_task, origin: Date, days: i32, opts: GanttOpts) i32 {
    const zp4_c = cvtFree(c.cui_date, origin);
    const opts_c = self.cvtOpts(c.cui_gantt_opts, opts);
    return c.cui_gantt_ex(self.h, self.tmpStr(id).ptr, @ptrCast(tasks.ptr), @intCast(tasks.len), zp4_c, days, &opts_c);
}

pub fn hover_card(self: *Ui, id: []const u8, opts: HoverCardOpts) bool {
    const opts_c = self.cvtOpts(c.cui_hover_card_opts, opts);
    if (!(c.cui_hover_card_begin(self.h, self.tmpStr(id).ptr, &opts_c))) return false;
    self.pushEnd(zui_end_adapter_hover_card_end);
    return true;
}

pub fn confirm_popover(self: *Ui, id: []const u8, opts: ConfirmPopoverOpts) bool {
    const opts_c = self.cvtOpts(c.cui_confirm_popover_opts, opts);
    return c.cui_confirm_popover_ex(self.h, self.tmpStr(id).ptr, &opts_c);
}

pub fn expandable_text(self: *Ui, id: []const u8, s: []const u8, opts: ExpandableTextOpts) bool {
    const opts_c = self.cvtOpts(c.cui_expandable_text_opts, opts);
    return c.cui_expandable_text_ex(self.h, self.tmpStr(id).ptr, self.tmpStr(s).ptr, &opts_c);
}

pub fn expandable_card(self: *Ui, title: []const u8, open: *bool, opts: ExpandableCardOpts) bool {
    const opts_c = self.cvtOpts(c.cui_expandable_card_opts, opts);
    if (!(c.cui_expandable_card_begin(self.h, self.tmpStr(title).ptr, open, &opts_c))) return false;
    self.pushEnd(zui_end_adapter_expandable_card_end);
    return true;
}

pub fn toc(self: *Ui, scroll_id: []const u8, items: []const TocItem) i32 {
    const zp2_c = self.structArr(c.cui_toc_item, items);
    return c.cui_toc(self.h, self.tmpStr(scroll_id).ptr, zp2_c, @intCast(items.len));
}

pub fn toc_anchor(self: *Ui, anchor: []const u8) void {
    c.cui_toc_anchor(self.h, self.tmpStr(anchor).ptr);
}

pub fn banner(self: *Ui, s: []const u8, open: *bool, opts: BannerOpts) bool {
    const opts_c = self.cvtOpts(c.cui_banner_opts, opts);
    return c.cui_banner_ex(self.h, self.tmpStr(s).ptr, open, &opts_c);
}

pub fn countdown(self: *Ui, id: []const u8, seconds_left: f64, opts: CountdownOpts) void {
    const opts_c = self.cvtOpts(c.cui_countdown_opts, opts);
    c.cui_countdown_ex(self.h, self.tmpStr(id).ptr, seconds_left, &opts_c);
}

pub fn checklist(self: *Ui, id: []const u8, steps: []c.cui_check_step, opts: ChecklistOpts) i32 {
    const opts_c = self.cvtOpts(c.cui_checklist_opts, opts);
    return c.cui_checklist_ex(self.h, self.tmpStr(id).ptr, @ptrCast(steps.ptr), @intCast(steps.len), &opts_c);
}

pub fn veil(self: *Ui, id: []const u8, revealed: *bool, opts: VeilOpts) void {
    const opts_c = self.cvtOpts(c.cui_veil_opts, opts);
    self.pushEnd(zui_end_adapter_veil_end);
_ = c.cui_veil_begin_ex(self.h, self.tmpStr(id).ptr, revealed, &opts_c);
}

pub fn multi_select(self: *Ui, id: []const u8, items: []const []const u8, selected: *bool, opts: MultiSelectOpts) bool {
    const zp2_c = self.strArr(items);
    const opts_c = self.cvtOpts(c.cui_multi_select_opts, opts);
    return c.cui_multi_select_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(items.len), selected, &opts_c);
}

/// One or two months side by side; click a start and an end.
pub fn range_calendar(self: *Ui, id: []const u8, range: *c.cui_date_range, months: i32) bool {
    return c.cui_range_calendar(self.h, self.tmpStr(id).ptr, @ptrCast(range), months);
}

pub fn date_range_picker(self: *Ui, id: []const u8, range: *c.cui_date_range, opts: DateRangeOpts) bool {
    const opts_c = self.cvtOpts(c.cui_date_range_opts, opts);
    return c.cui_date_range_picker_ex(self.h, self.tmpStr(id).ptr, @ptrCast(range), &opts_c);
}

pub fn time_picker(self: *Ui, id: []const u8, hour: *i32, minute: *i32, opts: TimeOpts) bool {
    const opts_c = self.cvtOpts(c.cui_time_opts, opts);
    return c.cui_time_picker_ex(self.h, self.tmpStr(id).ptr, @ptrCast(hour), @ptrCast(minute), &opts_c);
}

pub fn wheel_picker(self: *Ui, id: []const u8, items: []const []const u8, index: *i32, opts: WheelOpts) bool {
    const zp2_c = self.strArr(items);
    const opts_c = self.cvtOpts(c.cui_wheel_opts, opts);
    return c.cui_wheel_picker_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(items.len), @ptrCast(index), &opts_c);
}

/// Time dial: a clock face. Drag the hand to set hours, then minutes.
pub fn time_dial(self: *Ui, id: []const u8, hour: *i32, minute: *i32, size_arg: f32) bool {
    return c.cui_time_dial(self.h, self.tmpStr(id).ptr, @ptrCast(hour), @ptrCast(minute), size_arg);
}

pub fn ruler_slider(self: *Ui, label: []const u8, value: *f32, min: f32, max: f32, opts: RulerOpts) bool {
    const opts_c = self.cvtOpts(c.cui_ruler_opts, opts);
    return c.cui_ruler_slider_ex(self.h, self.tmpStr(label).ptr, @ptrCast(value), min, max, &opts_c);
}

pub fn histogram_slider(self: *Ui, label: []const u8, bins: []const f32, bin_count: i32, lo: *f32, hi: *f32, min: f32, max: f32, opts: HistogramOpts) bool {
    const opts_c = self.cvtOpts(c.cui_histogram_opts, opts);
    return c.cui_histogram_slider_ex(self.h, self.tmpStr(label).ptr, bins.ptr, bin_count, @ptrCast(lo), @ptrCast(hi), min, max, &opts_c);
}

pub fn knob(self: *Ui, id: []const u8, value: *f32, min: f32, max: f32, opts: KnobOpts) bool {
    const opts_c = self.cvtOpts(c.cui_knob_opts, opts);
    return c.cui_knob_ex(self.h, self.tmpStr(id).ptr, @ptrCast(value), min, max, &opts_c);
}

pub fn fader(self: *Ui, id: []const u8, value: *f32, min: f32, max: f32, opts: FaderOpts) bool {
    const opts_c = self.cvtOpts(c.cui_fader_opts, opts);
    return c.cui_fader_ex(self.h, self.tmpStr(id).ptr, @ptrCast(value), min, max, &opts_c);
}

/// Returns true when the clip light was clicked to clear it.
pub fn level_meter(self: *Ui, id: []const u8, levels: []const f32, opts: LevelMeterOpts) bool {
    const opts_c = self.cvtOpts(c.cui_level_meter_opts, opts);
    return c.cui_level_meter_ex(self.h, self.tmpStr(id).ptr, levels.ptr, @intCast(levels.len), &opts_c);
}

pub fn signature_pad(self: *Ui, id: []const u8, opts: SignatureOpts) bool {
    const opts_c = self.cvtOpts(c.cui_signature_opts, opts);
    return c.cui_signature_pad_ex(self.h, self.tmpStr(id).ptr, &opts_c);
}

pub fn signature_clear(self: *Ui, id: []const u8) void {
    c.cui_signature_clear(self.h, self.tmpStr(id).ptr);
}

pub fn dropzone(self: *Ui, id: []const u8, opts: DropzoneOpts) i32 {
    const opts_c = self.cvtOpts(c.cui_dropzone_opts, opts);
    return c.cui_dropzone_ex(self.h, self.tmpStr(id).ptr, &opts_c);
}

/// Avatar upload: a round avatar that takes a dropped image, with a camera
/// badge on hover. Returns 1 when *image changed, -1 when clicked (browse),
/// 0 otherwise. A dropped image is loaded with cui_image_load.
pub fn avatar_upload(self: *Ui, id: []const u8, name: []const u8, image: *usize, size_arg: f32) i32 {
    return c.cui_avatar_upload(self.h, self.tmpStr(id).ptr, self.tmpStr(name).ptr, @ptrCast(image), size_arg);
}

pub fn inline_edit(self: *Ui, id: []const u8, buf: []u8, cap: usize, opts: InlineEditOpts) i32 {
    const opts_c = self.cvtOpts(c.cui_inline_edit_opts, opts);
    return c.cui_inline_edit_ex(self.h, self.tmpStr(id).ptr, buf.ptr, cap, &opts_c);
}

pub fn scrub(self: *Ui, label: []const u8, value: *f32, min: f32, max: f32, opts: ScrubOpts) bool {
    const opts_c = self.cvtOpts(c.cui_scrub_opts, opts);
    return c.cui_scrub_ex(self.h, self.tmpStr(label).ptr, @ptrCast(value), min, max, &opts_c);
}

pub fn money_input(self: *Ui, id: []const u8, value: *f64, opts: MoneyOpts) bool {
    const opts_c = self.cvtOpts(c.cui_money_opts, opts);
    return c.cui_money_input_ex(self.h, self.tmpStr(id).ptr, @ptrCast(value), &opts_c);
}

pub fn shortcut_recorder(self: *Ui, id: []const u8, combo: *c.cui_key_combo, opts: ShortcutRecorderOpts) bool {
    const opts_c = self.cvtOpts(c.cui_shortcut_recorder_opts, opts);
    return c.cui_shortcut_recorder_ex(self.h, self.tmpStr(id).ptr, @ptrCast(combo), &opts_c);
}

pub fn shortcut_label(self: *Ui, combo: KeyCombo) []const u8 {
    const zp1_c = cvtFree(c.cui_key_combo, combo);
    return spanOrEmpty(c.cui_shortcut_label(self.h, zp1_c));
}

pub fn node_editor(self: *Ui, id: []const u8, view: *c.cui_node_view, opts: NodeEditorOpts) void {
    const opts_c = self.cvtOpts(c.cui_node_editor_opts, opts);
    self.pushEnd(zui_end_adapter_node_editor_end);
_ = c.cui_node_editor_begin_ex(self.h, self.tmpStr(id).ptr, @ptrCast(view), &opts_c);
}

pub fn node(self: *Ui, node_id: i32, x: *f32, y: *f32, title: []const u8, opts: NodeOpts) void {
    const opts_c = self.cvtOpts(c.cui_node_opts, opts);
    self.pushEnd(zui_end_adapter_node_end);
_ = c.cui_node_begin_ex(self.h, node_id, @ptrCast(x), @ptrCast(y), self.tmpStr(title).ptr, &opts_c);
}

pub fn node_input(self: *Ui, pin_id: i32, label: []const u8, opts: PinOpts) bool {
    const opts_c = self.cvtOpts(c.cui_pin_opts, opts);
    return c.cui_node_input_ex(self.h, pin_id, self.tmpStr(label).ptr, &opts_c);
}

pub fn node_output(self: *Ui, pin_id: i32, label: []const u8, opts: PinOpts) bool {
    const opts_c = self.cvtOpts(c.cui_pin_opts, opts);
    return c.cui_node_output_ex(self.h, pin_id, self.tmpStr(label).ptr, &opts_c);
}

/// A row for ordinary components. They are laid out at 100% and scaled with
/// the view, so their text is sharpest at 100% zoom and below.
pub fn node_content(self: *Ui) void {
    self.pushEnd(zui_end_adapter_node_content_end);
c.cui_node_content_begin(self.h);
}

/// A link from an output pin to an input pin. Returns true while it is selected.
pub fn node_link(self: *Ui, link_id: i32, from_pin: i32, to_pin: i32) bool {
    return c.cui_node_link(self.h, link_id, from_pin, to_pin);
}

/// What the user did this frame, one event per call; call them after
/// cui_node_editor_begin (and up to the end of the frame).
pub fn node_link_created(self: *Ui, from_pin: *i32, to_pin: *i32) bool {
    return c.cui_node_link_created(self.h, @ptrCast(from_pin), @ptrCast(to_pin));
}

pub fn node_link_removed(self: *Ui, link_id: *i32) bool {
    return c.cui_node_link_removed(self.h, @ptrCast(link_id));
}

pub fn node_deleted(self: *Ui, node_id: *i32) bool {
    return c.cui_node_deleted(self.h, @ptrCast(node_id));
}

pub fn menu_bar(self: *Ui, id: []const u8, opts: MenuBarOpts) void {
    const opts_c = self.cvtOpts(c.cui_menu_bar_opts, opts);
    self.pushEnd(zui_end_adapter_menu_bar_end);
c.cui_menu_bar_begin(self.h, self.tmpStr(id).ptr, &opts_c);
}

pub fn menu_bar_menu(self: *Ui, label: []const u8, opts: MenuBarMenuOpts) bool {
    const opts_c = self.cvtOpts(c.cui_menu_bar_menu_opts, opts);
    if (!(c.cui_menu_bar_menu_begin(self.h, self.tmpStr(label).ptr, &opts_c))) return false;
    self.pushEnd(zui_end_adapter_menu_bar_menu_end);
    return true;
}

pub fn toolbar(self: *Ui, id: []const u8, opts: ToolbarOpts) void {
    const opts_c = self.cvtOpts(c.cui_toolbar_opts, opts);
    self.pushEnd(zui_end_adapter_toolbar_end);
c.cui_toolbar_begin(self.h, self.tmpStr(id).ptr, &opts_c);
}

pub fn toolbar_button(self: *Ui, icon_name: []const u8, opts: ToolOpts) bool {
    const opts_c = self.cvtOpts(c.cui_tool_opts, opts);
    return c.cui_toolbar_button_ex(self.h, self.tmpStr(icon_name).ptr, &opts_c);
}

pub fn toolbar_separator(self: *Ui) void {
    c.cui_toolbar_separator(self.h);
}

pub fn toolbar_spacer(self: *Ui) void {
    c.cui_toolbar_spacer(self.h);
}

/// A group of items: a raised well in the grouped style, set apart by separators in the others.
pub fn toolbar_group(self: *Ui) void {
    self.pushEnd(zui_end_adapter_toolbar_group_end);
c.cui_toolbar_group_begin(self.h);
}

pub fn toolbar_radio(self: *Ui, id: []const u8, icons: []const []const u8, index: *i32, opts: ToolbarRadioOpts) bool {
    const zp2_c = self.strArr(icons);
    const opts_c = self.cvtOpts(c.cui_toolbar_radio_opts, opts);
    return c.cui_toolbar_radio_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(icons.len), @ptrCast(index), &opts_c);
}

/// The main action at the end of a grouped toolbar: a larger button filled with the text color.
pub fn toolbar_primary(self: *Ui, icon_name: []const u8, opts: ToolOpts) bool {
    const opts_c = self.cvtOpts(c.cui_tool_opts, opts);
    return c.cui_toolbar_primary_ex(self.h, self.tmpStr(icon_name).ptr, &opts_c);
}

/// A small picker that steps through its choices on each click ("1x", "2x", "4x").
/// Returns true when *index changed.
pub fn toolbar_cycle(self: *Ui, id: []const u8, items: []const []const u8, index: *i32, opts: ToolOpts) bool {
    const zp2_c = self.strArr(items);
    const opts_c = self.cvtOpts(c.cui_tool_opts, opts);
    return c.cui_toolbar_cycle_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(items.len), @ptrCast(index), &opts_c);
}

/// A small triangle in the corner of the previous component (at the end side) that
/// says it opens a flyout or a menu. Any button can take it.
pub fn flyout_mark(self: *Ui) void {
    c.cui_flyout_mark(self.h);
}

pub fn status_bar(self: *Ui, id: []const u8, opts: StatusBarOpts) void {
    const opts_c = self.cvtOpts(c.cui_status_bar_opts, opts);
    self.pushEnd(zui_end_adapter_status_bar_end);
c.cui_status_bar_begin(self.h, self.tmpStr(id).ptr, &opts_c);
}

pub fn status_bar_spacer(self: *Ui) void {
    c.cui_status_bar_spacer(self.h);
}

/// A message; `tone` colors its icon.
pub fn status_bar_text(self: *Ui, s: []const u8, opts: StatusItemOpts) void {
    const opts_c = self.cvtOpts(c.cui_status_item_opts, opts);
    c.cui_status_bar_text_ex(self.h, self.tmpStr(s).ptr, &opts_c);
}

/// A small clickable item ("Ln 12, Col 4", "UTF-8"). Returns true when clicked.
pub fn status_bar_item(self: *Ui, label: []const u8, opts: StatusItemOpts) bool {
    const opts_c = self.cvtOpts(c.cui_status_item_opts, opts);
    return c.cui_status_bar_item_ex(self.h, self.tmpStr(label).ptr, &opts_c);
}

pub fn status_bar_progress(self: *Ui, value: f32, opts: StatusProgressOpts) void {
    const opts_c = self.cvtOpts(c.cui_status_progress_opts, opts);
    c.cui_status_bar_progress_ex(self.h, value, &opts_c);
}

pub fn doc_tabs(self: *Ui, id: []const u8, tabs_arg: []const DocTab, selected: *i32, opts: DocTabsOpts) DocTabsResult {
    const zp2_c = self.structArr(c.cui_doc_tab, tabs_arg);
    const opts_c = self.cvtOpts(c.cui_doc_tabs_opts, opts);
    return cvtBackStruct(DocTabsResult, c.cui_doc_tabs_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(tabs_arg.len), @ptrCast(selected), &opts_c));
}

pub fn dockspace(self: *Ui, id: []const u8, opts: DockspaceOpts) void {
    const opts_c = self.cvtOpts(c.cui_dockspace_opts, opts);
    self.pushEnd(zui_end_adapter_dockspace_end);
c.cui_dockspace_begin_ex(self.h, self.tmpStr(id).ptr, &opts_c);
}

pub fn dock_panel(self: *Ui, title: []const u8, open: *bool, opts: DockPanelOpts) bool {
    const opts_c = self.cvtOpts(c.cui_dock_panel_opts, opts);
    if (!(c.cui_dock_panel_begin_ex(self.h, self.tmpStr(title).ptr, open, &opts_c))) return false;
    self.pushEnd(zui_end_adapter_dock_panel_end);
    return true;
}

/// Saved layout: one line, e.g.
/// dock1 h0.22([*Scene tree,Assets],v0.7([*Viewport],[*Log,-Console]))
/// h splits side by side and v stacks, the number is the first child's share,
/// [..] is a leaf's tabs in order, * the selected tab, - a closed panel; a
/// backslash escapes , [ ] ( ) and itself in names. cui_dock_save returns the full length (as
/// snprintf does) and writes what fits, or 0 when there is no layout.
/// cui_dock_load replaces the layout (and sets each panel's *open from it on
/// its next frame); names it does not know yet are kept for when they appear.
/// Malformed text returns false and changes nothing.
pub fn dock_save(self: *Ui, id: []const u8, buf: []u8, cap: usize) usize {
    return c.cui_dock_save(self.h, self.tmpStr(id).ptr, buf.ptr, cap);
}

pub fn dock_load(self: *Ui, id: []const u8, s: []const u8) bool {
    return c.cui_dock_load(self.h, self.tmpStr(id).ptr, self.tmpStr(s).ptr);
}

pub fn inspector(self: *Ui, id: []const u8, opts: InspectorOpts) bool {
    const opts_c = self.cvtOpts(c.cui_inspector_opts, opts);
    if (!(c.cui_inspector_begin_ex(self.h, self.tmpStr(id).ptr, &opts_c))) return false;
    self.pushEnd(zui_end_adapter_inspector_end);
    return true;
}

/// A folding group header. Build its rows only when this returns true (it
/// stays true while the group animates closed). open may be NULL for a plain
/// section that does not fold.
pub fn inspector_group(self: *Ui, title: []const u8, open: *bool) bool {
    return c.cui_inspector_group(self.h, self.tmpStr(title).ptr, open);
}

pub fn prop_float(self: *Ui, label: []const u8, value: *f32, opts: PropOpts) bool {
    const opts_c = self.cvtOpts(c.cui_prop_opts, opts);
    return c.cui_prop_float_ex(self.h, self.tmpStr(label).ptr, @ptrCast(value), &opts_c);
}

pub fn prop_int(self: *Ui, label: []const u8, value: *i32, opts: PropOpts) bool {
    const opts_c = self.cvtOpts(c.cui_prop_opts, opts);
    return c.cui_prop_int_ex(self.h, self.tmpStr(label).ptr, @ptrCast(value), &opts_c);
}

pub fn prop_text(self: *Ui, label: []const u8, buf: []u8, cap: usize, opts: PropOpts) bool {
    const opts_c = self.cvtOpts(c.cui_prop_opts, opts);
    return c.cui_prop_text_ex(self.h, self.tmpStr(label).ptr, buf.ptr, cap, &opts_c);
}

pub fn prop_bool(self: *Ui, label: []const u8, value: *bool, opts: PropOpts) bool {
    const opts_c = self.cvtOpts(c.cui_prop_opts, opts);
    return c.cui_prop_bool_ex(self.h, self.tmpStr(label).ptr, value, &opts_c);
}

pub fn prop_enum(self: *Ui, label: []const u8, items: []const []const u8, index: *i32, opts: PropOpts) bool {
    const zp2_c = self.strArr(items);
    const opts_c = self.cvtOpts(c.cui_prop_opts, opts);
    return c.cui_prop_enum_ex(self.h, self.tmpStr(label).ptr, zp2_c, @intCast(items.len), @ptrCast(index), &opts_c);
}

/// A swatch and hex value that opens the color picker.
pub fn prop_color(self: *Ui, label: []const u8, value: *Color, opts: PropOpts) bool {
    var zp2_c: c.cui_color = colorToC(value.*);
    const opts_c = self.cvtOpts(c.cui_prop_opts, opts);
    const result = c.cui_prop_color_ex(self.h, self.tmpStr(label).ptr, &zp2_c, &opts_c);
    value.* = colorFromC(zp2_c);
    return result;
}

/// Compact X, Y (Z, W) scrub fields side by side; value holds 2, 3 or 4 floats.
pub fn prop_vec(self: *Ui, label: []const u8, value: *f32, components: i32, opts: PropOpts) bool {
    const opts_c = self.cvtOpts(c.cui_prop_opts, opts);
    return c.cui_prop_vec_ex(self.h, self.tmpStr(label).ptr, @ptrCast(value), components, &opts_c);
}

/// Toolbar: level filters, a search field that filters and highlights,
/// Follow (keeps the newest line in view; scrolling up turns it off, reaching
/// the bottom turns it back on), Copy (selected lines, or all shown) and Clear.
/// Click a line to select it, Shift+click for a range; with the list focused,
/// arrows move, Shift+arrows extend, Ctrl+A selects all, Ctrl+C copies, Esc
/// clears the selection, End follows again.
pub fn log_view(self: *Ui, id: []const u8, buf: *c.cui_log_buffer, opts: LogViewOpts) void {
    const opts_c = self.cvtOpts(c.cui_log_view_opts, opts);
    c.cui_log_view_ex(self.h, self.tmpStr(id).ptr, @ptrCast(buf), &opts_c);
}

pub fn terminal(self: *Ui, id: []const u8, t: *c.cui_terminal_buffer, opts: TerminalOpts) TerminalResult {
    const opts_c = self.cvtOpts(c.cui_terminal_opts, opts);
    return cvtBackStruct(TerminalResult, c.cui_terminal_ex(self.h, self.tmpStr(id).ptr, @ptrCast(t), &opts_c));
}

/// ---- Emoji ----
/// Color emoji come from an emoji font: the system's (cui_emoji_font_load_system, which
/// the picker calls by itself when nothing is loaded) or one the app ships. Bitmap color
/// fonts (sbix as on macOS, CBDT as on Linux and Android) and layered ones (COLR version 0,
/// as on Windows) are read, as is a plain outline font for one-color emoji. Sequences with
/// skin tones, joined people and flags are looked up through the font's ligatures. Big
/// fonts are read from the file as needed rather than loaded whole. Drawn emoji are kept in
/// one texture and reused.
pub fn emoji_font_load_file(self: *Ui, path: []const u8) bool {
    return c.cui_emoji_font_load_file(self.h, self.tmpStr(path).ptr);
}

pub fn emoji_font_load_memory(self: *Ui, data: []const u8, copy: bool) bool {
    return c.cui_emoji_font_load_memory(self.h, data.ptr, @intCast(data.len), copy);
}

pub fn emoji_font_load_system(self: *Ui) bool {
    return c.cui_emoji_font_load_system(self.h);
}

pub fn emoji_supported(self: *Ui, utf8: []const u8) bool {
    return c.cui_emoji_supported(self.h, utf8.ptr, @intCast(utf8.len));
}

pub fn draw_emoji(self: *Ui, utf8: []const u8, r: Rect) void {
    const zp2_c = rectToC(r);
    c.cui_draw_emoji(self.h, utf8.ptr, @intCast(utf8.len), zp2_c);
}

pub fn emoji(self: *Ui, utf8: []const u8, size_arg: f32) void {
    c.cui_emoji(self.h, self.tmpStr(utf8).ptr, size_arg);
}

pub fn emoji_picker(self: *Ui, id: []const u8, opts: EmojiPickerOpts) []const u8 {
    const opts_c = self.cvtOpts(c.cui_emoji_picker_opts, opts);
    return spanOrEmpty(c.cui_emoji_picker_ex(self.h, self.tmpStr(id).ptr, &opts_c));
}

/// sel may be NULL: the view then keeps the selection itself.
pub fn hex_view(self: *Ui, id: []const u8, data: []const u8, sel: *c.cui_hex_selection, opts: HexViewOpts) HexResult {
    const opts_c = self.cvtOpts(c.cui_hex_view_opts, opts);
    return cvtBackStruct(HexResult, c.cui_hex_view_ex(self.h, self.tmpStr(id).ptr, data.ptr, @intCast(data.len), @ptrCast(sel), &opts_c));
}

/// Go to offset: on the view's next frame its cursor moves to offset, that byte
/// becomes the selection and it scrolls into view (to the middle when it was
/// out of sight). Wire a "Go to" field to it; it is safe to call every frame.
pub fn hex_view_goto(self: *Ui, id: []const u8, offset: usize) void {
    c.cui_hex_view_goto(self.h, self.tmpStr(id).ptr, offset);
}

/// selected: index into spans, -1 for none (may be NULL).
pub fn flame_graph(self: *Ui, id: []const u8, spans: []const FlameSpan, view: *c.cui_flame_view, selected: *i32, opts: FlameOpts) FlameResult {
    const zp2_c = self.structArr(c.cui_flame_span, spans);
    const opts_c = self.cvtOpts(c.cui_flame_opts, opts);
    return cvtBackStruct(FlameResult, c.cui_flame_graph_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(spans.len), @ptrCast(view), @ptrCast(selected), &opts_c));
}

pub fn curve_editor(self: *Ui, id: []const u8, keys: *c.cui_curve_key, count: *i32, capacity: i32, opts: CurveOpts) CurveResult {
    const opts_c = self.cvtOpts(c.cui_curve_opts, opts);
    return cvtBackStruct(CurveResult, c.cui_curve_editor_ex(self.h, self.tmpStr(id).ptr, @ptrCast(keys), @ptrCast(count), capacity, &opts_c));
}

pub fn gradient_editor(self: *Ui, id: []const u8, stops: *c.cui_gradient_stop, count: *i32, capacity: i32, opts: GradientOpts) GradientResult {
    const opts_c = self.cvtOpts(c.cui_gradient_opts, opts);
    return cvtBackStruct(GradientResult, c.cui_gradient_editor_ex(self.h, self.tmpStr(id).ptr, @ptrCast(stops), @ptrCast(count), capacity, &opts_c));
}

pub fn status_tag(self: *Ui, label: []const u8, status: TagStatus, opts: StatusTagOpts) bool {
    const opts_c = self.cvtOpts(c.cui_status_tag_opts, opts);
    return c.cui_status_tag_ex(self.h, self.tmpStr(label).ptr, enumOrInt(c.cui_tag_status, status), &opts_c);
}

pub fn ratio_slider(self: *Ui, first: []const u8, second: []const u8, ratio: *f32, opts: RatioSliderOpts) bool {
    const opts_c = self.cvtOpts(c.cui_ratio_slider_opts, opts);
    return c.cui_ratio_slider_ex(self.h, self.tmpStr(first).ptr, self.tmpStr(second).ptr, @ptrCast(ratio), &opts_c);
}

pub fn gradient_slider(self: *Ui, label: []const u8, value: *f32, min: f32, max: f32, opts: GradientSliderOpts) i32 {
    const opts_c = self.cvtOpts(c.cui_gradient_slider_opts, opts);
    return c.cui_gradient_slider_ex(self.h, self.tmpStr(label).ptr, @ptrCast(value), min, max, &opts_c);
}

pub fn step_slider(self: *Ui, label: []const u8, value: *i32, min: i32, max: i32, opts: StepSliderOpts) i32 {
    const opts_c = self.cvtOpts(c.cui_step_slider_opts, opts);
    return c.cui_step_slider_ex(self.h, self.tmpStr(label).ptr, @ptrCast(value), min, max, &opts_c);
}

pub fn palette_strip(self: *Ui, label: []const u8, colors: []Color, locked: *bool, opts: PaletteStripOpts) i32 {
    const opts_c = self.cvtOpts(c.cui_palette_strip_opts, opts);
    return c.cui_palette_strip_ex(self.h, self.tmpStr(label).ptr, @ptrCast(colors.ptr), locked, @intCast(colors.len), &opts_c);
}

pub fn aspect_picker(self: *Ui, label: []const u8, index: *i32, opts: AspectPickerOpts) bool {
    const opts_c = self.cvtOpts(c.cui_aspect_picker_opts, opts);
    return c.cui_aspect_picker_ex(self.h, self.tmpStr(label).ptr, @ptrCast(index), &opts_c);
}

pub fn option_action(self: *Ui, label: []const u8, items: []const []const u8, index: *i32, icon_name: []const u8, opts: OptionActionOpts) i32 {
    const zp2_c = self.strArr(items);
    const opts_c = self.cvtOpts(c.cui_option_action_opts, opts);
    return c.cui_option_action_ex(self.h, self.tmpStr(label).ptr, zp2_c, @intCast(items.len), @ptrCast(index), self.tmpStr(icon_name).ptr, &opts_c);
}

pub fn seed_field(self: *Ui, label: []const u8, seed: *u32, locked: *bool, opts: SeedFieldOpts) i32 {
    const opts_c = self.cvtOpts(c.cui_seed_field_opts, opts);
    return c.cui_seed_field_ex(self.h, self.tmpStr(label).ptr, @ptrCast(seed), locked, &opts_c);
}

/// time: the playhead in seconds (may be NULL).
pub fn timeline_editor(self: *Ui, id: []const u8, tracks: []c.cui_timeline_track, time: *f32, opts: TimelineEditorOpts) TimelineEditorResult {
    const opts_c = self.cvtOpts(c.cui_timeline_editor_opts, opts);
    return cvtBackStruct(TimelineEditorResult, c.cui_timeline_editor_ex(self.h, self.tmpStr(id).ptr, @ptrCast(tracks.ptr), @intCast(tracks.len), @ptrCast(time), &opts_c));
}

pub fn kv_editor(self: *Ui, id: []const u8, pairs: *c.cui_kv_pair, count: *i32, capacity: i32, opts: KvEditorOpts) bool {
    const opts_c = self.cvtOpts(c.cui_kv_editor_opts, opts);
    return c.cui_kv_editor_ex(self.h, self.tmpStr(id).ptr, @ptrCast(pairs), @ptrCast(count), capacity, &opts_c);
}

pub fn problems(self: *Ui, id: []const u8, diags: []const Diagnostic, opts: ProblemsOpts) ProblemsResult {
    const zp2_c = self.structArr(c.cui_diagnostic, diags);
    const opts_c = self.cvtOpts(c.cui_problems_opts, opts);
    return cvtBackStruct(ProblemsResult, c.cui_problems_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(diags.len), &opts_c));
}

pub fn pipeline(self: *Ui, id: []const u8, stages: []const []const u8, jobs: []const PipelineJob, opts: PipelineOpts) PipelineResult {
    const zp2_c = self.strArr(stages);
    const zp4_c = self.structArr(c.cui_pipeline_job, jobs);
    const opts_c = self.cvtOpts(c.cui_pipeline_opts, opts);
    return cvtBackStruct(PipelineResult, c.cui_pipeline_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(stages.len), zp4_c, @intCast(jobs.len), &opts_c));
}

/// Read-only and disabled builders preserve the input rules and count.
pub fn query_builder(self: *Ui, id: []const u8, fields: []const QueryField, nodes: *c.cui_query_node, count: *i32, capacity: i32, opts: QueryOpts) bool {
    const zp2_c = self.structArr(c.cui_query_field, fields);
    const opts_c = self.cvtOpts(c.cui_query_opts, opts);
    return c.cui_query_builder_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(fields.len), @ptrCast(nodes), @ptrCast(count), capacity, &opts_c);
}

pub fn schedule_picker(self: *Ui, id: []const u8, cron: []u8, cap: usize, opts: ScheduleOpts) ScheduleResult {
    const opts_c = self.cvtOpts(c.cui_schedule_opts, opts);
    return cvtBackStruct(ScheduleResult, c.cui_schedule_picker_ex(self.h, self.tmpStr(id).ptr, cron.ptr, cap, &opts_c));
}

/// "Every weekday at 09:30", in frame memory; NULL when invalid.
pub fn cron_describe(self: *Ui, cron: []const u8) []const u8 {
    return spanOrEmpty(c.cui_cron_describe(self.h, self.tmpStr(cron).ptr));
}

pub fn keymap(self: *Ui, id: []const u8, bindings: []const KeymapBinding, opts: KeymapOpts) KeymapResult {
    const zp2_c = self.structArr(c.cui_keymap_binding, bindings);
    const opts_c = self.cvtOpts(c.cui_keymap_opts, opts);
    return cvtBackStruct(KeymapResult, c.cui_keymap_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(bindings.len), &opts_c));
}

pub fn commit_graph(self: *Ui, id: []const u8, commits: []const Commit, opts: CommitGraphOpts) CommitGraphResult {
    const zp2_c = self.structArr(c.cui_commit, commits);
    const opts_c = self.cvtOpts(c.cui_commit_graph_opts, opts);
    return cvtBackStruct(CommitGraphResult, c.cui_commit_graph_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(commits.len), &opts_c));
}

pub fn graph_view(self: *Ui, id: []const u8, nodes: []const GraphNode, edges: []const GraphEdge, opts: GraphOpts) GraphResult {
    const zp2_c = self.structArr(c.cui_graph_node, nodes);
    const zp4_c = self.structArr(c.cui_graph_edge, edges);
    const opts_c = self.cvtOpts(c.cui_graph_opts, opts);
    return cvtBackStruct(GraphResult, c.cui_graph_view_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(nodes.len), zp4_c, @intCast(edges.len), &opts_c));
}

pub fn waterfall(self: *Ui, id: []const u8, requests: []const NetRequest, opts: WaterfallOpts) WaterfallResult {
    const zp2_c = self.structArr(c.cui_net_request, requests);
    const opts_c = self.cvtOpts(c.cui_waterfall_opts, opts);
    return cvtBackStruct(WaterfallResult, c.cui_waterfall_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(requests.len), &opts_c));
}

pub fn trace_view(self: *Ui, id: []const u8, tracks: *c.cui_trace_track, track_count: i32, spans: []const TraceSpan, view: *c.cui_trace_view, selected: *i32, opts: TraceOpts) TraceResult {
    const zp4_c = self.structArr(c.cui_trace_span, spans);
    const opts_c = self.cvtOpts(c.cui_trace_opts, opts);
    return cvtBackStruct(TraceResult, c.cui_trace_view_ex(self.h, self.tmpStr(id).ptr, @ptrCast(tracks), track_count, zp4_c, @intCast(spans.len), @ptrCast(view), @ptrCast(selected), &opts_c));
}

pub fn regex_tester(self: *Ui, id: []const u8, pattern: []u8, pattern_cap: usize, s: []u8, text_cap: usize, opts: RegexTesterOpts) RegexTesterResult {
    const opts_c = self.cvtOpts(c.cui_regex_tester_opts, opts);
    return cvtBackStruct(RegexTesterResult, c.cui_regex_tester_ex(self.h, self.tmpStr(id).ptr, pattern.ptr, pattern_cap, s.ptr, text_cap, &opts_c));
}

pub fn test_explorer(self: *Ui, id: []const u8, items: []const TestItem, opts: TestExplorerOpts) TestExplorerResult {
    const zp2_c = self.structArr(c.cui_test_item, items);
    const opts_c = self.cvtOpts(c.cui_test_explorer_opts, opts);
    return cvtBackStruct(TestExplorerResult, c.cui_test_explorer_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(items.len), &opts_c));
}

pub fn stack_trace(self: *Ui, id: []const u8, frames: []const StackFrame, opts: StackTraceOpts) StackTraceResult {
    const zp2_c = self.structArr(c.cui_stack_frame, frames);
    const opts_c = self.cvtOpts(c.cui_stack_trace_opts, opts);
    return cvtBackStruct(StackTraceResult, c.cui_stack_trace_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(frames.len), &opts_c));
}

pub fn request_bar(self: *Ui, id: []const u8, method: *i32, url: []u8, cap: usize, opts: RequestBarOpts) RequestBarResult {
    const opts_c = self.cvtOpts(c.cui_request_bar_opts, opts);
    return cvtBackStruct(RequestBarResult, c.cui_request_bar_ex(self.h, self.tmpStr(id).ptr, @ptrCast(method), url.ptr, cap, &opts_c));
}

pub fn response_status(self: *Ui, status: i32, seconds: f64, bytes: f64) void {
    c.cui_response_status(self.h, status, seconds, bytes);
}

pub fn uptime(self: *Ui, id: []const u8, services: []const UptimeService, opts: UptimeOpts) UptimeResult {
    const zp2_c = self.structArr(c.cui_uptime_service, services);
    const opts_c = self.cvtOpts(c.cui_uptime_opts, opts);
    return cvtBackStruct(UptimeResult, c.cui_uptime_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(services.len), &opts_c));
}

pub fn time_histogram(self: *Ui, id: []const u8, start: f64, bucket_seconds: f64, buckets: i32, series: []const c.cui_histogram_series, sel_start: *f64, sel_end: *f64, opts: TimeHistogramOpts) TimeHistogramResult {
    const opts_c = self.cvtOpts(c.cui_time_histogram_opts, opts);
    return cvtBackStruct(TimeHistogramResult, c.cui_time_histogram_ex(self.h, self.tmpStr(id).ptr, start, bucket_seconds, buckets, @ptrCast(series.ptr), @intCast(series.len), @ptrCast(sel_start), @ptrCast(sel_end), &opts_c));
}

pub fn coverage(self: *Ui, id: []const u8, files: []const CoverageFile, opts: CoverageOpts) CoverageResult {
    const zp2_c = self.structArr(c.cui_coverage_file, files);
    const opts_c = self.cvtOpts(c.cui_coverage_opts, opts);
    return cvtBackStruct(CoverageResult, c.cui_coverage_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(files.len), &opts_c));
}

pub fn blame(self: *Ui, id: []const u8, lines: []const []const u8, line_commit: []const i32, line_count: i32, commits: []const BlameCommit, opts: BlameOpts) BlameResult {
    const zp2_c = std.heap.page_allocator.alloc([*c]const u8, lines.len + 1) catch @panic("zui: oom");
    defer std.heap.page_allocator.free(zp2_c);
    for (lines, 0..) |it, ii| zp2_c[ii] = @ptrCast(self.tmpStr(it).ptr);
    zp2_c[lines.len] = null;
    const zp5_c = self.structArr(c.cui_blame_commit, commits);
    const opts_c = self.cvtOpts(c.cui_blame_opts, opts);
    return cvtBackStruct(BlameResult, c.cui_blame_ex(self.h, self.tmpStr(id).ptr, zp2_c.ptr, line_commit.ptr, line_count, zp5_c, @intCast(commits.len), &opts_c));
}

pub fn feature_flags(self: *Ui, id: []const u8, flags: []c.cui_feature_flag, envs: []const []const u8, opts: FeatureFlagsOpts) FeatureFlagsResult {
    const zp4_c = self.strArr(envs);
    const opts_c = self.cvtOpts(c.cui_feature_flags_opts, opts);
    return cvtBackStruct(FeatureFlagsResult, c.cui_feature_flags_ex(self.h, self.tmpStr(id).ptr, @ptrCast(flags.ptr), @intCast(flags.len), zp4_c, @intCast(envs.len), &opts_c));
}

pub fn api_explorer(self: *Ui, id: []const u8, endpoints: []const ApiEndpoint, opts: ApiExplorerOpts) ApiExplorerResult {
    const zp2_c = self.structArr(c.cui_api_endpoint, endpoints);
    const opts_c = self.cvtOpts(c.cui_api_explorer_opts, opts);
    return cvtBackStruct(ApiExplorerResult, c.cui_api_explorer_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(endpoints.len), &opts_c));
}

pub fn dot_chart(self: *Ui, id: []const u8, series: []const c.cui_dot_series, count: i32, opts: DotChartOpts) DotChartResult {
    const opts_c = self.cvtOpts(c.cui_dot_chart_opts, opts);
    return cvtBackStruct(DotChartResult, c.cui_dot_chart_ex(self.h, self.tmpStr(id).ptr, @ptrCast(series.ptr), @intCast(series.len), count, &opts_c));
}

pub fn event_track(self: *Ui, id: []const u8, times: *f64, count: *i32, capacity: i32, min: f64, max: f64, opts: EventTrackOpts) EventTrackResult {
    const opts_c = self.cvtOpts(c.cui_event_track_opts, opts);
    return cvtBackStruct(EventTrackResult, c.cui_event_track_ex(self.h, self.tmpStr(id).ptr, @ptrCast(times), @ptrCast(count), capacity, min, max, &opts_c));
}

pub fn readout(self: *Ui, label: []const u8, value: []const u8, opts: ReadoutOpts) void {
    const opts_c = self.cvtOpts(c.cui_readout_opts, opts);
    c.cui_readout_ex(self.h, self.tmpStr(label).ptr, self.tmpStr(value).ptr, &opts_c);
}

pub fn dot_display(self: *Ui, s: []const u8, opts: DotDisplayOpts) void {
    const opts_c = self.cvtOpts(c.cui_dot_display_opts, opts);
    c.cui_dot_display_ex(self.h, self.tmpStr(s).ptr, &opts_c);
}

/// Returns CUI_FORMAT_* flags.
pub fn format_bar(self: *Ui, id: []const u8, format: *c.cui_text_format, opts: FormatBarOpts) i32 {
    const opts_c = self.cvtOpts(c.cui_format_bar_opts, opts);
    return c.cui_format_bar_ex(self.h, self.tmpStr(id).ptr, @ptrCast(format), &opts_c);
}

pub fn live_cursors(self: *Ui, id: []const u8, users: []const LiveUser, opts: LiveCursorsOpts) void {
    const zp2_c = self.structArr(c.cui_live_user, users);
    const opts_c = self.cvtOpts(c.cui_live_cursors_opts, opts);
    c.cui_live_cursors_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(users.len), &opts_c);
}

pub fn presence_pill(self: *Ui, id: []const u8, users: []const LiveUser, opts: PresencePillOpts) void {
    const zp2_c = self.structArr(c.cui_live_user, users);
    const opts_c = self.cvtOpts(c.cui_presence_pill_opts, opts);
    c.cui_presence_pill_ex(self.h, self.tmpStr(id).ptr, zp2_c, @intCast(users.len), &opts_c);
}

pub fn selection_ring(self: *Ui, color: Color, opts: SelectionRingOpts) void {
    const opts_c = self.cvtOpts(c.cui_selection_ring_opts, opts);
    c.cui_selection_ring_ex(self.h, colorToC(color), &opts_c);
}

/// Returns CUI_CANVAS_* flags.
pub fn canvas_controls(self: *Ui, id: []const u8, view: *c.cui_node_view, opts: CanvasControlsOpts) i32 {
    const opts_c = self.cvtOpts(c.cui_canvas_controls_opts, opts);
    return c.cui_canvas_controls_ex(self.h, self.tmpStr(id).ptr, @ptrCast(view), &opts_c);
}

pub fn result_card(self: *Ui, id: []const u8, image: usize, title: []const u8, opts: ResultCardOpts) bool {
    const opts_c = self.cvtOpts(c.cui_result_card_opts, opts);
    return c.cui_result_card_ex(self.h, self.tmpStr(id).ptr, image, self.tmpStr(title).ptr, &opts_c);
}

/// Returns the action picked, CUI_SELECTION_CLEARED when the clear button or Esc
/// cleared the selection, or CUI_SELECTION_NONE.
pub fn selection_bar(self: *Ui, id: []const u8, count: i32, actions: []const SelectionAction, opts: SelectionBarOpts) i32 {
    const zp3_c = self.structArr(c.cui_selection_action, actions);
    const opts_c = self.cvtOpts(c.cui_selection_bar_opts, opts);
    return c.cui_selection_bar_ex(self.h, self.tmpStr(id).ptr, count, zp3_c, @intCast(actions.len), &opts_c);
}

pub fn draw_rect(self: *Ui, r: Rect, radius: Corners, fill: Color) void {
    const zp1_c = rectToC(r);
    const zp2_c = cvtFree(c.cui_corners, radius);
    c.cui_draw_rect(self.h, zp1_c, zp2_c, colorToC(fill));
}

pub fn draw_rect_border(self: *Ui, r: Rect, radius: Corners, fill: Color, border: Color, border_width: f32) void {
    const zp1_c = rectToC(r);
    const zp2_c = cvtFree(c.cui_corners, radius);
    c.cui_draw_rect_border(self.h, zp1_c, zp2_c, colorToC(fill), colorToC(border), border_width);
}

pub fn draw_rect_gradient(self: *Ui, r: Rect, radius: Corners, top: Color, bottom: Color) void {
    const zp1_c = rectToC(r);
    const zp2_c = cvtFree(c.cui_corners, radius);
    c.cui_draw_rect_gradient(self.h, zp1_c, zp2_c, colorToC(top), colorToC(bottom));
}

pub fn draw_shadow(self: *Ui, r: Rect, radius: Corners, blur: f32, spread: f32, offset: Vec2, color: Color) void {
    const zp1_c = rectToC(r);
    const zp2_c = cvtFree(c.cui_corners, radius);
    const zp5_c = vecToC(offset);
    c.cui_draw_shadow(self.h, zp1_c, zp2_c, blur, spread, zp5_c, colorToC(color));
}

pub fn draw_line(self: *Ui, a: Vec2, b: Vec2, thickness: f32, color: Color) void {
    const zp1_c = vecToC(a);
    const zp2_c = vecToC(b);
    c.cui_draw_line(self.h, zp1_c, zp2_c, thickness, colorToC(color));
}

pub fn draw_polyline(self: *Ui, points: []const Vec2, thickness: f32, color: Color, closed: bool) void {
    const zp1_c = self.arena.allocator().alloc(c.cui_vec2, points.len) catch @panic("zui: oom");
    for (points, 0..) |pt, vpi| zp1_c[vpi] = vecToC(pt);
    c.cui_draw_polyline(self.h, zp1_c.ptr, @intCast(points.len), thickness, colorToC(color), closed);
}

pub fn draw_polygon(self: *Ui, points: []const Vec2, color: Color) void {
    const zp1_c = self.arena.allocator().alloc(c.cui_vec2, points.len) catch @panic("zui: oom");
    for (points, 0..) |pt, vpi| zp1_c[vpi] = vecToC(pt);
    c.cui_draw_polygon(self.h, zp1_c.ptr, @intCast(points.len), colorToC(color));
}

pub fn draw_circle(self: *Ui, center: Vec2, radius: f32, color: Color) void {
    const zp1_c = vecToC(center);
    c.cui_draw_circle(self.h, zp1_c, radius, colorToC(color));
}

pub fn draw_arc(self: *Ui, center: Vec2, radius: f32, a0: f32, a1: f32, thickness: f32, color: Color) void {
    const zp1_c = vecToC(center);
    c.cui_draw_arc(self.h, zp1_c, radius, a0, a1, thickness, colorToC(color));
}

pub fn draw_text(self: *Ui, font: i32, size_arg: f32, pos: Vec2, color: Color, s: []const u8) void {
    const zp3_c = vecToC(pos);
    c.cui_draw_text(self.h, font, size_arg, zp3_c, colorToC(color), s.ptr, @intCast(s.len));
}

pub fn draw_icon(self: *Ui, icon_name: []const u8, r: Rect, size_arg: f32, color: Color) void {
    const zp2_c = rectToC(r);
    c.cui_draw_icon(self.h, self.tmpStr(icon_name).ptr, zp2_c, size_arg, colorToC(color));
}

pub fn draw_image(self: *Ui, tex: usize, r: Rect, uv: Rect, radius: Corners, tint: Color) void {
    const zp2_c = rectToC(r);
    const zp3_c = rectToC(uv);
    const zp4_c = cvtFree(c.cui_corners, radius);
    c.cui_draw_image(self.h, tex, zp2_c, zp3_c, zp4_c, colorToC(tint));
}

pub fn push_clip(self: *Ui, r: Rect) void {
    const zp1_c = rectToC(r);
    c.cui_push_clip(self.h, zp1_c);
}

pub fn pop_clip(self: *Ui) void {
    c.cui_pop_clip(self.h);
}

/// Request focus for a submitted canvas with component_input enabled. The last
/// request wins at end_frame and expires there. An absent, disabled, or
/// nonparticipating target leaves the current focus unchanged. Removal revokes
/// participating focus; built-in forward-focus behavior is unchanged.
pub fn request_component_focus(self: *Ui, id: u32) void {
    c.cui_request_component_focus(self.h, id);
}

/// Test eligibility from a completed submission: call after end_frame or before
/// submitting components in the next frame. Includes window, modal and popup
/// exclusion. Unsubmitted host visibility/disabled changes remain host-owned.
pub fn component_has_input(self: *Ui, id: u32) bool {
    return c.cui_component_has_input(self.h, id);
}

/// Current owner, including built-ins. Ownership alone does not imply eligibility.
pub fn focused_id(self: *Ui) u32 {
    return c.cui_focused_id(self.h);
}

pub fn window_focused(self: *Ui) bool {
    return c.cui_window_focused(self.h);
}

/// Whether `id` has keyboard focus with its ring showing; for a painter.
pub fn focus_visible(self: *Ui, id: u32) bool {
    return c.cui_focus_visible(self.h, id);
}

pub fn frame_strdup(self: *Ui, s: []const u8) []const u8 {
    return spanOrEmpty(c.cui_frame_strdup(self.h, self.tmpStr(s).ptr));
}

/// Marks the part of a canvas that takes the wheel, for a canvas that zooms,
/// pans or scrolls what it draws the way the built-in charts, graphs and
/// timelines do. Call it from the paint callback; over the rectangle the wheel
/// stops there instead of scrolling an enclosing scroll area or the page. Give
/// it an id of its own, not the canvas's: the region keeps scroll state under
/// that id. A canvas in a disabled scope marks nothing, so the wheel scrolls
/// the page there. Like every hit area, the region is the one painted on the
/// previous frame.
pub fn wheel_region(self: *Ui, id: u32, rect: Rect) void {
    const zp2_c = rectToC(rect);
    c.cui_wheel_region(self.h, id, zp2_c);
}

/// Returns the wheel aimed at a cui_wheel_region id this frame, in lines with
/// +y up as cui_input_scroll gives it, and consumes it, so call it once per
/// frame. Returns false and leaves *delta alone when no wheel came, and in a
/// disabled scope: call it in the scope the canvas was built in.
pub fn wheel_take(self: *Ui, id: u32, delta: *Vec2) bool {
    var zp2_c: c.cui_vec2 = std.mem.zeroes(c.cui_vec2);
    const result = c.cui_wheel_take(self.h, id, &zp2_c);
    delta.* = .{ .x = zp2_c.x, .y = zp2_c.y };
    return result;
}

/// Animation helpers. Values move toward target with a spring and request
/// frames while moving. Reduced motion makes them snap.
pub fn animate(self: *Ui, id: u32, target: f32) f32 {
    return c.cui_animate(self.h, id, target);
}

pub fn animate_spring(self: *Ui, id: u32, target: f32, duration: f32, bounce: f32) f32 {
    return c.cui_animate_spring(self.h, id, target, duration, bounce);
}
// ==== END GEN:METHODS ====

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
        const single_slice = comptime blk: {
            var n: usize = 0;
            for (info.field_types) |FT| {
                if (@typeInfo(FT) == .pointer and @typeInfo(FT).pointer.size == .slice) {
                    if (@typeInfo(FT).pointer.child != u8) n += 1;
                }
            }
            break :blk n == 1;
        };
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
            } else if (From == Vec2) {
                dst.* = vecToC(val);
            } else if (From == Rect) {
                dst.* = rectToC(val);
            } else if (@typeInfo(From) == .pointer and @typeInfo(From).pointer.size == .slice) {
                // pointer+count field pair folded into one slice
                const CF = @FieldType(C, f);
                const Elem = @typeInfo(CF).pointer.child;
                const has_suffixed = comptime @hasField(C, f ++ "_count");
                const use_count = comptime !has_suffixed and single_slice and @hasField(C, "count");
                if (Elem == [*c]const u8) {
                    @field(out, f) = @ptrCast(self.strArr(val));
                } else if (@typeInfo(Elem) == .@"struct") {
                    @field(out, f) = @ptrCast(self.structArr(Elem, val));
                } else {
                    @field(out, f) = @ptrCast(val.ptr);
                }
                if (has_suffixed) {
                    @field(out, f ++ "_count") = @intCast(val.len);
                } else if (use_count) {
                    @field(out, "count") = @intCast(val.len);
                }
            } else if (@typeInfo(From) == .optional and @typeInfo(To) == .pointer) {
                dst.* = if (val) |pv| @ptrCast(pv) else null;
            } else if (@typeInfo(From) == .@"enum") {
                dst.* = enumOrInt(To, val);
            } else if (@typeInfo(From) == .@"struct" and @typeInfo(From).@"struct".layout != .@"extern") {
                dst.* = self.cvtOpts(To, val);
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

fn rectToC(r: Rect) c.cui_rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

fn vecToC(v: Vec2) c.cui_vec2 {
    return .{ .x = v.x, .y = v.y };
}

fn colorFromC(cv: c.cui_color) Color {
    return .{ .r = cv.r, .g = cv.g, .b = cv.b, .a = cv.a };
}

fn vecFromC(cv: c.cui_vec2) Vec2 {
    return .{ .x = cv.x, .y = cv.y };
}

fn rectFromC(cv: c.cui_rect) Rect {
    return .{ .x = cv.x, .y = cv.y, .w = cv.w, .h = cv.h };
}

/// Reverse of `Size.toC` — for result structs CUI returns.
fn sizeFromC(v: c.cui_size) Size {
    const kind: i32 = enumToInt(v.kind);
    return switch (kind) {
        1 => if (v.value == 1) .fill else .{ .grow = v.value },
        2 => .{ .px = v.value },
        3 => .{ .pct = v.value },
        else => .fit,
    };
}

/// Any C string pointer shape -> slice ("" when null). Result strings point
/// into CUI's frame arena and stay valid until the next frame begins.
fn spanOrEmpty(p: anytype) []const u8 {
    if (p == null) return "";
    return std.mem.span(p);
}

fn enumToInt(v: anytype) i32 {
    return if (@typeInfo(@TypeOf(v)) == .@"enum") @intFromEnum(v) else @intCast(v);
}

/// Converts a friendly struct that has no string/slice fields into its C
/// counterpart (used by the free utility functions, which have no frame
/// arena). Structs needing strings take C-typed parameters instead.
fn cvtFree(comptime C: type, o: anytype) C {
    var out: C = std.mem.zeroes(C);
    const info = @typeInfo(@TypeOf(o)).@"struct";
    inline for (0..info.field_names.len) |i| {
        const f = info.field_names[i];
        const val = @field(o, f);
        const From = @TypeOf(val);
        const To = @TypeOf(@field(out, f));
        if (From == Size) {
            @field(out, f) = val.toC();
        } else if (From == Color or From == ?Color) {
            @field(out, f) = colorToC(val);
        } else if (From == Vec2) {
            @field(out, f) = vecToC(val);
        } else if (From == Rect) {
            @field(out, f) = rectToC(val);
        } else if (@typeInfo(From) == .@"enum") {
            @field(out, f) = enumOrInt(To, val);
        } else if (@typeInfo(From) == .@"struct") {
            @field(out, f) = cvtFree(To, val);
        } else {
            @field(out, f) = val;
        }
    }
    return out;
}

/// Converts a C struct returned by value into its friendly Zig mirror.
fn cvtBackStruct(comptime Z: type, cv: anytype) Z {
    var out: Z = undefined;
    const info = @typeInfo(Z).@"struct";
    inline for (0..info.field_names.len) |i| {
        const f = info.field_names[i];
        const To = info.field_types[i];
        const src = @field(cv, f);
        if (To == []const u8 or To == ?[]const u8) {
            @field(out, f) = spanOrEmpty(src);
        } else if (@typeInfo(To) == .@"enum") {
            @field(out, f) = @enumFromInt(enumToInt(src));
        } else if (To == Color) {
            @field(out, f) = .{ .r = src.r, .g = src.g, .b = src.b, .a = src.a };
        } else if (To == Size) {
            @field(out, f) = sizeFromC(src);
        } else if (To == Vec2) {
            @field(out, f) = .{ .x = src.x, .y = src.y };
        } else if (To == Rect) {
            @field(out, f) = .{ .x = src.x, .y = src.y, .w = src.w, .h = src.h };
        } else if (@typeInfo(To) == .@"struct") {
            @field(out, f) = cvtBackStruct(To, src);
        } else {
            @field(out, f) = src;
        }
    }
    return out;
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

/// C `cui_window_state`.
pub const WindowState = enum(c_int) { normal = 0, maximized, minimized };

/// C `cui_file_dialog_kind`.
pub const FileDialogKind = enum(c_int) { open = 0, save, folder };

/// C `cui_file_dialog_opts`.
pub const FileDialogOpts = struct {
    kind: FileDialogKind = .open,
    title: ?[]const u8 = null,
    filter_name: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    default_name: ?[]const u8 = null,
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

    /// The window's size in logical points.
    pub fn size(self: *App) Vec2 {
        const s = c.cui_app_size(self.handle);
        return .{ .x = s.x, .y = s.y };
    }

    pub fn maximize(self: *App) void {
        c.cui_app_maximize(self.handle);
    }

    pub fn restore(self: *App) void {
        c.cui_app_restore(self.handle);
    }

    pub fn minimize(self: *App) void {
        c.cui_app_minimize(self.handle);
    }

    /// Normal, maximized or minimized, as the system reports it now.
    pub fn windowState(self: *App) WindowState {
        return @enumFromInt(enumToInt(c.cui_app_window_state(self.handle)));
    }

    /// Native open/save dialog; blocking. On success writes the chosen path
    /// (UTF-8) into `out` and returns true.
    pub fn fileDialog(self: *App, opts: FileDialogOpts, out: []u8) bool {
        var cd: c.cui_file_dialog_opts = std.mem.zeroes(c.cui_file_dialog_opts);
        cd.kind = enumOrInt(@TypeOf(cd.kind), opts.kind);
        if (opts.title) |s| cd.title = self.ui_state.tmpStr(s).ptr;
        if (opts.filter_name) |s| cd.filter_name = self.ui_state.tmpStr(s).ptr;
        if (opts.filter) |s| cd.filter = self.ui_state.tmpStr(s).ptr;
        if (opts.default_name) |s| cd.default_name = self.ui_state.tmpStr(s).ptr;
        return c.cui_app_file_dialog(self.handle, &cd, out.ptr, out.len);
    }

    /// Renders the current UI into an RGBA buffer (any backend), for
    /// screenshots and tests.
    pub fn screenshot(self: *App, rgba: []u8, width: i32, height: i32) bool {
        return c.cui_app_screenshot(self.handle, rgba.ptr, width, height);
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
