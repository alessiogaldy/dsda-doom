//! Render regression check.
//!
//! Renders fixed gametics of a demo and compares a fingerprint of each frame
//! against a recorded baseline. This is the only thing in the project that can
//! observe rendering at all: every rspec suite runs with -nodraw, so a change
//! that alters a pixel -- or a race once drawing moves off the main thread --
//! is completely invisible to them.
//!
//!     zig build shots -- --save    # record the current rendering as correct
//!     ...change the renderer...
//!     zig build shots              # fail if any frame differs
//!
//! The fingerprint is an FNV-1a hash of the raw RGB24 framebuffer, taken after
//! drawing completes but before the buffer swap (see I_HashScreen). Hashing
//! pixels rather than an encoded file keeps the result independent of the PNG
//! encoder and any metadata it embeds.
//!
//! A hash tells you *that* something changed, not what. When one trips, rerun
//! the game directly with -framehash on the offending tic; passing a path to
//! I_QueueFrameHash writes the frame out to look at.
//!
//! Deliberately run at a small fixed resolution: nothing here depends on
//! resolution, and 640x400 keeps a full check to a few seconds per case.

const std = @import("std");
const Io = std.Io;

const Case = struct {
    name: []const u8,
    iwad: []const u8,
    pwad: ?[]const u8 = null,
    lmp: []const u8,
    /// Gametics to fingerprint. The run exits after the last one, so keep them
    /// early enough that the check stays quick.
    tics: []const u8,
};

/// Chosen for renderer coverage rather than playsim load: Sunder map 15 for
/// huge open geometry and flood planes, map 31 for dense indoor detail, and
/// Sunlust for a second mapset with different texturing.
const cases = [_]Case{
    .{
        .name = "sunder15",
        .iwad = "spec/support/wads/DOOM2.WAD",
        .pwad = "spec/support/wads/sunder2512.wad",
        .lmp = "spec/support/lmps/sunder/su15p027.lmp",
        .tics = "200,500,900",
    },
    .{
        .name = "sunder31",
        .iwad = "spec/support/wads/DOOM2.WAD",
        .pwad = "spec/support/wads/sunder2512.wad",
        .lmp = "spec/support/lmps/sunder/su31m2737.lmp",
        .tics = "300,1200",
    },
    .{
        .name = "sunlust29",
        .iwad = "spec/support/wads/DOOM2.WAD",
        .pwad = "spec/support/wads/sunlust.wad",
        .lmp = "spec/support/lmps/sunlust/sl29m549.lmp",
        .tics = "300,1500",
    },
};

/// Both renderers are checked. They share the scene-building code, so a change
/// there can break one and not the other.
const modes = [_][]const u8{ "gl", "sw" };

