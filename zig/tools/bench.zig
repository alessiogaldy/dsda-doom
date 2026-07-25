//! Playsim throughput benchmark.
//!
//! Runs demos under -fastdemo -nodraw, which exercises the game simulation
//! with rendering and sound switched off, and reports gametics per second.
//! That is the number playsim optimization work moves; anything touching the
//! renderer will not show up here at all.
//!
//! Each case is run several times and the *best* result is reported, not the
//! mean. A slow run means something else on the machine stole time; it carries
//! no information about the code. The spread between best and worst is printed
//! so a noisy machine is visible rather than silently averaged in.
//!
//! Results can be written to a baseline file and compared against on later
//! runs, so a change can be judged without remembering previous numbers:
//!
//!     zig build bench -- --save     # record where we are now
//!     ...edit the playsim...
//!     zig build bench               # compare against the recording
//!
//! Know the noise floor before believing a number. Repeats *within* one
//! invocation agree to within a few percent, but the same case measured across
//! separate invocations has been seen to move by 4% on an otherwise idle
//! machine -- CPU frequency and cache state do not reset identically. So a
//! sub-5% delta at the default rep count is not evidence of anything; raise
//! --reps, or re-record the baseline in the same sitting you compare against.
//!
//! Correctness is NOT checked here -- a change that makes the simulation
//! faster and wrong will look like a win. The rspec suites are the gate for
//! that, and they must pass before a benchmark number means anything.

const std = @import("std");
const Io = std.Io;

const Case = struct {
    name: []const u8,
    iwad: []const u8,
    pwad: ?[]const u8 = null,
    lmp: []const u8,
    extra: []const []const u8 = &.{},
};

/// Ordered cheapest first, so a run that is going to fail does so quickly.
///
/// These are the heaviest demos available, chosen because playsim cost scales
/// with thinker count and line-of-sight work, and ordinary maps are far too
/// cheap to measure against -- Doom 2 map30 runs at over 200k gametics/sec,
/// where the process spends most of its life starting up.
const cases = [_]Case{
    .{
        .name = "sunlust29",
        .iwad = "spec/support/wads/DOOM2.WAD",
        .pwad = "spec/support/wads/sunlust.wad",
        .lmp = "spec/support/lmps/sunlust/sl29m549.lmp",
    },
    .{
        .name = "sunlust30",
        .iwad = "spec/support/wads/DOOM2.WAD",
        .pwad = "spec/support/wads/sunlust.wad",
        .lmp = "spec/support/lmps/sunlust/sl30m1837.lmp",
    },
    .{
        .name = "sunder31",
        .iwad = "spec/support/wads/DOOM2.WAD",
        .pwad = "spec/support/wads/sunder2512.wad",
        .lmp = "spec/support/lmps/sunder/su31m2737.lmp",
    },
    .{
        .name = "sunder18",
        .iwad = "spec/support/wads/DOOM2.WAD",
        .pwad = "spec/support/wads/sunder2512.wad",
        .lmp = "spec/support/lmps/sunder/su18m5932.lmp",
    },
    .{
        .name = "sunder20",
        .iwad = "spec/support/wads/DOOM2.WAD",
        .pwad = "spec/support/wads/sunder2512.wad",
        .lmp = "spec/support/lmps/sunder/su20-6159.lmp",
    },
};

const default_baseline = "zig/bench_baseline.txt";

