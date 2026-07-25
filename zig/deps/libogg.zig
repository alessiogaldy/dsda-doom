//! Builds libogg from upstream xiph/ogg source.
//!
//! Tiny: two source files plus a generated config_types.h that just picks
//! which integer typedefs to use. Upstream resolves those with autoconf/CMake
//! probes; since Zig always provides stdint.h, they are fixed here.

const std = @import("std");

pub fn build(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const config_types_h = b.addConfigHeader(.{
        .style = .{ .autoconf_at = upstream.path("include/ogg/config_types.h.in") },
        .include_path = "ogg/config_types.h",
    }, .{
        .INCLUDE_INTTYPES_H = @as(i64, 1),
        .INCLUDE_STDINT_H = @as(i64, 1),
        .INCLUDE_SYS_TYPES_H = @as(i64, if (target.result.os.tag == .windows) 0 else 1),
        .SIZE16 = "int16_t",
        .USIZE16 = "uint16_t",
        .SIZE32 = "int32_t",
        .USIZE32 = "uint32_t",
        .SIZE64 = "int64_t",
        .USIZE64 = "uint64_t",
    });

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });
    mod.addConfigHeader(config_types_h);
    mod.addIncludePath(upstream.path("include"));
    mod.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = &.{ "bitwise.c", "framing.c" },
        .flags = &.{"-std=gnu99"},
        .language = .c,
    });

    const lib = b.addLibrary(.{ .name = "ogg", .root_module = mod, .linkage = .static });
    lib.installHeader(upstream.path("include/ogg/ogg.h"), "ogg/ogg.h");
    lib.installHeader(upstream.path("include/ogg/os_types.h"), "ogg/os_types.h");
    lib.installConfigHeader(config_types_h);
    return lib;
}
