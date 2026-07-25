//! Builds libmad (MPEG audio decoder) from upstream source.
//!
//! Used by MUSIC/madplayer.c for MP3 music. Upstream selects a fixed-point
//! math implementation per architecture with FPM_* defines; the wrong choice
//! silently produces garbage audio rather than failing to build, so the
//! mapping below matters.
//!
//! The hand-written assembly optimisations (ASO_*, imdct_l_arm.S) are left
//! out: they exist for 1990s-era CPUs and the generic C path is fine.

const std = @import("std");

const version_major = 0;
const version_minor = 16;
const version_patch = 4;

const sources = [_][]const u8{
    "bit.c",
    "decoder.c",
    "fixed.c",
    "frame.c",
    "huffman.c",
    "layer12.c",
    "layer3.c",
    "stream.c",
    "synth.c",
    "timer.c",
    "version.c",
};

pub fn build(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const t = target.result;

    // Matches upstream CMakeLists.txt: 64-bit targets use FPM_64BIT, and the
    // 32-bit ones each have a dedicated implementation. Picking the wrong one
    // still compiles -- it just decodes to garbage -- so this is the part of
    // the libmad build worth being careful about.
    const bits64 = t.ptrBitWidth() == 64;
    const arch = t.cpu.arch;

    // mad.h carries the FPM selection, the version and sizeof(int); the
    // sources read it rather than taking them as -D flags.
    const mad_h = b.addConfigHeader(.{
        .style = .{ .cmake = upstream.path("mad.h.in") },
        .include_path = "mad.h",
    }, .{
        .FPM_64BIT = bits64,
        .FPM_INTEL = !bits64 and arch == .x86,
        .FPM_ARM = !bits64 and arch.isArm(),
        .FPM_MIPS = !bits64 and arch.isMIPS(),
        .FPM_SPARC = !bits64 and arch.isSPARC(),
        .FPM_PPC = !bits64 and arch.isPowerPC(),
        .FPM_DEFAULT = !bits64 and !(arch == .x86 or arch.isArm() or
            arch.isMIPS() or arch.isSPARC() or arch.isPowerPC()),

        .CMAKE_PROJECT_VERSION_MAJOR = @as(i64, version_major),
        .CMAKE_PROJECT_VERSION_MINOR = @as(i64, version_minor),
        .CMAKE_PROJECT_VERSION_PATCH = @as(i64, version_patch),
        // int is 32 bits on every target dsda supports.
        .SIZEOF_INT = @as(i64, 4),
    });

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });
    mod.addConfigHeader(mad_h);
    mod.addIncludePath(upstream.path("."));

    // Favour accuracy over speed; this decodes music, not a hot loop.
    mod.addCMacro("OPT_ACCURACY", "");

    if (t.os.tag != .windows) {
        for ([_][]const u8{
            "HAVE_SYS_TYPES_H",
            "HAVE_SYS_STAT_H",
            "HAVE_UNISTD_H",
            "HAVE_FCNTL_H",
        }) |def| mod.addCMacro(def, "");
    }
    for ([_][]const u8{ "HAVE_ASSERT_H", "HAVE_LIMITS_H" }) |def| mod.addCMacro(def, "");

    mod.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = &sources,
        .flags = &.{"-std=gnu99"},
        .language = .c,
    });

    const lib = b.addLibrary(.{ .name = "mad", .root_module = mod, .linkage = .static });
    lib.installConfigHeader(mad_h);
    return lib;
}
