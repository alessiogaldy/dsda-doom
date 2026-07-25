//! Builds libopus from upstream source.
//!
//! Not used by dsda directly -- it is here because libsndfile gates all of its
//! Xiph codec support behind a single HAVE_EXTERNAL_XIPH_LIBS switch, so
//! getting FLAC and Vorbis sound-effect support means building Opus too.
//!
//! Float build rather than fixed-point: every target dsda supports has an FPU,
//! and libsndfile only ever decodes.

const std = @import("std");
const sources = @import("opus_sources.zig");

pub fn build(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });
    for ([_][]const u8{
        "include",
        "celt",
        "silk",
        "silk/float",
        "src",
        ".",
    }) |dir| mod.addIncludePath(upstream.path(dir));

    // Upstream normally generates a config.h; these are the only settings that
    // matter for a plain float decoder build.
    mod.addCMacro("OPUS_BUILD", "1");
    mod.addCMacro("USE_ALLOCA", "1");
    mod.addCMacro("HAVE_LRINTF", "1");
    mod.addCMacro("HAVE_LRINT", "1");
    // Avoid the runtime CPU-detection machinery, which needs its own config
    // plumbing and buys nothing here.
    mod.addCMacro("OPUS_HAVE_RTCD", "0");

    const flags = [_][]const u8{
        "-std=gnu99",
        "-Wno-unused-parameter",
        "-Wno-sign-compare",
    };
    inline for (.{ sources.opus, sources.opus_float, sources.celt, sources.silk, sources.silk_float }) |list| {
        mod.addCSourceFiles(.{
            .root = upstream.path("."),
            .files = &list,
            .flags = &flags,
            .language = .c,
        });
    }

    const lib = b.addLibrary(.{ .name = "opus", .root_module = mod, .linkage = .static });
    for ([_][]const u8{
        "opus.h",
        "opus_types.h",
        "opus_defines.h",
        "opus_multistream.h",
        "opus_projection.h",
    }) |h| {
        lib.installHeader(upstream.path(b.fmt("include/{s}", .{h})), b.fmt("opus/{s}", .{h}));
    }
    return lib;
}
