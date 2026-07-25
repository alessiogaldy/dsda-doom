//! Zig build for dsda-doom.
//!
//! This lives alongside the CMake build (rooted at prboom2/) rather than
//! replacing it. Both must stay in sync until CMake is retired, so the source
//! group names in zig/sources.zig deliberately mirror the CMake variables.
//!
//! Stage 1: every dependency is resolved from the system via pkg-config, which
//! is what the CMake Find*.cmake modules do too. Later stages swap individual
//! libraries over to the Zig package manager.

const std = @import("std");
const sources = @import("zig/sources.zig");
const wad_data = @import("zig/wad_data.zig");
const libzip = @import("zig/deps/libzip.zig");
const libogg = @import("zig/deps/libogg.zig");
const libvorbis = @import("zig/deps/libvorbis.zig");
const libmad = @import("zig/deps/libmad.zig");
const libxmp = @import("zig/deps/libxmp.zig");
const portmidi = @import("zig/deps/portmidi.zig");
const opus = @import("zig/deps/opus.zig");
const flac = @import("zig/deps/flac.zig");
const libsndfile = @import("zig/deps/libsndfile.zig");
const sdl2_mixer = @import("zig/deps/sdl2_mixer.zig");

const version = "0.29.4";
const project_name = "dsda-doom";
const wad_name = "dsda-doom.wad";

/// Warnings shared by C and C++, from prboom2/cmake/DsdaTargetFeatures.cmake.
const common_warnings = [_][]const u8{
    "-Wall",
    "-Wwrite-strings",
    "-Wundef",
    "-Wtype-limits",
    "-Wcast-qual",
    "-Wpointer-arith",
    "-Wno-unused-function",
    "-Wno-switch",
    "-Wno-sign-compare",
    "-Wno-missing-field-initializers",
    "-Wno-format-truncation",
    "-Wno-tautological-constant-out-of-range-compare",
    "-Wno-tautological-unsigned-enum-zero-compare",
    "-Wno-misleading-indentation",
};

/// Warnings CMake applies only under $<COMPILE_LANGUAGE:C>.
const c_only_warnings = [_][]const u8{
    "-Wabsolute-value",
    "-Wno-pointer-sign",
    "-Wdeclaration-after-statement",
    "-Wbad-function-cast",
    "-Wno-strict-prototypes",
};

const c_base_flags = [_][]const u8{"-std=gnu99"} ++ common_warnings ++ c_only_warnings;

