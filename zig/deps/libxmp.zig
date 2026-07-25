//! Builds libxmp (tracker module player) from upstream source.
//!
//! Used by MUSIC/xmpplayer.c for MOD/S3M/XM/IT music. This is the full
//! library, not libxmp-lite: the lite build drops most module formats, and
//! Homebrew's libxmp is the full one, so dropping to lite would silently
//! reduce the set of music files dsda can play.
//!
//! Upstream has no config header; everything is driven by -D defines.

const std = @import("std");
const sources = @import("libxmp_sources.zig");

pub fn build(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const t = target.result;
    const posix = t.os.tag != .windows;

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });
    mod.addIncludePath(upstream.path("include"));
    mod.addIncludePath(upstream.path("src"));

    // Consumers must see LIBXMP_STATIC too, or xmp.h decorates the API with
    // dllimport on Windows.
    mod.addCMacro("LIBXMP_STATIC", "");
    mod.addCMacro("HAVE_POWF", "");

    if (posix) {
        // These gate libxmp's external depackers, which shell out via
        // fork/exec to handle archived modules.
        for ([_][]const u8{
            "HAVE_UNISTD_H",
            "HAVE_MKSTEMP",
            "HAVE_POPEN",
            "HAVE_FNMATCH",
            "HAVE_UMASK",
            "HAVE_WAIT",
            "HAVE_PIPE",
            "HAVE_FORK",
            "HAVE_EXECVP",
            "HAVE_DUP2",
        }) |def| mod.addCMacro(def, "");
    }

    const flags = [_][]const u8{
        "-std=gnu99",
        // Upstream's own warning posture: these files are noisy and the
        // warnings are not ours to fix.
        "-Wno-unused-parameter",
        "-Wno-sign-compare",
    };
    inline for (.{ sources.core, sources.prowizard, sources.depackers }) |list| {
        mod.addCSourceFiles(.{
            .root = upstream.path("."),
            .files = &list,
            .flags = &flags,
            .language = .c,
        });
    }

    const lib = b.addLibrary(.{ .name = "xmp", .root_module = mod, .linkage = .static });
    lib.installHeader(upstream.path("include/xmp.h"), "xmp.h");
    return lib;
}
