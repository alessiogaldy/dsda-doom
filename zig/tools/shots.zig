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
//!
//! Baselines belong to the environment that recorded them, and so are kept out
//! of the repository. The frames are not reproducible across machines: the
//! software renderer reaches libm to build its projection, and again for
//! fake-contrast wall lighting, where an atan result is rounded to an integer
//! light level -- so a last-bit libm difference becomes a visibly different
//! pixel. The GL frames depend on the driver on top of that. A committed golden
//! file would therefore be red on every machine but the one that recorded it,
//! and a wholesale mismatch looks exactly like a regression: worse than no gate
//! at all, because it teaches you to ignore the one test that can see the
//! renderer.
//!
//! What is left is the comparison that actually matters while changing the
//! renderer: this machine, before a change against after it. So a missing
//! baseline is not a failure, it is an instruction to record one from a build
//! you already trust.
//!
//! The runs are hermetic with respect to configuration. The game otherwise
//! reads the player's own dsda-doom.cfg, and -timedemo calls M_SaveDefaults on
//! the way out, so without this the hashes would depend on -- and then quietly
//! rewrite -- whatever settings the machine happened to have.

const std = @import("std");
const builtin = @import("builtin");
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

const usage =
    \\usage: shots [--bin PATH] [--baseline FILE] [--workdir DIR] [--save] [game args...]
    \\
;

const Row = struct {
    key: []const u8,
    hash: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var bin: []const u8 = "zig-out/bin/dsda-doom";
    var baseline_override: ?[]const u8 = null;
    var workdir: []const u8 = ".zig-cache/shots";
    var save = false;
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
            baseline_override = args[i];
        } else if (std.mem.eql(u8, a, "--workdir") and i + 1 < args.len) {
            i += 1;
            workdir = args[i];
        } else if (std.mem.startsWith(u8, a, "--")) {
            std.debug.print(usage, .{});
            return error.InvalidArguments;
        } else {
            // Everything else is the game's. The point of the check is comparing
            // two ways of producing the same frame, so the switch under test is
            // passed through here rather than added to the fixed argv below --
            // including bare values, as in "-assign uncapped_framerate=0".
            try game_args.append(arena, a);
        }
    }

    try Io.Dir.cwd().createDirPath(io, workdir);

    // Every case runs before anything is compared: the baseline is chosen by an
    // environment fingerprint, and the GL half of that fingerprint can only be
    // had from a run that opened a context.
    var rows: std.ArrayList(Row) = .empty;
    var gl_device: ?[]const u8 = null;

    for (cases) |case| {
        for (modes) |mode| {
            const is_gl = std.mem.eql(u8, mode, "gl");

            // A config file this harness owns. Emptied first, because the game
            // writes its defaults back on exit and a file left by an
            // interrupted run would otherwise carry into this one.
            const cfg = try std.fmt.allocPrint(arena, "{s}/{s}-{s}.cfg", .{ workdir, case.name, mode });
            Io.Dir.cwd().deleteFile(io, cfg) catch {};

            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(arena, &.{ bin, "-iwad", case.iwad });
            if (case.pwad) |p| try argv.appendSlice(arena, &.{ "-file", p });
            try argv.appendSlice(arena, &.{ "-timedemo", case.lmp });
            try argv.appendSlice(arena, &.{ "-nosound", "-nomusic" });
            try argv.appendSlice(arena, &.{ "-geom", "640x400w", "-vidmode", mode });
            try argv.appendSlice(arena, &.{ "-framehash", case.tics });
            try argv.appendSlice(arena, &.{ "-config", cfg });
            // The device and driver name the baseline, and this is where the
            // game prints them. It logs at debug level, so nothing that is
            // drawn depends on it.
            if (is_gl) try argv.append(arena, "-verbose");
            try argv.appendSlice(arena, game_args.items);

            const run = std.process.run(arena, io, .{ .argv = argv.items }) catch |err| {
                std.debug.print("shots: failed to run {s}: {t}\n", .{ bin, err });
                return err;
            };

            // The game prints through lprintf, so scan both streams rather
            // than assuming which one it lands on.
            var found: usize = 0;
            for ([_][]const u8{ run.stdout, run.stderr }) |stream| {
                if (is_gl and gl_device == null) {
                    if (lineAfter(stream, "GL_RENDERER: ")) |device| {
                        gl_device = try std.fmt.allocPrint(arena, "{s} / {s}", .{
                            device,
                            lineAfter(stream, "GL_VERSION: ") orelse "unknown driver",
                        });
                    }
                }

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

                    try rows.append(arena, .{
                        .key = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ case.name, mode, tic }),
                        .hash = hash,
                    });
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

    const fingerprint = try environment(arena, gl_device);
    const baseline_path = baseline_override orelse
        try std.fmt.allocPrint(arena, "zig/frame_hashes.{x}.txt", .{
            @as(u32, @truncate(std.hash.Fnv1a_64.hash(fingerprint))),
        });

    if (save) {
        var out: std.ArrayList(u8) = .empty;
        try out.print(arena,
            \\# Rendered frame fingerprints, recorded by: zig build shots -- --save
            \\# A mismatch means the renderer changed. That is not automatically
            \\# wrong, but it must be deliberate -- re-record only after looking.
            \\#
            \\# These belong to the machine that recorded them and are not
            \\# portable; see the header of zig/tools/shots.zig.
            \\environment: {s}
            \\
        , .{fingerprint});
        for (rows.items) |row| try out.print(arena, "{s}\t{s}\n", .{ row.key, row.hash });

        try Io.Dir.cwd().writeFile(io, .{ .sub_path = baseline_path, .data = out.items });
        std.debug.print("\nrecorded {d} frame hashes to {s}\n  environment: {s}\n", .{
            rows.items.len, baseline_path, fingerprint,
        });
        return;
    }

    const old = readBaseline(io, arena, baseline_path) orelse {
        std.debug.print(
            \\
            \\shots: no baseline for this environment
            \\  environment: {s}
            \\  expected at: {s}
            \\
            \\Frames are not reproducible across machines, so there is nothing to
            \\compare against yet. Record one from a build you trust -- master, or
            \\the commit before the change you are testing:
            \\
            \\  zig build shots -- --save
            \\
        , .{ fingerprint, baseline_path });
        return error.NoBaseline;
    };

    // The file name is a hash, so a stored fingerprint that disagrees is either
    // a collision or a baseline from a machine that has since been upgraded.
    // Either way it cannot be compared against, and saying so beats reporting
    // every frame as a regression.
    if (old.environment) |recorded| {
        if (!std.mem.eql(u8, recorded, fingerprint)) {
            std.debug.print(
                \\
                \\shots: {s} was recorded in a different environment
                \\  recorded: {s}
                \\       now: {s}
                \\
                \\Re-record it with: zig build shots -- --save
                \\
            , .{ baseline_path, recorded, fingerprint });
            return error.EnvironmentChanged;
        }
    }

    var failures: usize = 0;
    for (rows.items) |row| {
        if (old.hashes.get(row.key)) |want| {
            if (!std.mem.eql(u8, want, row.hash)) {
                std.debug.print(
                    "  MISMATCH {s}: expected {s}, got {s}\n",
                    .{ row.key, want, row.hash },
                );
                failures += 1;
            }
        } else {
            std.debug.print("  new      {s} = {s}\n", .{ row.key, row.hash });
        }
    }

    if (failures > 0) {
        std.debug.print("\n{d} of {d} frames differ from the baseline\n", .{ failures, rows.items.len });
        return error.RenderChanged;
    }
    std.debug.print("\nall {d} frames match\n", .{rows.items.len});
}