const Result = struct {
    name: []const u8,
    gametics: u64,
    /// Best of `reps`, in gametics per second.
    best: f64,
    /// How much slower the worst run was than the best, as a percentage.
    spread_pct: f64,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var bin: []const u8 = "zig-out/bin/dsda-doom";
    var baseline_path: []const u8 = default_baseline;
    var reps: usize = 3;
    var save = false;
    var filter: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--save")) {
            save = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(usage, .{});
            return;
        } else if (i + 1 < args.len) {
            i += 1;
            if (std.mem.eql(u8, a, "--bin")) {
                bin = args[i];
            } else if (std.mem.eql(u8, a, "--reps")) {
                reps = std.fmt.parseInt(usize, args[i], 10) catch {
                    std.debug.print("bench: --reps wants a number, got '{s}'\n", .{args[i]});
                    return error.InvalidArguments;
                };
            } else if (std.mem.eql(u8, a, "--baseline")) {
                baseline_path = args[i];
            } else if (std.mem.eql(u8, a, "--filter")) {
                filter = args[i];
            } else {
                std.debug.print("bench: unknown option '{s}'\n" ++ usage, .{a});
                return error.InvalidArguments;
            }
        } else {
            std.debug.print("bench: unknown or incomplete option '{s}'\n" ++ usage, .{a});
            return error.InvalidArguments;
        }
    }
    if (reps == 0) reps = 1;

    const baseline = readBaseline(io, arena, baseline_path);
    if (baseline == null and !save) {
        std.debug.print(
            "bench: no baseline at {s}; run with --save to record one\n\n",
            .{baseline_path},
        );
    }

    var results: std.ArrayList(Result) = .empty;

    for (cases) |case| {
        if (filter) |f| {
            if (std.mem.indexOf(u8, case.name, f) == null) continue;
        }

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ bin, "-iwad", case.iwad });
        if (case.pwad) |p| try argv.appendSlice(arena, &.{ "-file", p });
        try argv.appendSlice(arena, &.{ "-fastdemo", case.lmp });
        // -nodraw is what makes this a playsim benchmark rather than a
        // renderer one; -nosound/-nomusic keep the audio thread out of it.
        try argv.appendSlice(arena, &.{ "-nosound", "-nomusic", "-nodraw" });
        try argv.appendSlice(arena, case.extra);

        var best_ns: i96 = std.math.maxInt(i96);
        var worst_ns: i96 = 0;
        var gametics: u64 = 0;

        std.debug.print("  {s} ", .{case.name});
        for (0..reps) |_| {
            const t0 = Io.Clock.awake.now(io);
            const run = std.process.run(arena, io, .{ .argv = argv.items }) catch |err| {
                std.debug.print("\nbench: failed to run {s}: {t}\n", .{ bin, err });
                return err;
            };
            const t1 = Io.Clock.awake.now(io);

            switch (run.term) {
                .exited => |code| if (code != 0) {
                    std.debug.print("\nbench: {s} exited with {d}\n{s}\n", .{ case.name, code, run.stderr });
                    return error.DemoFailed;
                },
                else => {
                    std.debug.print("\nbench: {s} terminated abnormally\n", .{case.name});
                    return error.DemoFailed;
                },
            }

            gametics = parseGametics(run.stdout) orelse {
                std.debug.print(
                    "\nbench: no 'Timed N gametics' line from {s} -- is the demo valid?\n",
                    .{case.name},
                );
                return error.NoTimingOutput;
            };

            const ns = t0.durationTo(t1).toNanoseconds();
            best_ns = @min(best_ns, ns);
            worst_ns = @max(worst_ns, ns);
            std.debug.print(".", .{});
        }

        const best = @as(f64, @floatFromInt(gametics)) /
            (@as(f64, @floatFromInt(best_ns)) / std.time.ns_per_s);
        const spread = (@as(f64, @floatFromInt(worst_ns - best_ns)) /
            @as(f64, @floatFromInt(best_ns))) * 100.0;

        std.debug.print(" {d:.0} gametics/s\n", .{best});
        try results.append(arena, .{
            .name = case.name,
            .gametics = gametics,
            .best = best,
            .spread_pct = spread,
        });
    }

    if (results.items.len == 0) {
        std.debug.print("bench: no cases matched\n", .{});
        return error.NoCasesMatched;
    }

    report(results.items, baseline);

    if (save) {
        try writeBaseline(io, arena, baseline_path, results.items);
        std.debug.print("\nbaseline written to {s}\n", .{baseline_path});
    }
}

