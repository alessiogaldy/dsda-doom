//! Builds FluidSynth from upstream source, without GLib.
//!
//! FluidSynth is dsda's default MIDI backend (snd_midiplayer defaults to
//! "fluidsynth"): it renders Doom's MIDI music through an SF2 soundfont, and
//! dsda ships one as the sndfont.lmp lump inside dsda-doom.wad.
//!
//! It is usually assumed to require GLib, which would drag in pcre2, libffi,
//! gettext and libiconv. It does not: upstream has a pluggable OS abstraction
//! layer (the `osal` CMake setting) with a `cpp11` backend that uses
//! std::thread, std::mutex and std::filesystem instead. dsda already links
//! libc++ for its own C++ sources, so that costs nothing.
//!
//! Every audio and MIDI driver is disabled. dsda drives the synth directly
//! with fluid_synth_write_float and mixes the result itself, so it never opens
//! a fluidsynth device. drivers/fluid_adriver.c and drivers/fluid_mdriver.c
//! still compile -- they are the driver registries -- but their tables end up
//! empty, which is what we want.

const std = @import("std");
const sources = @import("fluidsynth_sources.zig");

const version = "2.5.7";

pub fn build(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    /// GCE-Math, a header-only constexpr math library. Upstream carries it as
    /// a git submodule, which `zig fetch` does not clone, so it is pinned
    /// separately in build.zig.zon. src/gentables/*.cpp use it to compute the
    /// synth's lookup tables at compile time.
    gcem: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const t = target.result;
    const posix = t.os.tag != .windows;

    const config_h = b.addConfigHeader(.{
        .style = .{ .cmake = upstream.path("src/config.cmake") },
        .include_path = "config.h",
    }, .{
        .PACKAGE = "fluidsynth",
        .PACKAGE_NAME = "fluidsynth",
        .PACKAGE_TARNAME = "fluidsynth",
        .PACKAGE_VERSION = version,
        .PACKAGE_STRING = "fluidsynth " ++ version,
        .PACKAGE_BUGREPORT = "",
        .osal = "cpp11",
        .INLINE_KEYWORD = "inline",

        .DARWIN = t.os.tag.isDarwin(),
        .MINGW32 = t.os.tag == .windows and t.abi == .gnu,
        .WORDS_BIGENDIAN = t.cpu.arch.endian() == .big,
        .STDC_HEADERS = true,
        .SUPPORTS_VLA = true,
        // Single-precision rendering, matching upstream's default.
        .WITH_FLOAT = true,
        .ENABLE_MIXER_THREADS = true,
        .HAVE_CXX_FILESYSTEM = true,
        .NO_GUI = true,

        // Every driver off: dsda renders via fluid_synth_write_float.
        .ALSA_SUPPORT = false,
        .AUFILE_SUPPORT = false,
        .COREAUDIO_SUPPORT = false,
        .COREAUDIO_SUPPORT_HAL = false,
        .COREMIDI_SUPPORT = false,
        .DART_SUPPORT = false,
        .DBUS_SUPPORT = false,
        .DSOUND_SUPPORT = false,
        .JACK_SUPPORT = false,
        .KAI_SUPPORT = false,
        .MIDISHARE_SUPPORT = false,
        .OBOE_SUPPORT = false,
        .OPENSLES_SUPPORT = false,
        .OSS_SUPPORT = false,
        .PIPEWIRE_SUPPORT = false,
        .PORTAUDIO_SUPPORT = false,
        .PULSE_SUPPORT = false,
        .SDL3_SUPPORT = false,
        .SYSTEMD_SUPPORT = false,
        .WASAPI_SUPPORT = false,
        .WAVEOUT_SUPPORT = false,
        .WINMIDI_SUPPORT = false,

        // Optional extras dsda does not use.
        .LADSPA = false,
        .LADSPA_SUPPORT = false,
        .LIBINSTPATCH_SUPPORT = false,
        .LIBSNDFILE_SUPPORT = false,
        .LIBSNDFILE_HASVORBIS = false,
        .READLINE_SUPPORT = false,
        .NETWORK_SUPPORT = false,
        .IPV6_SUPPORT = false,
        .ENABLE_NATIVE_DLS = false,
        .HAVE_OPENMP = false,
        .DEFAULT_SOUNDFONT = "",

        .FPE_CHECK = false,
        .TRAP_ON_FPE = false,
        .WITH_PROFILING = false,

        .HAVE_MATH_H = true,
        .HAVE_STDIO_H = true,
        .HAVE_STDLIB_H = true,
        .HAVE_STDARG_H = true,
        .HAVE_STDINT_H = true,
        .HAVE_STRING_H = true,
        .HAVE_LIMITS_H = true,
        .HAVE_ERRNO_H = true,
        .HAVE_SIGNAL_H = true,
        .HAVE_INTTYPES_H = true,
        .HAVE_FCNTL_H = true,
        .HAVE_STRINGS_H = posix,
        .HAVE_UNISTD_H = posix,
        .HAVE_GETOPT_H = posix,
        .HAVE_PTHREAD_H = posix,
        .HAVE_SYS_TYPES_H = posix,
        .HAVE_SYS_STAT_H = true,
        .HAVE_SYS_TIME_H = posix,
        .HAVE_SYS_MMAN_H = posix,
        .HAVE_SYS_SOCKET_H = posix,
        .HAVE_NETINET_IN_H = posix,
        .HAVE_NETINET_TCP_H = posix,
        .HAVE_ARPA_INET_H = posix,
        .HAVE_SOCKLEN_T = posix,
        .HAVE_INETNTOP = posix,
        .HAVE_WINDOWS_H = !posix,
        .HAVE_IO_H = !posix,
        .HAVE_LINUX_SOUNDCARD_H = false,
        .HAVE_MACHINE_SOUNDCARD_H = false,
        .HAVE_SYS_SOUNDCARD_H = false,

        .HAVE_COSF = true,
        .HAVE_SINF = true,
        .HAVE_LOGF = true,
        .HAVE_POWF = true,
        .HAVE_SQRTF = true,
        .HAVE_FABSF = true,

        // Test-suite paths; unused here.
        .TEST_COMMAND_LINES = "",
        .TEST_DLS = "",
        .TEST_MIDI_UTF8 = "",
        .TEST_SOUNDFONT = "",
        .TEST_SOUNDFONT_SF3 = "",
        .TEST_SOUNDFONT_UTF8_1 = "",
        .TEST_SOUNDFONT_UTF8_2 = "",
        .TEST_WAV_UTF8 = "",
    });

    // Two public headers are generated too.
    const fluidsynth_h = b.addConfigHeader(.{
        .style = .{ .cmake = upstream.path("include/fluidsynth.cmake") },
        .include_path = "fluidsynth.h",
    }, .{
        // Static build, so no dllimport/dllexport decoration.
        .BUILD_SHARED_LIBS = false,
    });
    const version_h = b.addConfigHeader(.{
        .style = .{ .autoconf_at = upstream.path("include/fluidsynth/version.h.in") },
        .include_path = "fluidsynth/version.h",
    }, .{
        .FLUIDSYNTH_VERSION = version,
        .FLUIDSYNTH_VERSION_MAJOR = @as(i64, 2),
        .FLUIDSYNTH_VERSION_MINOR = @as(i64, 5),
        .FLUIDSYNTH_VERSION_MICRO = @as(i64, 7),
    });

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // The cpp11 OSAL, plus a dozen .cpp files in the DSP and sequencer.
        .link_libcpp = true,
        .sanitize_c = .off,
    });
    mod.addConfigHeader(config_h);
    mod.addConfigHeader(fluidsynth_h);
    mod.addConfigHeader(version_h);
    for ([_][]const u8{
        "include",
        "src",
        "src/utils",
        "src/sfloader",
        "src/rvoice",
        "src/synth",
        "src/midi",
        "src/drivers",
        "src/bindings",
    }) |dir| mod.addIncludePath(upstream.path(dir));
    mod.addIncludePath(gcem.path("include"));

    const c_flags = [_][]const u8{ "-std=gnu99", "-Wno-unused-parameter" };
    // fluid_sys_cpp11.cpp wants std::filesystem, which is C++17.
    const cxx_flags = [_][]const u8{ "-std=c++17", "-Wno-unused-parameter" };

    mod.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = &sources.c,
        .flags = &c_flags,
        .language = .c,
    });
    mod.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = &sources.cpp,
        .flags = &cxx_flags,
        .language = .cpp,
    });
    // The OSAL: cpp11 instead of glib. This one file is the whole reason
    // GLib is not needed.
    mod.addCSourceFile(.{
        .file = upstream.path("src/utils/fluid_sys_cpp11.cpp"),
        .flags = &cxx_flags,
        .language = .cpp,
    });

    const lib = b.addLibrary(.{ .name = "fluidsynth", .root_module = mod, .linkage = .static });
    lib.installHeadersDirectory(upstream.path("include"), "", .{ .include_extensions = &.{".h"} });
    lib.installConfigHeader(fluidsynth_h);
    lib.installConfigHeader(version_h);
    return lib;
}
