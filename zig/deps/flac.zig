//! Builds libFLAC from upstream source.
//!
//! Needed because libsndfile gates FLAC, Vorbis and Opus support behind one
//! HAVE_EXTERNAL_XIPH_LIBS switch, and FLAC sound effects are common in Doom
//! mods.
//!
//! The per-architecture SIMD variants (lpc_intrin_avx2.c, fixed_intrin_sse2.c,
//! lpc_intrin_neon.c and friends) are deliberately omitted: each needs its own
//! -m flags wired up per file, they only affect speed, and dsda uses FLAC to
//! decode short sound effects where that is irrelevant. Setting the
//! FLAC__HAS_*INTRIN macros to 0 makes cpu.c skip the dispatch to them.

const std = @import("std");

const version = "1.4.3";

const core_sources = [_][]const u8{
    "bitmath.c",
    "bitreader.c",
    "bitwriter.c",
    "cpu.c",
    "crc.c",
    "fixed.c",
    "float.c",
    "format.c",
    "lpc.c",
    "md5.c",
    "memory.c",
    "metadata_iterators.c",
    "metadata_object.c",
    "stream_decoder.c",
    "stream_encoder.c",
    "stream_encoder_framing.c",
    "window.c",
};

/// Ogg-container support; libsndfile reads .oga/FLAC-in-Ogg through these.
const ogg_sources = [_][]const u8{
    "ogg_decoder_aspect.c",
    "ogg_encoder_aspect.c",
    "ogg_helper.c",
    "ogg_mapping.c",
};

pub fn build(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ogg: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const t = target.result;
    const posix = t.os.tag != .windows;

    const config_h = b.addConfigHeader(.{
        .style = .{ .cmake = upstream.path("config.cmake.h.in") },
        .include_path = "config.h",
    }, .{
        .PACKAGE = "flac",
        .PACKAGE_NAME = "FLAC",
        .PACKAGE_TARNAME = "flac",
        .PACKAGE_VERSION = version,
        .PROJECT_VERSION = version,
        .PACKAGE_STRING = "FLAC " ++ version,
        .PACKAGE_BUGREPORT = "",
        .PACKAGE_URL = "",
        .GIT_COMMIT_DATE = "",
        .GIT_COMMIT_HASH = "",
        .GIT_COMMIT_TAG = "",

        .CPU_IS_BIG_ENDIAN = t.cpu.arch.endian() == .big,
        .CPU_IS_LITTLE_ENDIAN = t.cpu.arch.endian() == .little,
        .FLAC__CPU_ARM64 = t.cpu.arch == .aarch64,
        .FLAC__SYS_DARWIN = t.os.tag.isDarwin(),
        .FLAC__SYS_LINUX = t.os.tag == .linux,
        .ENABLE_64_BIT_WORDS = t.ptrBitWidth() == 64,
        .FLAC__ALIGN_MALLOC_DATA = true,
        .AC_APPLE_UNIVERSAL_BUILD = false,

        // See the note at the top: generic C paths only.
        .FLAC__HAS_X86INTRIN = false,
        .FLAC__HAS_NEONINTRIN = false,
        .FLAC__HAS_A64NEONINTRIN = false,
        .WITH_AVX = false,
        .HAVE_X86INTRIN_H = false,
        .HAVE_CPUID_H = false,

        .OGG_FOUND = true,

        .HAVE_BSWAP16 = true,
        .HAVE_BSWAP32 = true,
        .HAVE_BYTESWAP_H = t.os.tag == .linux,
        .HAVE_CLOCK_GETTIME = posix,
        .HAVE_FSEEKO = posix,
        .HAVE_GETOPT_LONG = posix,
        .HAVE_INTTYPES_H = true,
        .HAVE_LROUND = true,
        .HAVE_MEMORY_H = true,
        .HAVE_STDINT_H = true,
        .HAVE_STDLIB_H = true,
        .HAVE_STRING_H = true,
        .HAVE_SYS_IOCTL_H = posix,
        .HAVE_SYS_PARAM_H = posix,
        .HAVE_SYS_STAT_H = true,
        .HAVE_SYS_TYPES_H = true,
        .HAVE_TERMIOS_H = posix,
        .HAVE_TYPEOF = true,
        .HAVE_UNISTD_H = posix,
        .HAVE_LANGINFO_CODESET = posix,
        .HAVE_ICONV = false,
        .ICONV_CONST = "",
        .HAVE_STDBOOL_H = true,
        .FLAC__HAS_DOCBOOK_TO_MAN = false,

        .SIZEOF_OFF_T = @as(i64, if (posix) 8 else 4),
        .SIZEOF_VOIDP = @as(i64, @divExact(t.ptrBitWidth(), 8)),

        .NDEBUG = optimize != .Debug,
        .DODEFINE_XOPEN_SOURCE = @as(i64, 0),
        .DODEFINE_EXTENSIONS = @as(i64, 0),
        ._POSIX_PTHREAD_SEMANTICS = false,
        ._TANDEM_SOURCE = false,
        ._LARGE_FILES = false,
        ._MINIX = false,
        ._POSIX_1_SOURCE = false,
        ._POSIX_SOURCE = false,
    });

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });
    mod.addConfigHeader(config_h);
    mod.addIncludePath(upstream.path("include"));
    mod.addIncludePath(upstream.path("src/libFLAC/include"));
    mod.linkLibrary(ogg);

    mod.addCMacro("HAVE_CONFIG_H", "");
    mod.addCMacro("FLAC__NO_DLL", "");

    mod.addCSourceFiles(.{
        .root = upstream.path("src/libFLAC"),
        .files = &(core_sources ++ ogg_sources),
        .flags = &.{ "-std=gnu99", "-Wno-unused-parameter" },
        .language = .c,
    });

    const lib = b.addLibrary(.{ .name = "FLAC", .root_module = mod, .linkage = .static });
    lib.installHeadersDirectory(upstream.path("include/FLAC"), "FLAC", .{});
    return lib;
}
