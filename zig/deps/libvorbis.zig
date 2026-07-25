//! Builds libvorbis + libvorbisfile from upstream xiph/vorbis source.
//!
//! dsda only needs vorbisfile (MUSIC/vorbisplayer.c), but vorbisfile depends
//! on the vorbis decoder, which depends on ogg. The encoder (vorbisenc) is
//! left out -- nothing in dsda writes Ogg Vorbis.
//!
//! No config.h: upstream's autoconf probes only feed the encoder and the
//! example tools, not the decoder.

const std = @import("std");

/// Source list from upstream lib/CMakeLists.txt (VORBIS_SOURCES).
const vorbis_sources = [_][]const u8{
    "mdct.c",
    "smallft.c",
    "block.c",
    "envelope.c",
    "window.c",
    "lsp.c",
    "lpc.c",
    "analysis.c",
    "synthesis.c",
    "psy.c",
    "info.c",
    "floor1.c",
    "floor0.c",
    "res0.c",
    "mapping0.c",
    "registry.c",
    "codebook.c",
    "sharedbook.c",
    "lookup.c",
    "bitrate.c",
};

pub fn build(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ogg: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });
    mod.addIncludePath(upstream.path("include"));
    mod.addIncludePath(upstream.path("lib"));
    mod.linkLibrary(ogg);

    const flags = [_][]const u8{"-std=gnu99"};
    mod.addCSourceFiles(.{
        .root = upstream.path("lib"),
        // vorbisfile.c is folded into the same artifact rather than built as a
        // separate library: dsda links both, and keeping them together avoids
        // an extra artifact for one source file.
        .files = &(vorbis_sources ++ [_][]const u8{"vorbisfile.c"}),
        .flags = &flags,
        .language = .c,
    });

    const lib = b.addLibrary(.{ .name = "vorbisfile", .root_module = mod, .linkage = .static });
    for ([_][]const u8{ "codec.h", "vorbisfile.h" }) |h| {
        lib.installHeader(upstream.path(b.fmt("include/vorbis/{s}", .{h})), b.fmt("vorbis/{s}", .{h}));
    }
    return lib;
}
