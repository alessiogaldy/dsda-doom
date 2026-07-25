//! Generates libzip's zip_err_str.c, replacing upstream's
//! cmake/GenerateZipErrorStrings.cmake.
//!
//! Both tables are encoded in the comments beside the #define lines in zip.h
//! and zipint.h, e.g.
//!
//!     #define ZIP_ER_MULTIDISK 1  /* N Multi-disk zip archives not supported */
//!
//! where the first token of the comment is the error-type macro (L/N/S/Z for
//! errors, E/G for details) and the remainder is the message. Upstream pulls
//! these out with a CMake regex; this does the same with string scanning.
//!
//! Usage: gen_zip_err_str <zip.h> <zipint.h> <output.c>

const std = @import("std");
const Io = std.Io;

const preamble =
    \\/*
    \\  This file was generated automatically from zip.h and zipint.h;
    \\  make changes there.
    \\*/
    \\
    \\#include "zipint.h"
    \\
    \\#define L ZIP_ET_LIBZIP
    \\#define N ZIP_ET_NONE
    \\#define S ZIP_ET_SYS
    \\#define Z ZIP_ET_ZLIB
    \\
    \\#define E ZIP_DETAIL_ET_ENTRY
    \\#define G ZIP_DETAIL_ET_GLOBAL
    \\
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.debug.print("usage: gen_zip_err_str <zip.h> <zipint.h> <output.c>\n", .{});
        return error.InvalidArguments;
    }

    const cwd = Io.Dir.cwd();
    const zip_h = try cwd.readFileAlloc(io, args[1], arena, .limited(4 << 20));
    const zipint_h = try cwd.readFileAlloc(io, args[2], arena, .limited(4 << 20));

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, preamble);

    try emitTable(arena, &out, zip_h, "ZIP_ER_", "_zip_err_str", "LNSZ");
    try out.appendSlice(arena,
        \\
        \\const int _zip_err_str_count = sizeof(_zip_err_str)/sizeof(_zip_err_str[0]);
        \\
        \\
    );

    try emitTable(arena, &out, zipint_h, "ZIP_ER_DETAIL_", "_zip_err_details", "EG");
    try out.appendSlice(arena,
        \\
        \\const int _zip_err_details_count = sizeof(_zip_err_details)/sizeof(_zip_err_details[0]);
        \\
    );

    try cwd.writeFile(io, .{ .sub_path = args[3], .data = out.items });
}

/// Emits one `{ TYPE, "message" },` row per matching #define.
///
/// `type_letters` lists the valid single-character type macros; requiring the
/// comment to start with one is what separates real entries from unrelated
/// comments on neighbouring defines.
fn emitTable(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    source: []const u8,
    prefix: []const u8,
    table_name: []const u8,
    type_letters: []const u8,
) !void {
    try out.print(arena, "const struct _zip_err_info {s}[] = {{\n", .{table_name});

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const define = "#define ";
        if (!std.mem.startsWith(u8, line, define)) continue;
        if (!std.mem.startsWith(u8, line[define.len..], prefix)) continue;

        const open = std.mem.indexOf(u8, line, "/*") orelse continue;
        const close = std.mem.lastIndexOf(u8, line, "*/") orelse continue;
        if (close <= open + 2) continue;
        const comment = std.mem.trim(u8, line[open + 2 .. close], " \t");

        const sep = std.mem.indexOfAny(u8, comment, " \t") orelse continue;
        if (sep != 1) continue;
        const letter = comment[0];
        if (std.mem.indexOfScalar(u8, type_letters, letter) == null) continue;

        const message = std.mem.trim(u8, comment[sep..], " \t\r");
        try out.print(arena, "    {{ {c}, \"{s}\" }},\n", .{ letter, message });
    }

    try out.appendSlice(arena, "};\n");
}
