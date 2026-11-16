#!/usr/bin/env python3
"""Generates the typed Zig surface of zui from the vendored CUI header.

Reads vendor/cui/include/cui/cui.h and splices generated code into the marker
regions of src/zui.zig:

    // ==== GEN:TYPES ... ====      enums, opts/item/result struct mirrors
    // ==== GEN:METHODS ... ====    Ui methods for every component function

Everything outside the markers is hand-written and preserved verbatim. Re-run
after updating vendor/cui:

    python3 tools/gen.py && zig build test
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HEADER = os.path.join(ROOT, "vendor/cui/include/cui/cui.h")
ZIG = os.path.join(ROOT, "src/zui.zig")

TYPES_MARK = "// ==== GEN:TYPES"
TYPES_END = "// ==== END GEN:TYPES ===="
METHODS_MARK = "// ==== GEN:METHODS"
METHODS_END = "// ==== END GEN:METHODS ===="

# ---------------------------------------------------------------- parsing --


def split_comment(line):
    m = re.search(r"/\*.*?\*/", line)
    if not m:
        return line, ""
    return line[: m.start()], line[m.start() + 2 : m.end() - 2].strip()


def collect_doc(lines, i):
    buf = []
    s = lines[i].strip()
    body = s[2:]
    while "*/" not in body and i + 1 < len(lines):
        buf.append(body)
        i += 1
        body = lines[i].strip()
    if "*/" in body:
        buf.append(body[: body.index("*/")])
    text = "\n".join(b.strip().lstrip("*").strip() for b in buf if b.strip())
    return text, i + 1


def split_top_commas(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def parse_field_line(code):
    code = code.strip().rstrip(";").strip()
    if not code or code == "int _":
        return []
    if "(" in code:
        return [("raw", code)]
    if "[" in code:
        return [("arr", code)]
    parts = split_top_commas(code)
    if len(parts) > 1:
        m = re.match(r"^(.*?)\s*(\**)\s*(\w+)$", parts[0])
        if not m:
            return [("raw", code)]
        base, stars, first = m.group(1), m.group(2), m.group(3)
        out = [(base + " " + stars, first)] if stars else [(base, first)]
        for p in parts[1:]:
            m2 = re.match(r"^(\**)\s*(\w+)$", p)
            if not m2:
                return [("raw", code)]
            st = m2.group(1) or ""
            out.append((base + " " + st, m2.group(2)))
        return out
    m = re.match(r"^(.*?[\*\s])(\w+)$", code)
    if not m:
        return [("raw", code)]
    return [(m.group(1).strip(), m.group(2))]


def normalize_comment(buf):
    text = "\n".join(buf)
    lines = [l.strip().lstrip("*").strip() for l in text.split("\n")]
    return "\n".join(l for l in lines if l)


def preprocess(lines):
    """Turns raw C lines into ('doc'|'code', text, comment) tokens. Block
    comments that start at a line's beginning become doc tokens (they
    document what follows); comments that start mid-line attach to that
    code line as its trailing comment."""
    out = []
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        i += 1
        if "/*" in line:
            start = line.index("/*")
            code_part = line[:start]
            endpos = line.find("*/", start)
            if endpos != -1:
                comment = line[start + 2 : endpos].strip()
                code = re.sub(r"//.*$", "", line[:start] + line[endpos + 2 :])
                if code.strip():
                    out.append(("code", code, comment))
                elif comment:
                    out.append(("doc", comment, ""))
                continue
            # comment continues on following lines
            buf = [line[start + 2 :]]
            rest = ""
            while i < n:
                l2 = lines[i]
                i += 1
                if "*/" in l2:
                    cut = l2.index("*/")
                    buf.append(l2[:cut])
                    rest = l2[cut + 2 :]
                    break
                buf.append(l2)
            comment = normalize_comment(buf)
            if code_part.strip():
                out.append(("code", code_part, comment))
            elif comment:
                out.append(("doc", comment, ""))
            if rest.strip():
                out.append(("code", re.sub(r"//.*$", "", rest), ""))
            continue
        code = re.sub(r"//.*$", "", line)
        if code.strip():
            out.append(("code", code, ""))
    return out


def parse_header(path):
    with open(path) as f:
        tokens = preprocess(f.read().split("\n"))

    structs, enums, funcs, macros = {}, {}, [], {}
    doc = []
    i, n = 0, len(tokens)
    while i < n:
        kind, s, tok_com = tokens[i]
        if kind == "doc":
            doc.append(s)
            i += 1
            continue
        s = s.strip()
        if s.startswith("#define cui_") and "(" in s:
            name = s[len("#define ") :].split("(", 1)[0]
            body = s.split("(", 1)[1]
            while body.count("(") > body.count(")") and i + 1 < n and tokens[i + 1][0] == "code":
                i += 1
                body += " " + tokens[i][1].strip().rstrip("\\")
            macros[name] = body
            doc = []
            i += 1
            continue
        m = re.match(r"typedef struct (cui_\w+)?\s*\{", s)
        if m:
            name = m.group(1)
            j = i
            if "}" not in s:
                while j + 1 < n and not tokens[j][1].strip().startswith("}"):
                    j += 1
            close = tokens[j][1].strip()
            cname_m = re.match(r"\}\s*(cui_\w+)", close)
            cname = cname_m.group(1) if cname_m else name
            if name is None:
                name = cname
            fields = []
            if "{" in s and "}" in s:
                inner = s[s.index("{") + 1 : s.rindex("}")]
                for piece in inner.split(";"):
                    code, com = split_comment(piece)
                    for ct, cn in parse_field_line(code):
                        fields.append((ct, cn, com))
            else:
                k = i + 1
                while k < j:
                    if tokens[k][0] == "code":
                        for ct, cn in parse_field_line(tokens[k][1]):
                            fields.append((ct, cn, tokens[k][2]))
                    k += 1
            if cname:
                structs[cname] = {"name": cname, "fields": fields, "doc": "\n".join(doc)}
            doc = []
            i = j + 1
            continue
        m = re.match(r"typedef enum (cui_\w+)?\s*\{", s)
        if m:
            j = i
            if "}" not in s:
                while j + 1 < n and not tokens[j][1].strip().startswith("}"):
                    j += 1
            close = tokens[j][1].strip()
            cname_m = re.match(r"\}\s*(cui_\w+)", close)
            cname = cname_m.group(1) if cname_m else m.group(1)
            vals = []
            auto = 0

            def add_val(code, com):
                nonlocal auto
                code = code.strip().rstrip(";,").strip()
                if not code:
                    return
                if "=" in code:
                    vn, vx = code.split("=", 1)
                    vn = vn.strip().rstrip(",").strip()
                    vx = vx.strip().rstrip(",").strip()
                    try:
                        auto = int(vx, 0)
                    except ValueError:
                        return
                else:
                    vn = code
                vals.append((vn, auto, com))
                auto += 1

            if "{" in s and "}" in s:
                inner = s[s.index("{") + 1 : s.rindex("}")]
                for piece in split_top_commas(inner):
                    code, com = split_comment(piece)
                    add_val(code, com)
            else:
                k = i + 1
                while k < j:
                    if tokens[k][0] == "code":
                        pieces = split_top_commas(tokens[k][1])
                        for pi, piece in enumerate(pieces):
                            add_val(piece, tokens[k][2] if pi == 0 else "")
                    k += 1
            if cname:
                enums[cname] = {"values": vals, "doc": "\n".join(doc)}
            doc = []
            i = j + 1
            continue
        if s.startswith("CUI_API"):
            decl = s
            j = i
            while not re.search(r"\)\s*;", decl) and j + 1 < n and tokens[j + 1][0] == "code":
                j += 1
                decl += " " + tokens[j][1].strip()
            decl = re.sub(r"CUI_PRINTF\([^)]*\)", "", decl).strip()
            code, tail_com = split_comment(decl)
            m2 = re.match(r"CUI_API\s+(.+?)\s*\bcui_(\w+)\s*\((.*)\)\s*;\s*$", code, re.S)
            if m2:
                funcs.append(
                    {
                        "ret": m2.group(1).strip(),
                        "name": "cui_" + m2.group(2),
                        "params": [p for p in split_top_commas(m2.group(3)) if p],
                        "doc": "\n".join(doc) + ("\n" + tail_com if tail_com else ""),
                    }
                )
            doc = []
            i = j + 1
            continue
        doc = []
        i += 1
    return structs, enums, funcs, macros


# ------------------------------------------------------- hand-written maps --

HAND_ENUMS = {
    "cui_dir": "Dir",
    "cui_align": "Align",
    "cui_justify": "Justify",
    "cui_elevation": "Elevation",
    "cui_direction": "Direction",
    "cui_text_align": "TextAlign",
    "cui_button_variant": "ButtonVariant",
    "cui_control_size": "ControlSize",
    "cui_renderer_kind": "RendererKind",
    "cui_theme_mode": "ThemeMode",
    "cui_accent": "Accent",
    "cui_mouse_button": "MouseButton",
    "cui_size_kind": "SizeKind",
}

HAND_ENUM_DEFAULT = {
    "Dir": ".column",
    "Align": ".default",
    "Justify": ".start",
    "Elevation": ".none",
    "Direction": ".inherit",
    "TextAlign": ".start",
    "ButtonVariant": ".default",
    "ControlSize": ".md",
    "RendererKind": ".auto",
    "ThemeMode": ".light",
    "Accent": ".neutral",
    "MouseButton": ".left",
    "SizeKind": ".fit",
}

HAND_STRUCTS = {
    "cui_size": "Size",
    "cui_color": "Color",
    "cui_rect": "Rect",
    "cui_vec2": "Vec2",
}

SKIP_STRUCTS = {
    "cui_ctx",
    "cui_ctx_desc",
    "cui_app",
    "cui_app_desc",
    "cui_window_placement",
    "cui_renderer_iface",
    "cui_draw_data",
    "cui_draw_cmd",
    "cui_vertex",
    "cui_allocator",
    "cui_sw_renderer",
    "cui_gl_renderer",
    "cui_file_entry",
}

SKIP_FUNCS = {
    "cui_create", "cui_destroy", "cui_set_renderer", "cui_set_viewport",
    "cui_begin_frame", "cui_end_frame", "cui_needs_redraw", "cui_next_wakeup",
    "cui_request_redraw", "cui_request_wakeup", "cui_time", "cui_delta_time",
    "cui_frame_count", "cui_input_mouse_move", "cui_input_mouse_button",
    "cui_input_mouse_leave", "cui_input_scroll", "cui_input_key",
    "cui_input_text", "cui_input_focus", "cui_input_file_hover",
    "cui_input_file_drop", "cui_dropped_file_count", "cui_box_begin",
    "cui_box_end", "cui_row_begin", "cui_column_begin", "cui_card_begin",
    "cui_card_end", "cui_scroll_begin", "cui_scroll_end", "cui_split_begin",
    "cui_split_next", "cui_split_end", "cui_push_id", "cui_push_id_int",
    "cui_pop_id", "cui_push_disabled", "cui_pop_disabled", "cui_is_disabled",
    "cui_text_ex", "cui_textf", "cui_heading", "cui_secondary", "cui_muted",
    "cui_code", "cui_kbd", "cui_link", "cui_icon", "cui_spacer", "cui_gap",
    "cui_separator", "cui_button_ex", "cui_icon_button_ex", "cui_checkbox_ex",
    "cui_switch_ex", "cui_radio_ex", "cui_slider_ex", "cui_number_ex",
    "cui_input_ex", "cui_textarea_ex", "cui_search_ex", "cui_last_id",
    "cui_last_rect", "cui_get_rect", "cui_last_hovered", "cui_make_id",
    "cui_scroll_to", "cui_state", "cui_state_on_free", "cui_table_cell_textf",
}

COUNT_NAMES = {
    "count", "n", "ncols", "nseries", "nn", "nl", "na", "ncommits", "nenvs",
    "node_count", "field_count", "column_count", "series_count", "stage_count",
    "span_count", "left_count", "right_count", "link_count", "job_count",
    "env_count", "edge_count", "commit_count", "axis_count", "action_count",
    "channels", "rows", "cols", "size", "nitems", "nfields",
}

ZIG_KEYWORDS = {
    "align", "and", "anytype", "as", "break", "catch", "comptime", "const",
    "continue", "defer", "else", "enum", "errdefer", "error", "export",
    "extern", "fn", "for", "if", "inline", "noalias", "or", "orelse",
    "packed", "pub", "resume", "return", "linksection", "struct", "suspend",
    "switch", "test", "threadlocal", "try", "union", "unreachable",
    "usingnamespace", "var", "volatile", "while",
}

SCALARS = {
    "float": "f32",
    "double": "f64",
    "int": "i32",
    "unsigned": "u32",
    "unsigned int": "u32",
    "uint32_t": "u32",
    "uint64_t": "u64",
    "size_t": "usize",
    "uintptr_t": "usize",
    "bool": "bool",
    "char": "u8",
    "cui_id": "u32",
    "cui_texture": "usize",
    "cui_font": "i32",
}

# filled at run time
enums_cache = {}
structs_cache = {}
enum_first_tag = {}


def zig_tag(raw, prefix):
    t = raw
    if t.startswith(prefix):
        t = t[len(prefix) :]
    t = t.lower()
    if not t or t[0].isdigit() or t in ZIG_KEYWORDS:
        t = "@\"" + t + "\""
    return t


def camel(cname):
    return "".join(p.capitalize() for p in cname[4:].split("_"))


def method_name(f, sc):
    n = f["name"][4:]
    if sc is not None:
        n = re.sub(r"_begin(_ex)?$", "", n)
    if n.endswith("_ex"):
        n = n[:-3]
    return RENAMES.get(n, n)


def zig_ident(name):
    if name in ZIG_KEYWORDS:
        return '@"' + name + '"'
    return name


def base_of(ctype):
    """'const cui_x *' -> ('cui_x', is_const, stars); const may appear anywhere."""
    stars = ctype.count("*")
    base = ctype.replace("*", " ").strip()
    is_const = bool(re.search(r"\bconst\b", base))
    base = re.sub(r"\bconst\b", "", base).strip()
    return base, is_const, stars


def enum_default(zname):
    d = enum_first_tag.get(zname) or HAND_ENUM_DEFAULT.get(zname, ".default")
    return d if d.startswith(".") else "." + d


def gen_enum(cname, e):
    vals = e["values"]
    prefix = "CUI_"
    if len(vals) > 1:
        common = os.path.commonprefix([v[0] for v in vals])
        if len(common) > 4 and "_" in common[:-1]:
            prefix = common[: common.rindex("_") + 1]
    tags = {}
    seen = set()
    for name, value, com in vals:
        tag = zig_tag(name, prefix)
        if tag in seen:
            tag = zig_tag(name, "CUI_")
        seen.add(tag)
        tags[name] = (tag, value)
    out = []
    if e["doc"]:
        out.append("/// " + e["doc"].replace("\n", "\n/// "))
    out.append(f"pub const {camel(cname)} = enum(c_int) {{")
    for name, value, com in vals:
        tag, _ = tags[name]
        line = f"    {tag} = {value},"
        if com:
            line += "  // " + one_line(com)
        out.append(line)
    out.append("};\n")
    if tags:
        enum_first_tag[camel(cname)] = list(tags.values())[0][0]
    return "\n".join(out)


def field_slices(s):
    """Pairs pointer fields with their count field inside a struct.
    Returns {pointer_field_name: (elem_type, count_field_name)} and the set
    of count fields consumed."""
    pairs = {}
    consumed = set()
    fields = s["fields"]
    for idx, (ct, fn_, com) in enumerate(fields):
        if ct == "raw":
            continue
        base, is_const, stars = base_of(ct)
        if stars != 1 or not is_const:
            continue
        if base == "char":
            continue  # plain strings are not arrays
        # find a count field after this one
        cnt = None
        candidates = [fn_ + "_count"]
        if fn_.endswith("s"):
            candidates.append(fn_[:-1] + "_count")
        for ct2, fn2, _ in fields[idx + 1 :]:
            if fn2 in candidates or (fn2 in COUNT_NAMES and fn2 not in consumed):
                cnt = fn2
                break
        if cnt:
            pairs[fn_] = (base, cnt)
            consumed.add(cnt)
    return pairs, consumed


def one_line(com):
    return re.sub(r"\s+", " ", com).strip()


def gen_struct(sname, s):
    pairs, consumed = field_slices(s)
    out = []
    if s["doc"]:
        out.append("/// C `%s` — %s" % (sname, s["doc"].replace("\n", "\n/// ")))
    out.append(f"pub const {camel(sname)} = struct {{")
    for ct, fn_, com in s["fields"]:
        if ct == "raw":
            out.append(f"    // `{fn_}`: function-pointer field, set via zui.raw if needed")
            continue
        if fn_ in consumed:
            continue  # count field folded into its slice
        base, is_const, stars = base_of(ct)
        fz = zig_ident(fn_)
        if stars == 1 and is_const and base == "char":
            line = f"    {fz}: ?[]const u8 = null,"
            if com:
                line += "  // " + one_line(com)
            out.append(line)
            continue
        if stars == 1 and fn_ in pairs:
            elem, cnt = pairs[fn_]
            zt = slice_zig_type(elem)
            if zt is None:
                out.append(f"    // `{fn_}` ({ct}): unsupported array element, reach it via zui.raw")
                continue
            line = f"    {fz}: {zt} = &.{{}},"
            if com:
                line += "  // " + one_line(com)
            out.append(line)
            continue
        if stars == 1 and not is_const and base in structs_cache and base not in SKIP_STRUCTS and base not in HAND_STRUCTS:
            line = f"    {fz}: ?*c.{base} = null,"
            if com:
                line += "  // " + one_line(com)
            out.append(line)
            continue
        if stars >= 1:
            out.append(f"    // `{fn_}` ({ct}): pointer field, reach it via zui.raw")
            continue
        r = value_field_zig(base)
        if r is None:
            out.append(f"    // `{fn_}` ({ct}): unsupported field type, reach it via zui.raw")
            continue
        zt, dflt = r
        line = f"    {fz}: {zt} = {dflt},"
        if com:
            line += "  // " + one_line(com)
        out.append(line)
    out.append("};\n")
    return "\n".join(out)


def value_field_zig(base):
    """Zig (type, default) for a non-pointer struct field."""
    if base in HAND_STRUCTS:
        zt = HAND_STRUCTS[base]
        if zt == "Size":
            return ("Size", ".fit")
        if zt == "Color":
            return ("?Color", "null")
        return (zt, ".{}")
    if base in HAND_ENUMS:
        zt = HAND_ENUMS[base]
        return (zt, enum_default(zt))
    if base in SCALARS:
        zt = SCALARS[base]
        return (zt, "false" if zt == "bool" else "0")
    if base in enums_cache:
        zt = camel(base)
        return (zt, enum_default(zt))
    if base in structs_cache and base not in SKIP_STRUCTS:
        return (camel(base), ".{}")
    return None


def slice_zig_type(elem):
    if elem == "float":
        return "[]const f32"
    if elem == "double":
        return "[]const f64"
    if elem in ("uint32_t", "unsigned", "unsigned int"):
        return "[]const u32"
    if elem == "int":
        return "[]const i32"
    if elem == "char":
        return "[]const []const u8"
    if elem in enums_cache:
        return "[]const " + camel(elem)
    if elem in structs_cache and elem not in SKIP_STRUCTS:
        return "[]const " + camel(elem)
    return None


def parse_param(p):
    p = p.strip()
    if "(" in p:
        return ("fnptr", "", "")
    m = re.match(r"^(.*?)(\w+)$", p)
    if not m:
        return ("fnptr", "", "")
    ttype, name = m.group(1).strip(), m.group(2)
    stars = ttype.count("*")
    base, is_const, _ = base_of(ttype)
    if base == "cui_ctx" and stars == 1:
        return ("ctx", base, name)
    if base == "char" and stars == 1:
        return ("cstr" if is_const else "buf", base, name)
    if base == "char" and stars == 2 and is_const:
        return ("strarr", base, name)
    if base == "void" and stars == 1:
        return ("dataptr" if is_const else "voidptr", base, name)
    if base == "float" and stars == 1:
        return ("f32arr" if is_const else "floatout", base, name)
    if base == "double" and stars == 1:
        return ("f64arr" if is_const else "doubleout", base, name)
    if base == "int" and stars == 1:
        return ("i32arr" if is_const else "intout", base, name)
    if base in ("uint32_t", "unsigned", "unsigned int") and stars == 1 and is_const:
        return ("u32arr", base, name)
    if stars == 1:
        if base in HAND_STRUCTS:
            if base == "cui_vec2":
                return ("vec2arr" if is_const else "vec2out", base, name)
            return ("skip", base, name)
        if base in enums_cache:
            return ("skip", base, name)
        if base in structs_cache:
            return ("mutstruct" if not is_const else "cstructptr", base, name)
        if base in SCALARS:
            return (base + "out", base, name)
        return ("skip", base, name)
    if stars == 0:
        if base in HAND_ENUMS or base in enums_cache:
            return ("enum", base, name)
        if base == "cui_size":
            return ("size", base, name)
        if base == "cui_color":
            return ("color", base, name)
        if base == "cui_rect":
            return ("rect", base, name)
        if base == "cui_vec2":
            return ("vec2", base, name)
        if base in SCALARS:
            return ("scalar", base, name)
        if base in structs_cache and base not in SKIP_STRUCTS:
            return ("structin", base, name)
    return ("skip", base, name)


def pair_params(params):
    parsed = [parse_param(p) for p in params]
    out = []
    i = 0
    while i < len(parsed):
        kind, base, name = parsed[i]
        nxt = parsed[i + 1] if i + 1 < len(parsed) else None
        if (
            kind
            in ("strarr", "f32arr", "f64arr", "u32arr", "i32arr", "dataptr", "cstructptr", "vec2arr")
            and nxt
            and nxt[0] == "scalar"
        ):
            candidates = [name + "_count"]
            if name.endswith("s"):
                candidates.append(name[:-1] + "_count")
            if nxt[2] in candidates or nxt[2] in COUNT_NAMES:
                arrkind = "structarr" if kind == "cstructptr" else kind
                out.append((arrkind, base, name, nxt))
                i += 2
                continue
        if kind == "cstructptr":
            out.append(("structin", base, name, None))
            i += 1
            continue
        out.append((kind, base, name, None))
        i += 1
    return out


def struct_kind(sname):
    if sname in HAND_STRUCTS:
        return HAND_STRUCTS[sname]
    if sname in SKIP_STRUCTS or sname not in structs_cache:
        return None
    return camel(sname)


all_func_names = set()


def scope_info(cname, macros, funcs_by_name):
    """Returns None or {'if': bool, 'end': str}. Prefers the combined scope
    macro (cui_table) over a begin shim (cui_table_begin)."""
    candidates = [cname]
    if cname.endswith("_begin_ex"):
        candidates.append(cname[: -len("_begin_ex")])
        candidates.append(cname[: -len("_ex")])
    elif cname.endswith("_begin"):
        candidates.append(cname[: -len("_begin")])
    for cand in candidates:
        mac = macros.get(cand)
        if mac is None:
            continue
        mb = re.search(r"cui_(\w+?_begin(?:_ex)?)\s*\(", mac)
        me = re.search(r",\s*cui_(\w+_end)\s*\(", mac)
        if mb and me and ("cui_" + mb.group(1)) == cname:
            return {"if": "CUI__SCOPE_IF" in mac, "end": me.group(1)}
    if cname.endswith("_begin") or cname.endswith("_begin_ex"):
        b = re.sub(r"_begin(_ex)?$", "", cname)
        if b + "_end" in funcs_by_name:
            return {"if": False, "end": b + "_end"}
    return None


PARAM_RENAMES = {
    "text": "s",
    "state": "st",
    "c": "color",
    "icon": "icon_name",
}

RENAMES = {
    # method name would collide with a parameter name used by other methods
    "label": "label_text",
    "image": "image_view",
    "progress": "progress_bar",
}


def gen_function(f, macros, reserved):
    cname = f["name"]
    base = cname[4:]
    if base.endswith("_ex"):
        base = base[:-3]
    paired = pair_params(f["params"])
    kinds = [p[0] for p in paired]
    if "fnptr" in kinds or "skip" in kinds:
        return None

    opts_param = None
    if paired and paired[-1][0] == "structin" and paired[-1][1].endswith("_opts"):
        opts_param = paired[-1]
        paired = paired[:-1]
    if opts_param and struct_kind(opts_param[1]) is None:
        return None

    sc = scope_info(cname, macros, all_func_names)
    is_scope = sc is not None
    zname = method_name(f, sc)

    args = []
    sig = []
    pre = []
    post = []
    for kind, cbase, pname0, cnt in paired:
        if kind == "ctx":
            continue
        pname = zig_ident(pname0)
        if pname in reserved:
            pname = zig_ident(PARAM_RENAMES.get(pname0, pname0 + "_arg"))
        if kind == "cstr":
            sig.append(f"{pname}: []const u8")
            args.append(f"self.tmpStr({pname}).ptr")
        elif kind == "buf":
            sig.append(f"{pname}: []u8")
            args.append(f"{pname}.ptr")
            args.append(f"{pname}.len")
        elif kind == "strarr":
            sig.append(f"{pname}: []const []const u8")
            pre.append(f"const {pname}_c = self.strArr({pname});")
            args.append(f"{pname}_c")
            args.append(f"@intCast({pname}.len)")
        elif kind == "f32arr":
            sig.append(f"{pname}: []const f32")
            args.append(f"{pname}.ptr")
            args.append(f"@intCast({pname}.len)")
        elif kind == "f64arr":
            sig.append(f"{pname}: []const f64")
            args.append(f"{pname}.ptr")
            args.append(f"@intCast({pname}.len)")
        elif kind == "u32arr":
            sig.append(f"{pname}: []const u32")
            args.append(f"{pname}.ptr")
            args.append(f"@intCast({pname}.len)")
        elif kind == "i32arr":
            sig.append(f"{pname}: []const i32")
            args.append(f"{pname}.ptr")
            args.append(f"@intCast({pname}.len)")
        elif kind == "vec2arr":
            sig.append(f"{pname}: []const Vec2")
            pre.append(f"const {pname}_c = self.arena.allocator().alloc(c.cui_vec2, {pname}.len) catch @panic(\"zui: oom\");")
            pre.append(f"for ({pname}, 0..) |pt, pi| {pname}_c[pi] = vecToC(pt);")
            args.append(f"{pname}_c.ptr")
            args.append(f"@intCast({pname}.len)")
        elif kind == "dataptr":
            sig.append(f"{pname}: []const u8")
            args.append(f"{pname}.ptr")
            args.append(f"{pname}.len")
        elif kind == "structarr":
            zt = struct_kind(cbase)
            if zt is None:
                return None
            sig.append(f"{pname}: []const {zt}")
            pre.append(f"const {pname}_c = self.structArr(c.{cbase}, {pname});")
            args.append(f"{pname}_c")
            args.append(f"@intCast({pname}.len)")
        elif kind == "mutstruct":
            sig.append(f"{pname}: *c.{cbase}")
            args.append(f"@ptrCast({pname})")
        elif kind == "structin":
            zt = struct_kind(cbase)
            if zt is None:
                return None
            sig.append(f"{pname}: {zt}")
            pre.append(f"const {pname}_c = self.cvtOpts(c.{cbase}, {pname});")
            args.append(f"&{pname}_c")
        elif kind == "floatout":
            sig.append(f"{pname}: *f32")
            args.append(f"@ptrCast({pname})")
        elif kind == "doubleout":
            sig.append(f"{pname}: *f64")
            args.append(f"@ptrCast({pname})")
        elif kind == "intout":
            sig.append(f"{pname}: *i32")
            args.append(f"@ptrCast({pname})")
        elif kind == "boolout":
            sig.append(f"{pname}: *bool")
            args.append(f"{pname}")
        elif kind == "vec2out":
            sig.append(f"{pname}: *Vec2")
            pre.append(f"var {pname}_c: c.cui_vec2 = std.mem.zeroes(c.cui_vec2);")
            args.append(f"&{pname}_c")
            post.append(f"{pname}.* = .{{ .x = {pname}_c.x, .y = {pname}_c.y }};")
        elif kind == "voidptr":
            sig.append(f"{pname}: ?*anyopaque")
            args.append(f"{pname}")
        elif kind == "enum":
            zt = HAND_ENUMS.get(cbase) or camel(cbase)
            sig.append(f"{pname}: {zt}")
            args.append(f"enumOrInt(c.{cbase}, {pname})")
        elif kind == "size":
            sig.append(f"{pname}: Size")
            pre.append(f"const {pname}_c = {pname}.toC();")
            args.append(f"&{pname}_c")
        elif kind == "color":
            sig.append(f"{pname}: Color")
            args.append(f"colorToC({pname})")
        elif kind == "rect":
            sig.append(f"{pname}: Rect")
            pre.append(f"const {pname}_c = rectToC({pname});")
            args.append(f"&{pname}_c")
        elif kind == "vec2":
            sig.append(f"{pname}: Vec2")
            pre.append(f"const {pname}_c = vecToC({pname});")
            args.append(f"&{pname}_c")
        elif kind == "scalar":
            zt = SCALARS.get(cbase, "i32")
            sig.append(f"{pname}: {zt}")
            args.append(pname)

    if opts_param:
        optstype = struct_kind(opts_param[1])
        sig.append(f"opts: {optstype}")
        pre.append(f"const opts_c = self.cvtOpts(c.{opts_param[1]}, opts);")
        args.append("&opts_c")

    ret = f["ret"].strip()
    rbase, ris_const, rstars = base_of(ret)
    zret = "void"
    ret_wrap = None  # function applied around the call expression
    if rstars == 1 and rbase == "char":
        zret = "[]const u8"
        ret_wrap = "spanOrEmpty"
    elif rstars == 0:
        if rbase == "void":
            zret = "void"
        elif rbase == "bool":
            zret = "bool"
        elif rbase in SCALARS and rstars == 0:
            zret = SCALARS[rbase]
        elif rbase == "cui_color":
            zret = "Color"
            ret_wrap = "colorFromC"
        elif rbase == "cui_vec2":
            zret = "Vec2"
            ret_wrap = "vecFromC"
        elif rbase == "cui_rect":
            zret = "Rect"
            ret_wrap = "rectFromC"
        elif rbase in structs_cache and rbase not in SKIP_STRUCTS and not ris_const:
            zret = struct_kind(rbase)
            ret_wrap = "STRUCT:" + rbase
        elif rbase in HAND_ENUMS or rbase in enums_cache:
            zret = HAND_ENUMS.get(rbase) or camel(rbase)
            ret_wrap = "ENUMFROMINT"
        else:
            return None
    else:
        return None

    if is_scope:
        zret = "bool" if sc["if"] else "void"
        ret_wrap = None

    body = []
    if f["doc"]:
        body.append("/// " + f["doc"].replace("\n", "\n/// "))
    sig_s = (", ".join(sig)) if sig else ""
    body.append(f"pub fn {zname}(self: *Ui{', ' if sig else ''}{sig_s}) {zret} {{")
    for line in pre:
        body.append("    " + line)
    call = "c.%s(self.h%s)" % (cname, (", " + ", ".join(args)) if args else "")
    if is_scope:
        if sc["if"]:
            body.append(f"    if (!({call})) return false;")
            body.append(f"    self.pushEnd(c.cui_{sc['end']});")
            body.append("    return true;")
        else:
            body.append(f"    self.pushEnd(c.cui_{sc['end']});")
            body.append((f"{call};") if rbase == "void" else f"_ = {call};")
    elif ret_wrap is None:
        if zret == "void":
            body.append(f"    {call};")
        elif post:
            body.append(f"    const result = {call};")
            for line in post:
                body.append("    " + line)
            body.append("    return result;")
        else:
            body.append(f"    return {call};")
    elif isinstance(ret_wrap, str) and ret_wrap.startswith("STRUCT:"):
        sname = ret_wrap[len("STRUCT:") :]
        body.append(f"    return cvtBackStruct({struct_kind(sname)}, {call});")
    elif ret_wrap == "ENUMFROMINT":
        body.append(f"    return @enumFromInt(enumToInt({call}));")
    else:
        body.append(f"    return {ret_wrap}({call});")
    body.append("}")
    return "\n".join(body) + "\n"


def main():
    global enums_cache, structs_cache, all_func_names
    structs, enums, funcs, macros = parse_header(HEADER)
    enums_cache = enums
    structs_cache = structs
    all_func_names = {f["name"] for f in funcs}

    type_lines = []
    for cname in sorted(enums):
        if cname in HAND_ENUMS:
            continue
        type_lines.append(gen_enum(cname, enums[cname]))

    # structs referenced by generated functions (transitive over fields)
    used = set()

    def mark_struct(sname):
        if (
            sname in used
            or sname in SKIP_STRUCTS
            or sname in HAND_STRUCTS
            or sname not in structs
        ):
            return
        used.add(sname)
        for ct, fn_, com in structs[sname]["fields"]:
            if ct == "raw":
                continue
            base, is_const, stars = base_of(ct)
            if base in structs and base not in SKIP_STRUCTS and base not in HAND_STRUCTS:
                mark_struct(base)
            if stars == 1:
                pairs, _ = field_slices(structs[sname])
                if fn_ in pairs:
                    elem = pairs[fn_][0]
                    if elem in structs and elem not in SKIP_STRUCTS and elem not in HAND_STRUCTS:
                        mark_struct(elem)

    for f in funcs:
        if f["name"] in SKIP_FUNCS:
            continue
        if not f["params"] or "cui_ctx" not in f["params"][0]:
            continue
        if "..." in " ".join(f["params"]):
            continue
        for p in f["params"][1:]:
            base, is_const, stars = base_of(p.strip().rsplit(None, 1)[0] if " " in p.strip() else p.strip())
            # pointer params: base is type without name; by-value: strip name
            pp = p.strip()
            mm = re.match(r"^(.*?)(\**)?\s*(\w+)$", pp)
            if mm:
                b2, is_c2, st2 = base_of(mm.group(1) + (mm.group(2) or ""))
                if st2 == 1 and is_c2 and b2 in structs:
                    mark_struct(b2)
                elif st2 == 0 and b2 in structs:
                    mark_struct(b2)
        rb, rc, rs = base_of(f["ret"])
        if rs == 0 and rb in structs:
            mark_struct(rb)

    for sname in sorted(used):
        type_lines.append(gen_struct(sname, structs[sname]))

    # hand-written method names, so generated params never shadow them
    hand_names = set(re.findall(r"    pub fn (\w+)\(", open(ZIG).read()))

    def eligible(f):
        return (
            f["name"] not in SKIP_FUNCS
            and f["params"]
            and "cui_ctx" in f["params"][0]
            and "..." not in " ".join(f["params"])
        )

    consumed_ends = set()
    method_names = set()
    for f in funcs:
        if not eligible(f):
            continue
        sc = scope_info(f["name"], macros, {x["name"] for x in funcs})
        if sc:
            consumed_ends.add("cui_" + sc["end"])
        method_names.add(method_name(f, sc))
    reserved = hand_names | method_names | {"opts", "self", "end", "c", "std", "raw", "icon", "zui"}

    method_lines = []
    emitted = set()
    n_skipped = 0
    for f in funcs:
        if not eligible(f):
            continue
        if f["name"] in consumed_ends:
            n_skipped += 1
            continue
        code = gen_function(f, macros, reserved)
        if code is None:
            n_skipped += 1
            continue
        sc = scope_info(f["name"], macros, all_func_names)
        name = method_name(f, sc)
        if name in emitted:
            continue
        emitted.add(name)
        method_lines.append(code)

    types_code = (
        "// Generated enums and struct mirrors. Field names match the C structs;\n"
        "// defaults match C's zero-init semantics. Pointer+count field pairs are\n"
        "// folded into one slice field.\n\n"
        + "\n".join(type_lines)
    )
    methods_code = (
        "// Generated component methods. C cui_foo_ex -> foo; begin/end pairs\n"
        "// became scopes closed with `defer ui.end()` (CUI__SCOPE_IF ones return\n"
        "// bool and only open when true, matching the C macros).\n\n"
        + "\n".join(method_lines)
    )

    with open(ZIG) as zf:
        ztext = zf.read()

    def splice(text, mark, endmark, replacement):
        a = text.index(mark)
        b = text.index(endmark, a)
        return text[:a] + mark + " ====\n\n" + replacement.rstrip() + "\n" + text[b:]

    ztext = splice(ztext, TYPES_MARK, TYPES_END, types_code)
    ztext = splice(ztext, METHODS_MARK, METHODS_END, methods_code)
    with open(ZIG, "w") as zf:
        zf.write(ztext)

    print(f"generated {len(type_lines)} type blocks, {len(method_lines)} methods, {n_skipped} functions skipped")


if __name__ == "__main__":
    main()
