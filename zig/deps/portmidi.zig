//! Builds PortMidi from upstream source.
//!
//! Used by MUSIC/portmidiplayer.c to drive external MIDI hardware/synths.
//! Unlike the codec libraries this one is inherently platform-bound: it talks
//! to CoreMIDI on macOS, ALSA sequencer on Linux and winmm on Windows, so the
//! backend it needs is a system library whichever it is (as with OpenGL).

const std = @import("std");

pub fn build(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const t = target.result;

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });
    mod.addIncludePath(upstream.path("pm_common"));
    mod.addIncludePath(upstream.path("porttime"));

    // Portable core, from pm_common/CMakeLists.txt PM_LIB_PUBLIC_SRC.
    var files: std.ArrayList([]const u8) = .empty;
    files.appendSlice(b.allocator, &.{
        "pm_common/portmidi.c",
        "pm_common/pmutil.c",
        "porttime/porttime.c",
    }) catch @panic("OOM");

    if (t.os.tag.isDarwin()) {
        files.appendSlice(b.allocator, &.{
            "porttime/ptmacosx_mach.c",
            "pm_mac/pmmac.c",
            "pm_mac/pmmacosxcm.c",
            "pm_mac/finddefault.c",
            "pm_mac/readbinaryplist.c",
        }) catch @panic("OOM");
        // CoreServices is missing from upstream's CMakeLists but is required:
        // readbinaryplist.c calls FSFindFolder/FSRefMakePath. CMake builds get
        // away with it because something else in the link pulls CoreServices
        // in; linking portmidi on its own does not.
        for ([_][]const u8{ "CoreAudio", "CoreFoundation", "CoreMIDI", "CoreServices" }) |fw| {
            mod.linkFramework(fw, .{});
        }
    } else if (t.os.tag == .linux) {
        files.appendSlice(b.allocator, &.{
            "porttime/ptlinux.c",
            "pm_linux/pmlinux.c",
            "pm_linux/pmlinuxnull.c",
            "pm_linux/pmlinuxalsa.c",
            "pm_linux/finddefault.c",
        }) catch @panic("OOM");
        mod.addCMacro("PMALSA", "1");
        // ALSA is the kernel's sound API on Linux; like OpenGL it comes from
        // the system rather than being vendored.
        mod.linkSystemLibrary("asound", .{ .use_pkg_config = .no });
    } else if (t.os.tag == .windows) {
        files.appendSlice(b.allocator, &.{
            "porttime/ptwinmm.c",
            "pm_win/pmwin.c",
            "pm_win/pmwinmm.c",
        }) catch @panic("OOM");
        // No PMALSA equivalent to select a backend here: winmm is the only one
        // upstream has for Windows. It ships with the OS, so unlike the codecs
        // there is nothing to vendor.
        mod.linkSystemLibrary("winmm", .{ .use_pkg_config = .no });
    } else {
        std.debug.panic("portmidi: unsupported target {s}", .{@tagName(t.os.tag)});
    }

    mod.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = files.items,
        .flags = &.{ "-std=gnu99", "-Wno-unused-parameter" },
        .language = .c,
    });

    const lib = b.addLibrary(.{ .name = "portmidi", .root_module = mod, .linkage = .static });
    lib.installHeader(upstream.path("pm_common/portmidi.h"), "portmidi.h");
    lib.installHeader(upstream.path("porttime/porttime.h"), "porttime.h");
    return lib;
}
