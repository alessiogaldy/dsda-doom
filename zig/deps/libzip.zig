//! Builds libzip from upstream source.
//!
//! There is an allyourcodebase/libzip package, but it cannot be used on Zig
//! 0.16: it pins zlib 1.3.1, whose manifest predates the enum-literal `.name`
//! syntax, and it is a single commit from 2025-07 with no newer branch. So we
//! build upstream directly instead, which is also the pattern the remaining
//! unpackaged dependencies will follow.
//!
//! Deflate only. dsda uses libzip purely to read zip archives
//! (prboom2/src/dsda/zipfile.c), so bzip2/lzma/zstd/crypto are all left out.

const std = @import("std");
const sources = @import("libzip_sources.zig");

const version = "1.11.2";
const version_major = 1;
const version_minor = 11;
const version_patch = 2;

pub fn build(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zlib: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const t = target.result;
    const posix = t.os.tag != .windows;
    const mingw = t.os.tag == .windows and t.abi == .gnu;

    // zipconf.h is the public header; zip.h includes it.
    const zipconf_h = b.addConfigHeader(.{
        .style = .{ .cmake = upstream.path("zipconf.h.in") },
        .include_path = "zipconf.h",
    }, .{
        .libzip_VERSION = version,
        .libzip_VERSION_MAJOR = version_major,
        .libzip_VERSION_MINOR = version_minor,
        .libzip_VERSION_PATCH = version_patch,
        .ZIP_STATIC = true,
        // Upstream emits fallback no-op defines when the compiler lacks
        // _Nullable; clang has it, so HAVE_NULLABLE is set and this is empty.
        .ZIP_NULLABLE_DEFINES = "",
        .LIBZIP_TYPES_INCLUDE = "#include <stdint.h>",
        .ZIP_INT8_T = "int8_t",
        .ZIP_UINT8_T = "uint8_t",
        .ZIP_INT16_T = "int16_t",
        .ZIP_UINT16_T = "uint16_t",
        .ZIP_INT32_T = "int32_t",
        .ZIP_UINT32_T = "uint32_t",
        .ZIP_INT64_T = "int64_t",
        .ZIP_UINT64_T = "uint64_t",
    });

    // Upstream probes all of these with check_function_exists. As with
    // dsda's own config.h, they become properties of the target here.
    const config_h = b.addConfigHeader(.{
        .style = .{ .cmake = upstream.path("config.h.in") },
        .include_path = "config.h",
    }, .{
        .PACKAGE = "libzip",
        .VERSION = version,
        .CMAKE_PROJECT_NAME = "libzip",
        .CMAKE_PROJECT_VERSION = version,

        .ENABLE_FDOPEN = posix,
        .HAVE_FDOPEN = posix,
        .HAVE_FILENO = posix,
        // mingw provides fseeko/ftello even though the rest of the POSIX
        // surface is absent. Getting these wrong makes libzip's compat.h
        // define them as macros, which then collide with mingw's own
        // declarations in stdio.h.
        .HAVE_FSEEKO = posix or mingw,
        .HAVE_FTELLO = posix or mingw,
        .HAVE_FCHMOD = posix,
        .HAVE_MKSTEMP = posix,
        .HAVE_STRCASECMP = posix,
        .HAVE_STRDUP = true,
        .HAVE_SNPRINTF = true,
        .HAVE_STRTOLL = true,
        .HAVE_STRTOULL = true,
        .HAVE_LOCALTIME_R = posix,
        .HAVE_STRUCT_TM_TM_ZONE = posix,
        .HAVE_STDBOOL_H = true,
        .HAVE_STRINGS_H = posix,
        .HAVE_UNISTD_H = posix,
        .HAVE_DIRENT_H = posix,
        .HAVE_NULLABLE = true,
        .HAVE_ARC4RANDOM = t.os.tag.isDarwin() or t.os.tag.isBSD(),
        .HAVE_GETPROGNAME = t.os.tag.isDarwin() or t.os.tag.isBSD(),
        .HAVE_CLONEFILE = t.os.tag.isDarwin(),
        .HAVE_FICLONERANGE = t.os.tag == .linux,
        .HAVE___PROGNAME = t.os.tag == .linux,

        .SIZEOF_OFF_T = @as(i64, if (posix) 8 else 4),
        .SIZEOF_SIZE_T = @as(i64, @divExact(t.ptrBitWidth(), 8)),
        .WORDS_BIGENDIAN = t.cpu.arch.endian() == .big,

        // Deflate only, and no encryption: dsda just reads archives.
        .HAVE_LIBBZ2 = false,
        .HAVE_LIBLZMA = false,
        .HAVE_LIBZSTD = false,
        .HAVE_CRYPTO = false,
        .HAVE_COMMONCRYPTO = false,
        .HAVE_GNUTLS = false,
        .HAVE_OPENSSL = false,
        .HAVE_MBEDTLS = false,
        .HAVE_WINDOWS_CRYPTO = false,
        .HAVE_SHARED = false,

        // Windows / MSVC-only spellings.
        .HAVE__CLOSE = false,
        .HAVE__DUP = false,
        .HAVE__FDOPEN = false,
        .HAVE__FILENO = false,
        .HAVE__FSEEKI64 = false,
        .HAVE__FSTAT64 = false,
        .HAVE__SETMODE = false,
        .HAVE__SNPRINTF = false,
        .HAVE__SNPRINTF_S = false,
        .HAVE__SNWPRINTF_S = false,
        .HAVE__STAT64 = false,
        .HAVE__STRDUP = false,
        .HAVE__STRICMP = false,
        .HAVE__STRTOI64 = false,
        .HAVE__STRTOUI64 = false,
        .HAVE__UNLINK = false,
        .HAVE_SETMODE = false,
        .HAVE_STRICMP = false,
        .HAVE_SNPRINTF_S = false,
        .HAVE_MEMCPY_S = false,
        .HAVE_LOCALTIME_S = false,
        .HAVE_STRERROR_S = false,
        .HAVE_STRERRORLEN_S = false,
        .HAVE_STRNCPY_S = false,
        .HAVE_FTS_H = false,
        .HAVE_NDIR_H = false,
        .HAVE_SYS_DIR_H = false,
        .HAVE_SYS_NDIR_H = false,
    });

    // zip_err_str.c is derived from comments in zip.h / zipint.h; upstream
    // generates it with a CMake script, we use an equivalent host tool.
    const gen = b.addExecutable(.{
        .name = "gen_zip_err_str",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/tools/gen_zip_err_str.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run_gen = b.addRunArtifact(gen);
    run_gen.addFileArg(upstream.path("lib/zip.h"));
    run_gen.addFileArg(upstream.path("lib/zipint.h"));
    const zip_err_str = run_gen.addOutputFileArg("zip_err_str.c");

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });
    mod.addConfigHeader(zipconf_h);
    mod.addConfigHeader(config_h);
    mod.addIncludePath(upstream.path("lib"));
    mod.linkLibrary(zlib);

    const flags = [_][]const u8{ "-std=gnu99", "-DHAVE_CONFIG_H" };
    mod.addCSourceFiles(.{
        .root = upstream.path("lib"),
        .files = &sources.core,
        .flags = &flags,
        .language = .c,
    });
    if (posix) mod.addCSourceFiles(.{
        .root = upstream.path("lib"),
        .files = &sources.unix,
        .flags = &flags,
        .language = .c,
    });
    mod.addCSourceFile(.{ .file = zip_err_str, .flags = &flags, .language = .c });

    const lib = b.addLibrary(.{ .name = "zip", .root_module = mod, .linkage = .static });
    // dsda does `#include <zip.h>`, which pulls in zipconf.h.
    lib.installHeader(upstream.path("lib/zip.h"), "zip.h");
    lib.installConfigHeader(zipconf_h);
    return lib;
}