/// What a recorded frame depends on besides the code: the libm the software
/// renderer rounds its lighting through, the compiler that built it, and the
/// driver that drew the GL half.
fn environment(arena: std.mem.Allocator, gl_device: ?[]const u8) ![]const u8 {
    const u = std.posix.uname();

    return std.fmt.allocPrint(arena, "{s} {s} {s} | zig {d}.{d}.{d} | {s}", .{
        std.mem.sliceTo(&u.sysname, 0),
        std.mem.sliceTo(&u.release, 0),
        std.mem.sliceTo(&u.machine, 0),
        builtin.zig_version.major,
        builtin.zig_version.minor,
        builtin.zig_version.patch,
        gl_device orelse "no GL device reported",
    });
}

fn fieldAfter(line: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    const rest = line[at + key.len ..];
    const end = std.mem.indexOfAny(u8, rest, " \t\r\n") orelse rest.len;
    return rest[0..end];
}

/// The rest of the line following `key`, which unlike fieldAfter may contain
/// spaces -- a driver calls itself things like "2.1 Metal - 90.5".
fn lineAfter(text: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    const end = std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len;
    return std.mem.trim(u8, rest[0..end], " \t");
}

const Baseline = struct {
    environment: ?[]const u8,
    hashes: std.StringHashMap([]const u8),
};

fn readBaseline(io: Io, arena: std.mem.Allocator, path: []const u8) ?Baseline {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return null;
    var result: Baseline = .{ .environment = null, .hashes = .init(arena) };
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const env_key = "environment: ";
        if (std.mem.startsWith(u8, line, env_key)) {
            result.environment = std.mem.trim(u8, line[env_key.len..], " \t\r");
            continue;
        }
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const k = f.next() orelse continue;
        const v = f.next() orelse continue;
        result.hashes.put(k, v) catch return null;
    }
    return result;
}