// CMake emits no -std for C++: cxx_std_11 is already satisfied by the compiler
// default, so the faithful reproduction is to leave the default alone.
const cxx_base_flags = common_warnings;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const t = target.result;

    // Mirrors the WITH_* options in prboom2/cmake/DsdaDepsSetup.cmake.
    const with_image = b.option(bool, "with-image", "SDL2_image support (screenshots)") orelse true;
    const with_mad = b.option(bool, "with-mad", "libmad MP3 support") orelse true;
    const with_fluidsynth = b.option(bool, "with-fluidsynth", "FluidSynth MIDI support") orelse true;
    const with_xmp = b.option(bool, "with-xmp", "libxmp tracker module support") orelse true;
    const with_vorbisfile = b.option(bool, "with-vorbisfile", "Ogg Vorbis support") orelse true;
    const with_portmidi = b.option(bool, "with-portmidi", "PortMidi MIDI support") orelse true;

    // CMake applies -ffast-math unconditionally (DsdaTargetFeatures.cmake only
    // probes whether the compiler accepts it). It licenses the optimiser to
    // reassociate float expressions and contract them into FMAs, so the exact
    // results depend on the compiler build and optimisation level -- which is
    // why demo sync differs between toolchains at all. Exposed so that can be
    // measured rather than guessed at.
    const fast_math = b.option(bool, "fast-math", "Enable -ffast-math (matches CMake)") orelse true;

    // Mirrors SIMPLECHECKS / RANGECHECK in prboom2/cmake/DsdaOptions.cmake.
    const simplechecks = b.option(bool, "simplechecks", "Enable inexpensive sanity checks") orelse true;
    const rangecheck = b.option(bool, "rangecheck", "Enable expensive range-checking") orelse false;

    const posix = t.os.tag != .windows;

    // Decided here rather than inside linkDependencies because config.h has to
    // agree with which libsndfile actually gets linked.
    const sys_sndfile = b.systemIntegrationOption("sndfile", .{ .default = false });

    // The wad is installed next to the binary because I_FindFileInternal
    // (prboom2/src/SDL/i_system.c) searches I_ExeDir first. This replaces
    // CMake's POST_BUILD copy_if_different.
    const wad_dir = b.pathJoin(&.{ b.install_prefix, "bin" });

    const config_h = b.addConfigHeader(.{
        .style = .{ .cmake = b.path("prboom2/cmake/config.h.cin") },
        .include_path = "config.h",
    }, .{
        .PROJECT_NAME = project_name,
        .PROJECT_TARNAME = project_name,
        .WAD_DATA = wad_name,
        .PROJECT_VERSION = version,
        .PROJECT_STRING = project_name ++ " " ++ version,
        .DOOMWADDIR = wad_dir,
        .DSDA_ABSOLUTE_PWAD_PATH = wad_dir,

        .WORDS_BIGENDIAN = t.cpu.arch.endian() == .big,

        // CMake discovers these with check_symbol_exists/check_include_file at
        // configure time. Zig has no configure step, so they become properties
        // of the target -- which is also what makes cross-compilation work.
        .HAVE_GETOPT = posix,
        .HAVE_MMAP = posix,
        .HAVE_CREATE_FILE_MAPPING = !posix,
        .HAVE_STRSIGNAL = posix,
        .HAVE_MKSTEMP = posix,
        .HAVE_GETPWUID = posix,
        .HAVE_SYS_WAIT_H = posix,
        .HAVE_UNISTD_H = posix,
        .HAVE_ASM_BYTEORDER_H = t.os.tag == .linux,
        .HAVE_DIRENT_H = posix,

        .HAVE_LIBSDL2_IMAGE = with_image,
        .HAVE_LIBMAD = with_mad,
        .HAVE_LIBFLUIDSYNTH = with_fluidsynth,
        .HAVE_LIBXMP = with_xmp,
        .HAVE_LIBVORBISFILE = with_vorbisfile,
        .HAVE_LIBPORTMIDI = with_portmidi,
        // Our libsndfile build has no MPEG support (that needs mpg123 and
        // LAME); the system one usually does. MP3 *music* is unaffected --
        // that goes through libmad -- this is only MP3 sound effects.
        .HAVE_SNDFILE_MPEG = if (sys_sndfile) systemSndfileHasMpeg(b) else libsndfile.has_mpeg,

        .SIMPLECHECKS = simplechecks,
        .RANGECHECK = rangecheck,
    });

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // scanner.cpp, umapinfo.cpp and four dsda/*.cpp files.
        .link_libcpp = true,
        // Doom relies on signed overflow, misaligned reads and type punning by
        // design, and -ffast-math makes float checks meaningless. Zig turns
        // UBSan on for C by default in Debug/ReleaseSafe; leaving it on traps
        // during startup.
        .sanitize_c = .off,
        // CMake adds this globally via DsdaSanitiser.cmake.
        .omit_frame_pointer = false,
    });

    // Load-bearing beyond the listed sources: icon.c and the three r_draw*.inl
    // files are #included by name and resolve only through this include path.
    mod.addIncludePath(b.path("prboom2/src"));
    mod.addConfigHeader(config_h);

    mod.addCMacro("HAVE_CONFIG_H", "");
    // CMake defines these whenever check_symbol_exists fails to find the MSVC
    // spellings, i.e. everywhere except Windows.
    mod.addCMacro("stricmp", "strcasecmp");
    mod.addCMacro("strnicmp", "strncasecmp");
    if (t.os.tag.isDarwin()) mod.addCMacro("GL_SILENCE_DEPRECATION", "");

    const math_flags: []const []const u8 = if (fast_math) &.{"-ffast-math"} else &.{};
    const c_flags = b.allocator.alloc([]const u8, c_base_flags.len + math_flags.len) catch @panic("OOM");
    @memcpy(c_flags[0..c_base_flags.len], &c_base_flags);
    @memcpy(c_flags[c_base_flags.len..], math_flags);
    const cxx_flags = b.allocator.alloc([]const u8, cxx_base_flags.len + math_flags.len) catch @panic("OOM");
    @memcpy(cxx_flags[0..cxx_base_flags.len], &cxx_base_flags);
    @memcpy(cxx_flags[cxx_base_flags.len..], math_flags);

    const wad_backend = if (posix) &sources.w_mmap else &sources.w_memcache;
    const c_files = sources.common_c ++ sources.net_client_c ++ sources.mus2mid_c ++
        sources.sdl_c ++ sources.music_c ++ sources.gl_c;

    // CMake compiles 244 objects for this target. If an upstream merge adds a
    // source to prboom2/src/CMakeLists.txt without adding it to zig/sources.zig,
    // this is the tripwire.
    comptime std.debug.assert(c_files.len + sources.common_cpp.len + 1 == 244);

    mod.addCSourceFiles(.{
        .root = b.path("prboom2/src"),
        .files = &c_files,
        .flags = c_flags,
        .language = .c,
    });
    mod.addCSourceFiles(.{
        .root = b.path("prboom2/src"),
        .files = wad_backend,
        .flags = c_flags,
        .language = .c,
    });
    mod.addCSourceFiles(.{
        .root = b.path("prboom2/src"),
        .files = &sources.common_cpp,
        .flags = cxx_flags,
        .language = .cpp,
    });

    const vendored = linkDependencies(b, mod, t, target, optimize, .{
        .image = with_image,
        .mad = with_mad,
        .fluidsynth = with_fluidsynth,
        .xmp = with_xmp,
        .vorbisfile = with_vorbisfile,
        .portmidi = with_portmidi,
        .sys_sndfile = sys_sndfile,
    });

    const exe = b.addExecutable(.{ .name = project_name, .root_module = mod });

    // Off by default, unlike the CMake build dir which has
    // CMAKE_INTERPROCEDURAL_OPTIMIZATION=ON. ThinLTO combined with -ffast-math
    // lets the optimiser contract float operations across translation units,
    // which changes renderer/physics results and desyncs demos -- notably
    // heretic e1 (spec/sync_spec.rb:58), which the CMake build fails and this
    // one passes. Exposed so that difference stays testable.
    if (b.option(bool, "lto", "Enable ThinLTO (desyncs demos; for parity testing only)") orelse false) {
        exe.lto = .thin;
    }

    b.installArtifact(exe);

    const wad = buildWad(b);
    b.getInstallStep().dependOn(&b.addInstallBinFile(wad, wad_name).step);

    // Lets `zig build verify-config` diff against build/build-config/config.h.
    const install_config = b.addInstallFile(config_h.getOutputFile(), "config.h");
    b.step("config-header", "Install the generated config.h for comparison")
        .dependOn(&install_config.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Build and run dsda-doom").dependOn(&run.step);

    // Smoke-tests for vendored libraries. The demo suites cover none of them:
    // they run -nosound -nomusic and only open plain .wad files, so a broken
    // vendored library can still pass all 1105 demos.
    const check_deps = b.step("check-deps", "Smoke-test vendored dependencies");
    if (vendored.any()) {
        const checker = b.addExecutable(.{
            .name = "check_deps",
            .root_module = b.createModule(.{
                .root_source_file = b.path("zig/tools/check_deps.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_checks = b.addRunArtifact(checker);
        if (vendored.vorbisfile) |lib| {
            checker.root_module.linkLibrary(lib);
            run_checks.addPrefixedFileArg("vorbis:", b.path("zig/testdata/sine.ogg"));
        }
        if (vendored.mad) |lib| {
            checker.root_module.linkLibrary(lib);
            run_checks.addPrefixedFileArg("mad:", b.path("zig/testdata/sine.mp3"));
        }
        if (vendored.xmp) |lib| {
            checker.root_module.linkLibrary(lib);
            run_checks.addPrefixedFileArg("xmp:", b.path("zig/testdata/square.mod"));
        }
        if (vendored.portmidi) |lib| {
            checker.root_module.linkLibrary(lib);
            run_checks.addArg("portmidi:-");
        }
        if (vendored.sndfile) |lib| {
            checker.root_module.linkLibrary(lib);
            // One per container so a codec that failed to wire up is visible.
            for ([_][]const u8{ "sine.wav", "sine.flac", "sine.ogg" }) |f| {
                run_checks.addPrefixedFileArg("sndfile:", b.path(b.fmt("zig/testdata/{s}", .{f})));
            }
        }

        check_deps.dependOn(&run_checks.step);
    }

    // The demo regression suite in spec/. This is the real correctness check:
    // a build-system change that perturbs float codegen shows up as a desync.
    const spec = b.addSystemCommand(&.{"rspec"});
    spec.setEnvironmentVariable("DSDA_DOOM", b.pathJoin(&.{ b.install_prefix, "bin", project_name }));
    spec.has_side_effects = true; // writes analysis.txt / levelstat.txt into cwd
    spec.step.dependOn(b.getInstallStep());
    if (b.args) |args| spec.addArgs(args);
    b.step("spec", "Run the rspec demo regression suite").dependOn(&spec.step);
}

/// Artifacts built from source, exposed so `zig build check-deps` can smoke-test
/// them. Null means the library came from the system instead.
const Vendored = struct {
    vorbisfile: ?*std.Build.Step.Compile = null,
    mad: ?*std.Build.Step.Compile = null,
    xmp: ?*std.Build.Step.Compile = null,
    portmidi: ?*std.Build.Step.Compile = null,
    sndfile: ?*std.Build.Step.Compile = null,
    sdl2_mixer: ?*std.Build.Step.Compile = null,

    fn any(v: Vendored) bool {
        return v.vorbisfile != null or v.mad != null or v.xmp != null or v.portmidi != null or v.sndfile != null or v.sdl2_mixer != null;
    }
};

const Features = struct {
    image: bool,
    mad: bool,
    fluidsynth: bool,
    xmp: bool,
    vorbisfile: bool,
    portmidi: bool,
    sys_sndfile: bool,
};

/// Each library is either built from source by the Zig package manager or
/// resolved from the system, switchable per library with `-fsys=<name>` /
/// `-fno-sys=<name>`. Libraries with no in-tree build yet default to system.
///
/// Note SDL2, SDL2_image and SDL2_mixer must move to vendored *together*: a
/// vendored SDL2 beside a system SDL2_mixer would put two SDL2 copies with
/// independent global state in one process, because SDL2_mixer binds its SDL2
/// by absolute path.
fn linkDependencies(
    b: *std.Build,
    mod: *std.Build.Module,
    t: std.Target,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    features: Features,
) Vendored {
    var vendored: Vendored = .{};

    // OpenGL and GLU are the driver ABI and can never be vendored, and neither
    // ships a .pc file, so they are handled outside pkg-config.
    if (t.os.tag.isDarwin()) {
        // GLU lives inside the framework on macOS, which is why CMake ends up
        // emitting -framework OpenGL twice.
        mod.linkFramework("OpenGL", .{});
    } else {
        mod.linkSystemLibrary("GL", .{ .use_pkg_config = .no });
        mod.linkSystemLibrary("GLU", .{ .use_pkg_config = .no });
    }

    var packages: std.ArrayList([]const u8) = .empty;

    // Vendored by default; `-fsys=<name>` falls back to the system copy.
    const dep_args = .{ .target = target, .optimize = optimize };

    const sys_zlib = b.systemIntegrationOption("zlib", .{ .default = false });
    const sys_libzip = b.systemIntegrationOption("libzip", .{ .default = false });

    // libzip needs zlib as a library artifact, so resolve zlib first and reuse
    // it for both. If zlib is system-provided we can't hand an artifact to the
    // libzip build, so libzip has to come from the system too.
    var zlib_lib: ?*std.Build.Step.Compile = null;
    if (sys_zlib) {
        packages.append(b.allocator, "zlib") catch @panic("OOM");
    } else {
        zlib_lib = b.dependency("zlib", dep_args).artifact("z");
        mod.linkLibrary(zlib_lib.?);
    }

    if (sys_libzip or zlib_lib == null) {
        packages.append(b.allocator, "libzip") catch @panic("OOM");
    } else {
        const upstream = b.dependency("libzip_upstream", .{});
        mod.linkLibrary(libzip.build(b, upstream, target, optimize, zlib_lib.?));
    }

    // libogg is shared by libvorbis, FLAC and libsndfile. Build it once so
    // there is a single copy of the symbols in the link.
    const ogg_lib = libogg.build(b, b.dependency("libogg_upstream", .{}), target, optimize);
    const vorbis_lib = libvorbis.build(b, b.dependency("libvorbis_upstream", .{}), target, optimize, ogg_lib);

    if (features.vorbisfile) {
        if (b.systemIntegrationOption("vorbisfile", .{ .default = false })) {
            packages.append(b.allocator, "vorbisfile") catch @panic("OOM");
        } else {
            vendored.vorbisfile = vorbis_lib;
            mod.linkLibrary(vorbis_lib);
        }
    }

    if (features.sys_sndfile) {
        packages.append(b.allocator, "sndfile") catch @panic("OOM");
    } else {
        vendored.sndfile = libsndfile.build(b, b.dependency("libsndfile_upstream", .{}), target, optimize, .{
            .ogg = ogg_lib,
            .vorbis = vorbis_lib,
            .flac = flac.build(b, b.dependency("flac_upstream", .{}), target, optimize, ogg_lib),
            .opus = opus.build(b, b.dependency("opus_upstream", .{}), target, optimize),
        });
        mod.linkLibrary(vendored.sndfile.?);
    }

    if (features.mad) {
        if (b.systemIntegrationOption("mad", .{ .default = false })) {
            packages.append(b.allocator, "mad") catch @panic("OOM");
        } else {
            vendored.mad = libmad.build(b, b.dependency("libmad_upstream", .{}), target, optimize);
            mod.linkLibrary(vendored.mad.?);
        }
    }

    // The optional backends' .c files are always compiled -- they self-stub via
    // #ifdef -- so only the link and the HAVE_LIB* define are conditional.
    if (features.fluidsynth) packages.append(b.allocator, "fluidsynth") catch @panic("OOM");
    if (features.xmp) {
        if (b.systemIntegrationOption("libxmp", .{ .default = false })) {
            packages.append(b.allocator, "libxmp") catch @panic("OOM");
        } else {
            vendored.xmp = libxmp.build(b, b.dependency("libxmp_upstream", .{}), target, optimize);
            mod.linkLibrary(vendored.xmp.?);
        }
    }

    // SDL2, SDL2_image and SDL2_mixer move as a unit. SDL2_mixer binds its
    // SDL2 at link time, so mixing a vendored SDL2 with a system SDL2_mixer
    // (or vice versa) puts two SDL2 copies with independent global state in
    // one process: separate event queues, separate audio subsystems.
    const sys_sdl = b.systemIntegrationOption("sdl2", .{ .default = false });
    if (sys_sdl) {
        packages.append(b.allocator, "sdl2") catch @panic("OOM");
        packages.append(b.allocator, "SDL2_mixer") catch @panic("OOM");
        if (features.image) packages.append(b.allocator, "SDL2_image") catch @panic("OOM");
    } else {
        const dep_opts = .{ .target = target, .optimize = optimize };
        const sdl_dep = b.dependency("sdl2", dep_opts);
        const sdl_lib = sdl_dep.artifact("SDL2");
        mod.linkLibrary(sdl_lib);
        // dsda includes "SDL.h" flat, but the package installs headers under
        // an SDL2/ subdirectory.
        mod.addIncludePath(sdl_lib.getEmittedIncludeTree().path(b, "SDL2"));

        vendored.sdl2_mixer = sdl2_mixer.build(
            b,
            b.dependency("sdl2_mixer_upstream", .{}),
            target,
            optimize,
            sdl_lib,
            vendored.xmp,
        );
        mod.linkLibrary(vendored.sdl2_mixer.?);

        if (features.image) {
            const img_lib = b.dependency("sdl2_image", dep_opts).artifact("SDL2_image");
            mod.linkLibrary(img_lib);
            // Installed as SDL2/SDL_image.h, but dsda includes it flat.
            mod.addIncludePath(img_lib.getEmittedIncludeTree().path(b, "SDL2"));
        }
    }
    if (features.portmidi) {
        if (b.systemIntegrationOption("portmidi", .{ .default = false })) {
            packages.append(b.allocator, "portmidi") catch @panic("OOM");
        } else {
            vendored.portmidi = portmidi.build(b, b.dependency("portmidi_upstream", .{}), target, optimize);
            mod.linkLibrary(vendored.portmidi.?);
        }
    }

    addPkgConfig(b, mod, packages.items);
    return vendored;
}

/// Resolves every package in a *single* pkg-config invocation and applies the
/// result by hand, rather than calling linkSystemLibrary once per library.
///
/// This is not premature cleverness: sdl2, SDL2_mixer and SDL2_image each emit
/// `-lSDL2`, and linking them separately makes the linker write three
/// LC_LOAD_DYLIB entries for the same dylib. macOS dyld rejects that outright
/// ("duplicate linked dylib") and the binary will not start. Passing all the
/// package names to pkg-config at once makes pkg-config do the deduplication.
fn addPkgConfig(b: *std.Build, mod: *std.Build.Module, packages: []const []const u8) void {
    // pkg-config only knows about the host. When cross-compiling it happily
    // returns host include and library paths, which would silently produce a
    // binary linked against the wrong architecture's libraries. Fail loudly
    // instead, naming what still needs an in-tree build.
    if (!mod.resolved_target.?.query.isNative()) {
        std.debug.panic(
            "cross-compiling, but these dependencies still resolve via pkg-config: {s}\n" ++
                "pkg-config reports host paths, so the result would be linked against the " ++
                "wrong target. Vendor them (zig/deps/) or pass -fsys= only on a native build.",
            .{std.mem.join(b.allocator, " ", packages) catch "?"},
        );
    }

    for ([_][]const u8{ "--cflags", "--libs" }) |mode| {
        var argv: std.ArrayList([]const u8) = .empty;
        argv.appendSlice(b.allocator, &.{ "pkg-config", mode }) catch @panic("OOM");
        argv.appendSlice(b.allocator, packages) catch @panic("OOM");

        var code: u8 = undefined;
        const out = b.runAllowFail(argv.items, &code, .ignore) catch |err| {
            std.debug.panic(
                "pkg-config {s} failed for [{s}]: {s}\n" ++
                    "Install the dependencies first (macOS: `brew bundle`).",
                .{ mode, b.fmt("{s}", .{std.mem.join(b.allocator, " ", packages) catch "?"}), @errorName(err) },
            );
        };

        var it = std.mem.tokenizeAny(u8, out, " \t\r\n");
        while (it.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "-I")) {
                mod.addSystemIncludePath(.{ .cwd_relative = b.dupe(arg[2..]) });
            } else if (std.mem.startsWith(u8, arg, "-L")) {
                mod.addLibraryPath(.{ .cwd_relative = b.dupe(arg[2..]) });
            } else if (std.mem.startsWith(u8, arg, "-l")) {
                mod.linkSystemLibrary(b.dupe(arg[2..]), .{ .use_pkg_config = .no });
            } else if (std.mem.startsWith(u8, arg, "-D")) {
                const body = arg[2..];
                if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
                    mod.addCMacro(b.dupe(body[0..eq]), b.dupe(body[eq + 1 ..]));
                } else {
                    mod.addCMacro(b.dupe(body), "");
                }
            } else if (std.mem.startsWith(u8, arg, "-Wl,-framework,")) {
                mod.linkFramework(b.dupe(arg["-Wl,-framework,".len..]), .{});
            } else if (std.mem.eql(u8, arg, "-framework")) {
                if (it.next()) |fw| mod.linkFramework(b.dupe(fw), .{});
            }
            // Anything else (e.g. -pthread) is left alone deliberately: Zig
            // already handles threading, and silently forwarding unknown flags
            // is how hard-to-debug link failures start.
        }
    }
}

/// Builds the host-native rdatawad tool and runs it over the ~243 asset files
/// to produce dsda-doom.wad.
///
/// The tool must run on the *host*, not the target -- which is the entire
/// reason the CMake build needs an ExternalProject. In Zig it is one field.
fn buildWad(b: *std.Build) std.Build.LazyPath {
    const host = b.graph.host;

    const rd_mod = b.createModule(.{
        .target = host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
        .sanitize_c = .off,
    });
    rd_mod.addCMacro(
        "RD_IS_BIG_ENDIAN",
        if (host.result.cpu.arch.endian() == .big) "1" else "0",
    );
    rd_mod.addCSourceFiles(.{
        .root = b.path("prboom2/data"),
        .files = &.{
            "rd_main.c",
            "rd_util.c",
            "rd_output.c",
            "rd_sound.c",
            "rd_palette.c",
            "rd_graphic.c",
        },
        .flags = &.{"-std=gnu99"},
        .language = .c,
    });
    const rdatawad = b.addExecutable(.{ .name = "rdatawad", .root_module = rd_mod });

    const data = b.path("prboom2/data");
    const run = b.addRunArtifact(rdatawad);

    // rd_main.c is a stateful argument parser: each -switch selects a mode that
    // every following bare argument is consumed in. Order is not negotiable.
    //
    // CMake passes "-I <datadir>" plus bare filenames. We pass absolute paths
    // instead: read_or_die() fopen()s its argument directly before consulting
    // search paths, and extract_lumpname() strips to the last '/', so lump
    // names are unaffected. The payoff is that every input lands in the Run
    // step's cache manifest, which collapses CMake's two parallel lists
    // (WAD_SRC for DEPENDS, WAD_CMDLINE for the command) into one.
    run.addArg("-palette");
    addFiles(b, run, data, &wad_data.palette);
    run.addArg("-lumps");
    addFiles(b, run, data, &wad_data.lumps);

    run.addArgs(&.{ "-marker", "C_START", "-lumps" });
    addFiles(b, run, data, &wad_data.colormaps);
    run.addArgs(&.{ "-marker", "C_END" });

    run.addArgs(&.{ "-marker", "B_START", "-lumps" });
    addFiles(b, run, data, &wad_data.tables);
    run.addArgs(&.{ "-marker", "B_END" });

    run.addArg("-sounds");
    addFiles(b, run, data, &wad_data.sounds);
    run.addArg("-graphics");
    addFiles(b, run, data, &wad_data.graphics);

    run.addArgs(&.{ "-marker", "FF_START", "-flats" });
    addFiles(b, run, data, &wad_data.flats);
    run.addArgs(&.{ "-marker", "FF_END" });

    run.addArgs(&.{ "-marker", "SS_START", "-sprites" });
    for (wad_data.spritep) |s| {
        // Prefix and path become a single argv entry, which is what the
        // "x,y,file.ppm" form the tool expects requires.
        run.addPrefixedFileArg(b.fmt("{d},{d},", .{ s.x, s.y }), data.path(b, s.file));
    }
    run.addArgs(&.{ "-marker", "SS_END" });

    // Must be two argv entries: rd_main.c matches "-o" exactly, then consumes
    // the next argument as the path.
    run.addArg("-o");
    return run.addOutputFileArg(wad_name);
}

fn addFiles(
    b: *std.Build,
    run: *std.Build.Step.Run,
    root: std.Build.LazyPath,
    files: []const []const u8,
) void {
    for (files) |f| run.addFileArg(root.path(b, f));
}

/// libsndfile gained MPEG support in 1.1.0. CMake checks SndFile_VERSION; we
/// ask pkg-config the same question rather than hardcoding it, so a host with
/// an older libsndfile fails at build time instead of misbehaving at runtime.
fn systemSndfileHasMpeg(b: *std.Build) bool {
    var code: u8 = undefined;
    const out = b.runAllowFail(
        &.{ "pkg-config", "--modversion", "sndfile" },
        &code,
        .ignore,
    ) catch return false;
    const v = std.mem.trim(u8, out, " \r\n");
    var it = std.mem.splitScalar(u8, v, '.');
    const major = std.fmt.parseInt(u32, it.next() orelse return false, 10) catch return false;
    const minor = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch return false;
    return major > 1 or (major == 1 and minor >= 1);
}
