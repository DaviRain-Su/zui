/* Aggregates the CUI headers that zui translates into Zig bindings at build
 * time (Zig 0.17 removed @cImport; the build script turns this header into a
 * module that src/zui.zig imports as "c"). */
#include <cui/cui.h>
#include <cui/cui_app.h>
#include <cui/cui_render.h>