const usage =
    \\
    \\usage: bench [--bin PATH] [--reps N] [--baseline FILE] [--filter SUBSTR] [--save]
    \\
    \\  --bin       binary under test (default zig-out/bin/dsda-doom)
    \\  --reps      runs per case, best wins (default 3)
    \\  --baseline  comparison file (default zig/bench_baseline.txt)
    \\  --filter    only run cases whose name contains SUBSTR
    \\  --save      write results to the baseline file
    \\
;

/// dsda prints "Timed 130397 gametics in 68 realtics = ..." when a fastdemo
/// finishes. Only the gametic count is used -- realtics are quantised to 1/35s
/// and far too coarse to benchmark against.
fn parseGametics(stdout: []const u8) ?u64 {
    const marker = "Timed ";
    var search = stdout;
    // Take the last occurrence: a demo spanning several levels prints once per
    // level, and the final line covers the whole run.
    var found: ?u64 = null;
    while (std.mem.indexOf(u8, search, marker)) |idx| {
        const rest = search[idx + marker.len ..];
        const end = std.mem.indexOfAny(u8, rest, " \t\r\n") orelse rest.len;
        if (std.fmt.parseInt(u64, rest[0..end], 10)) |n| {
            found = n;
        } else |_| {}
        search = rest;
    }
    return found;
}

fn readBaseline(io: Io, arena: std.mem.Allocator, path: []const u8) ?std.StringHashMap(f64) {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return null;
    var map: std.StringHashMap(f64) = .init(arena);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        const value = fields.next() orelse continue;
        const parsed = std.fmt.parseFloat(f64, value) catch continue;
        map.put(name, parsed) catch return null;
    }
    return map;
}

fn writeBaseline(io: Io, arena: std.mem.Allocator, path: []const u8, results: []const Result) !void {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena,
        \\# Playsim throughput baseline, in gametics per second.
        \\# Regenerate with: zig build bench -- --save
        \\# Machine-specific: do not compare numbers across different hardware.
        \\
    );
    for (results) |r| {
        try out.print(arena, "{s}\t{d:.0}\n", .{ r.name, r.best });
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

fn report(results: []const Result, baseline: ?std.StringHashMap(f64)) void {
    std.debug.print("\n{s:<12} {s:>10} {s:>14} {s:>8}", .{ "case", "gametics", "gametics/s", "spread" });
    if (baseline != null) std.debug.print(" {s:>10} {s:>9}", .{ "baseline", "delta" });
    std.debug.print("\n", .{});

    for (results) |r| {
        std.debug.print("{s:<12} {d:>10} {d:>14.0} {d:>7.1}%", .{
            r.name, r.gametics, r.best, r.spread_pct,
        });
        if (baseline) |b| {
            if (b.get(r.name)) |old| {
                const delta = ((r.best - old) / old) * 100.0;
                // Zig's format spec has no sign flag, so carry it by hand --
                // a leading + is what makes an improvement obvious at a glance.
                var buf: [32]u8 = undefined;
                const shown = std.fmt.bufPrint(&buf, "{s}{d:.1}%", .{
                    if (delta >= 0) "+" else "", delta,
                }) catch "?";
                std.debug.print(" {d:>10.0} {s:>9}", .{ old, shown });
            } else {
                std.debug.print(" {s:>10} {s:>9}", .{ "-", "new" });
            }
        }
        std.debug.print("\n", .{});
    }

    // A spread this wide means the machine was busy; the numbers are not
    // trustworthy enough to judge a small change by.
    for (results) |r| {
        if (r.spread_pct > 10.0) {
            std.debug.print(
                "\nnote: {s} varied by {d:.0}% between runs -- close other work before trusting small deltas\n",
                .{ r.name, r.spread_pct },
            );
            break;
        }
    }
}