const default_baseline = "zig/frame_hashes.txt";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var bin: []const u8 = "zig-out/bin/dsda-doom";
    var baseline_path: []const u8 = default_baseline;
    var save = false;
    // Passed through to the game. The point of the check is comparing two ways
    // of producing the same frame, so the switch under test goes here rather
    // than into the fixed argv below.
    var game_args: std.ArrayList([]const u8) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--save")) {
            save = true;
        } else if (std.mem.eql(u8, a, "--bin") and i + 1 < args.len) {
            i += 1;
            bin = args[i];
        } else if (std.mem.eql(u8, a, "--baseline") and i + 1 < args.len) {
            i += 1;
            baseline_path = args[i];
        } else if (std.mem.startsWith(u8, a, "-") and !std.mem.startsWith(u8, a, "--")) {
            try game_args.append(arena, a);
        } else {
            std.debug.print(
                \\usage: shots [--bin PATH] [--baseline FILE] [--save] [-gameflag...]
                \\
            , .{});
            return error.InvalidArguments;
        }
    }

    const old = readBaseline(io, arena, baseline_path);
    if (old == null and !save) {
        std.debug.print("shots: no baseline at {s}; run with --save first\n", .{baseline_path});
        return error.NoBaseline;
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena,
        \\# Rendered frame fingerprints. Regenerate with: zig build shots -- --save
        \\# A mismatch means the renderer changed. That is not automatically
        \\# wrong, but it must be deliberate -- re-record only after looking.
        \\
    );

    var failures: usize = 0;
    var checked: usize = 0;

    for (cases) |case| {
        for (modes) |mode| {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(arena, &.{ bin, "-iwad", case.iwad });
            if (case.pwad) |p| try argv.appendSlice(arena, &.{ "-file", p });
            try argv.appendSlice(arena, &.{ "-timedemo", case.lmp });
            try argv.appendSlice(arena, &.{ "-nosound", "-nomusic" });
            try argv.appendSlice(arena, &.{ "-geom", "640x400w", "-vidmode", mode });
            try argv.appendSlice(arena, &.{ "-framehash", case.tics });
            try argv.appendSlice(arena, game_args.items);

            const run = std.process.run(arena, io, .{ .argv = argv.items }) catch |err| {
                std.debug.print("shots: failed to run {s}: {t}\n", .{ bin, err });
                return err;
            };

            // The game prints through lprintf, so scan both streams rather
            // than assuming which one it lands on.
            var found: usize = 0;
            for ([_][]const u8{ run.stdout, run.stderr }) |stream| {
                var rest = stream;
                while (std.mem.indexOf(u8, rest, "FRAMEHASH ")) |idx| {
                    const line_start = idx + "FRAMEHASH ".len;
                    const line_end = std.mem.indexOfScalar(u8, rest[line_start..], '\n') orelse
                        rest.len - line_start;
                    const line = rest[line_start .. line_start + line_end];
                    rest = rest[line_start + line_end ..];

                    // "tic=200 hash=52edb97bd8f8b34b"
                    const tic = fieldAfter(line, "tic=") orelse continue;
                    const hash = fieldAfter(line, "hash=") orelse continue;
                    found += 1;
                    checked += 1;

                    const key = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ case.name, mode, tic });
                    try out.print(arena, "{s}\t{s}\n", .{ key, hash });

                    if (old) |b| {
                        if (b.get(key)) |want| {
                            if (!std.mem.eql(u8, want, hash)) {
                                std.debug.print(
                                    "  MISMATCH {s}: expected {s}, got {s}\n",
                                    .{ key, want, hash },
                                );
                                failures += 1;
                            }
                        } else {
                            std.debug.print("  new      {s} = {s}\n", .{ key, hash });
                        }
                    }
                }
            }

            if (found == 0) {
                std.debug.print(
                    "shots: {s}/{s} produced no frame hashes -- did the run fail?\n{s}\n",
                    .{ case.name, mode, run.stderr },
                );
                return error.NoFrameHashes;
            }
            std.debug.print("  {s:<10} {s}  {d} frames\n", .{ case.name, mode, found });
        }
    }

    if (save) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = baseline_path, .data = out.items });
        std.debug.print("\nrecorded {d} frame hashes to {s}\n", .{ checked, baseline_path });
        return;
    }

    if (failures > 0) {
        std.debug.print("\n{d} of {d} frames differ from the baseline\n", .{ failures, checked });
        return error.RenderChanged;
    }
    std.debug.print("\nall {d} frames match\n", .{checked});
}

fn fieldAfter(line: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    const rest = line[at + key.len ..];
    const end = std.mem.indexOfAny(u8, rest, " \t\r\n") orelse rest.len;
    return rest[0..end];
}

fn readBaseline(io: Io, arena: std.mem.Allocator, path: []const u8) ?std.StringHashMap([]const u8) {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return null;
    var map: std.StringHashMap([]const u8) = .init(arena);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const k = f.next() orelse continue;
        const v = f.next() orelse continue;
        map.put(k, v) catch return null;
    }
    return map;
}
