//! Builds SDL2_mixer from upstream source.
//!
//! No maintained Zig package exists for SDL_mixer, and it is the reason the
//! whole SDL2 family had to stay on the system until now: a vendored SDL2
//! beside a Homebrew SDL2_mixer would put two SDL2 copies with independent
//! global state in one process.
//!
//! dsda uses SDL_mixer for the audio device itself (Mix_OpenAudioDevice plus a
//! Mix_SetPostMix callback that feeds its own mixed sound effects) and for the
//! "SDL" music backend. Its other music backends -- fluidsynth, OPL, PortMidi,
//! vorbis, mad, xmp -- are dsda's own and do not go through here.
//!
//! Music format support uses the decoders SDL_mixer bundles (stb_vorbis,
//! dr_flac, minimp3, timidity) plus the libxmp we already build, so this needs
//! no external codec libraries of its own.

const std = @import("std");

const core_sources = [_][]const u8{
    "src/effect_position.c",
    "src/effect_stereoreverse.c",
    "src/effects_internal.c",
    "src/mixer.c",
    "src/music.c",
    "src/utils.c",
    "src/codecs/load_aiff.c",
    "src/codecs/load_voc.c",
    "src/codecs/mp3utils.c",
    "src/codecs/music_wav.c",
    "src/codecs/music_ogg_stb.c",
    "src/codecs/music_drflac.c",
    "src/codecs/music_minimp3.c",
    "src/codecs/music_xmp.c",
    "src/codecs/music_timidity.c",
};

/// Bundled software MIDI synth, used when fluidsynth is not in play.
const timidity_sources = [_][]const u8{
    "src/codecs/timidity/common.c",
    "src/codecs/timidity/instrum.c",
    "src/codecs/timidity/mix.c",
    "src/codecs/timidity/output.c",
    "src/codecs/timidity/playmidi.c",
    "src/codecs/timidity/readmidi.c",
    "src/codecs/timidity/resample.c",
    "src/codecs/timidity/tables.c",
    "src/codecs/timidity/timidity.c",
};

pub fn build(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdl2: *std.Build.Step.Compile,
    xmp: ?*std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });
    mod.addIncludePath(upstream.path("include"));
    mod.addIncludePath(upstream.path("src"));
    mod.addIncludePath(upstream.path("src/codecs"));
    mod.linkLibrary(sdl2);
    // SDL_mixer's headers do #include "SDL.h" flat.
    mod.addIncludePath(sdl2.getEmittedIncludeTree().path(b, "SDL2"));

    // WAV/AIFF/VOC are built in; the rest come from bundled decoders.
    for ([_][]const u8{
        "MUSIC_WAV",
        "MUSIC_OGG",
        "OGG_USE_STB",
        "MUSIC_FLAC_DRFLAC",
        "MUSIC_MP3_MINIMP3",
        "MUSIC_MID_TIMIDITY",
    }) |def| mod.addCMacro(def, "");

    var files: std.ArrayList([]const u8) = .empty;
    files.appendSlice(b.allocator, &core_sources) catch @panic("OOM");
    files.appendSlice(b.allocator, &timidity_sources) catch @panic("OOM");

    if (xmp) |lib| {
        mod.addCMacro("MUSIC_MOD_XMP", "");
        mod.linkLibrary(lib);
    }

    mod.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = files.items,
        .flags = &.{
            "-std=gnu99",
            "-Wno-unused-parameter",
            "-Wno-sign-compare",
            // minimp3 and stb_vorbis are vendored third-party headers with
            // their own warning posture.
            "-Wno-unused-function",
        },
        .language = .c,
    });

    const lib = b.addLibrary(.{ .name = "SDL2_mixer", .root_module = mod, .linkage = .static });
    lib.installHeader(upstream.path("include/SDL_mixer.h"), "SDL_mixer.h");
    return lib;
}
