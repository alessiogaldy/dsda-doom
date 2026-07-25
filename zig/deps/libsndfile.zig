//! Builds libsndfile from upstream source.
//!
//! Unlike the other audio libraries this one is *required*: SDL/i_sndfile.c is
//! compiled unconditionally and dsda loads all of its sound effects through it.
//!
//! Xiph codec support (FLAC, Vorbis, Opus) is one switch upstream --
//! HAVE_EXTERNAL_XIPH_LIBS -- so it is all or nothing. It is on here, because
//! Doom mods commonly ship FLAC and Ogg sound effects and turning it off would
//! silently stop those loading.
//!
//! MPEG is off: libsndfile needs both mpg123 and LAME for it, and dsda already
//! decodes MP3 *music* through libmad. The only loss is MP3 sound effects,
//! which is why HAVE_SNDFILE_MPEG must be reported as false to dsda's own
//! config.h when this build is used.

const std = @import("std");
const sources = @import("libsndfile_sources.zig");

const version = "1.2.2";

pub const has_mpeg = false;

pub fn build(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    xiph: struct {
        ogg: *std.Build.Step.Compile,
        vorbis: *std.Build.Step.Compile,
        flac: *std.Build.Step.Compile,
        opus: *std.Build.Step.Compile,
    },
) *std.Build.Step.Compile {
    const t = target.result;
    const posix = t.os.tag != .windows;
    const ptr_bytes = @divExact(t.ptrBitWidth(), 8);
    const long_bytes: u16 = if (t.os.tag == .windows) 4 else ptr_bytes;

    // Upstream injects whole `#define SIZEOF_X n` lines rather than bare
    // values, so these substitutions are code fragments, not numbers. A type
    // absent on the target gets a 0 size, which is what libsndfile expects.
    const sizeof = struct {
        fn code(bb: *std.Build, name: []const u8, bytes: u16) []const u8 {
            return bb.fmt("#define SIZEOF_{s} {d}", .{ name, bytes });
        }
    };

    const config_h = b.addConfigHeader(.{
        .style = .{ .cmake = upstream.path("src/config.h.cmake") },
        .include_path = "config.h",
    }, .{
        .INLINE_CODE = "#define inline inline",
        .CPACK_PACKAGE_VERSION_FULL = version,
        .PROJECT_VERSION = version,
        .PACKAGE_NAME = "libsndfile",
        .PACKAGE_BUGREPORT = "",
        .PACKAGE_URL = "",

        .SIZEOF_SHORT_CODE = sizeof.code(b, "SHORT", 2),
        .SIZEOF_INT_CODE = sizeof.code(b, "INT", 4),
        .SIZEOF_LONG_CODE = sizeof.code(b, "LONG", long_bytes),
        .SIZEOF_LONG_LONG_CODE = sizeof.code(b, "LONG_LONG", 8),
        .SIZEOF_FLOAT_CODE = sizeof.code(b, "FLOAT", 4),
        .SIZEOF_DOUBLE_CODE = sizeof.code(b, "DOUBLE", 8),
        .SIZEOF_INT64_T_CODE = sizeof.code(b, "INT64_T", 8),
        .SIZEOF_VOIDP_CODE = sizeof.code(b, "VOIDP", ptr_bytes),
        .SIZEOF_SIZE_T_CODE = sizeof.code(b, "SIZE_T", ptr_bytes),
        .SIZEOF_SSIZE_T_CODE = sizeof.code(b, "SSIZE_T", ptr_bytes),
        .SIZEOF_WCHAR_T_CODE = sizeof.code(b, "WCHAR_T", if (t.os.tag == .windows) 2 else 4),
        .SIZEOF_OFF_T_CODE = sizeof.code(b, "OFF_T", if (posix) 8 else 4),
        // Linux-only glibc types; 0 means "not present".
        .SIZEOF_LOFF_T_CODE = sizeof.code(b, "LOFF_T", if (t.os.tag == .linux) 8 else 0),
        .SIZEOF_OFF64_T_CODE = sizeof.code(b, "OFF64_T", if (t.os.tag == .linux) 8 else 0),

        .CPU_IS_BIG_ENDIAN = t.cpu.arch.endian() == .big,
        .CPU_IS_LITTLE_ENDIAN = t.cpu.arch.endian() == .little,
        .WORDS_BIGENDIAN = t.cpu.arch.endian() == .big,
        // Whether casting a negative float to int clips. Both false selects
        // libsndfile's portable lrint-based path.
        .CPU_CLIPS_NEGATIVE = false,
        .CPU_CLIPS_POSITIVE = false,

        .HAVE_EXTERNAL_XIPH_LIBS = true,
        .HAVE_MPEG = has_mpeg,
        .ENABLE_EXPERIMENTAL_CODE = false,
        .HAVE_SPEEX = false,
        .HAVE_SQLITE3 = false,
        .HAVE_ALSA_ASOUNDLIB_H = false,
        .HAVE_SNDIO_H = false,

        .COMPILER_IS_GCC = true,
        .HAVE_LIBM = true,
        .HAVE_SSIZE_T = posix,

        .HAVE_CALLOC = true,
        .HAVE_MALLOC = true,
        .HAVE_REALLOC = true,
        .HAVE_FREE = true,
        .HAVE_CEIL = true,
        .HAVE_FLOOR = true,
        .HAVE_FMOD = true,
        .HAVE_LRINT = true,
        .HAVE_LRINTF = true,
        .HAVE_LROUND = true,
        .HAVE_SNPRINTF = true,
        .HAVE_VSNPRINTF = true,
        .HAVE_SETLOCALE = true,
        .HAVE_GMTIME = true,
        .HAVE_LOCALTIME = true,

        .HAVE_OPEN = posix,
        .HAVE_READ = posix,
        .HAVE_WRITE = posix,
        .HAVE_LSEEK = posix,
        .HAVE_FSTAT = posix,
        .HAVE_FSYNC = posix,
        .HAVE_FTRUNCATE = posix,
        .HAVE_GETPAGESIZE = posix,
        .HAVE_GETTIMEOFDAY = posix,
        .HAVE_GMTIME_R = posix,
        .HAVE_LOCALTIME_R = posix,
        .HAVE_MMAP = posix,
        .HAVE_PIPE = posix,
        .HAVE_WAITPID = posix,
        .HAVE_DECL_S_IRGRP = posix,
        // 64-bit off_t everywhere on modern POSIX, so the *64 variants are
        // absent rather than needed.
        .HAVE_FSTAT64 = false,
        .HAVE_LSEEK64 = false,

        .HAVE_BYTESWAP_H = t.os.tag == .linux,
        .HAVE_ENDIAN_H = t.os.tag == .linux,
        .HAVE_DLFCN_H = posix,
        .HAVE_INTTYPES_H = true,
        .HAVE_STDINT_H = true,
        .HAVE_STDLIB_H = true,
        .HAVE_STDBOOL_H = true,
        .HAVE_STRING_H = true,
        .HAVE_STRINGS_H = posix,
        .HAVE_MEMORY_H = true,
        .HAVE_LOCALE_H = true,
        .HAVE_SYS_STAT_H = true,
        .HAVE_SYS_TIME_H = posix,
        .HAVE_SYS_TYPES_H = true,
        .HAVE_SYS_WAIT_H = posix,
        .HAVE_UNISTD_H = posix,
        .HAVE_DIRECT_H = false,
        .HAVE_IO_H = false,
        .HAVE_IMMINTRIN_H = t.cpu.arch.isX86(),
        .USE_SSE2 = false,

        .OS_IS_WIN32 = !posix,
        .USE_WINDOWS_API = !posix,
        .WIN32_TARGET_DLL = false,
        .OS_IS_OPENBSD = t.os.tag == .openbsd,
        .OSX_DARWIN_VERSION = @as(i64, if (t.os.tag.isDarwin()) 1 else 0),
        ._MINIX = false,
    });

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });
    mod.addConfigHeader(config_h);
    mod.addIncludePath(upstream.path("include"));
    mod.addIncludePath(upstream.path("src"));

    mod.linkLibrary(xiph.ogg);
    mod.linkLibrary(xiph.vorbis);
    mod.linkLibrary(xiph.flac);
    mod.linkLibrary(xiph.opus);

    mod.addCMacro("HAVE_CONFIG_H", "");
    mod.addCMacro("FLAC__NO_DLL", "");

    mod.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = &sources.core,
        .flags = &.{
            "-std=gnu99",
            "-Wno-unused-parameter",
            "-Wno-sign-compare",
            "-Wno-unused-but-set-variable",
        },
        .language = .c,
    });

    const lib = b.addLibrary(.{ .name = "sndfile", .root_module = mod, .linkage = .static });
    lib.installHeader(upstream.path("include/sndfile.h"), "sndfile.h");
    lib.installHeader(upstream.path("include/sndfile.hh"), "sndfile.hh");
    return lib;
}
