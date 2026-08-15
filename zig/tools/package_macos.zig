//! Assemble and sign the Steam-importable macOS application bundle.

const std = @import("std");
const Io = std.Io;

const Options = struct {
    executable: []const u8,
    wad: []const u8,
    icon: []const u8,
    license: []const u8,
    plist_template: []const u8,
    output: []const u8,
    dev_output: []const u8,
    game_iwad: []const u8,
    game_wad: []const u8,
    version: []const u8,
    system_sdl: bool,
};

const troubleshooting =
    \\DSDA-Doom is ad hoc signed, not notarized with an Apple Developer ID.
    \\
    \\If macOS reports that it cannot verify DSDA-Doom, run:
    \\
    \\xattr -dr com.apple.quarantine /path/to/DSDA-Doom.app
    \\
    \\To add DSDA-Doom to Steam, move DSDA-Doom.app to Applications, choose
    \\Games > Add a Non-Steam Game, and browse to the application. Steam Input
    \\can then map the Steam Controller to gamepad and mouse input.
    \\
;

const launcher_with_pwad =
    \\#!/bin/sh
    \\set -eu
    \\app_dir="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
    \\contents_dir="$app_dir/Contents"
    \\dev_wads="$(dirname -- "$app_dir")/DSDA-Doom-WADs"
    \\iwad="$dev_wads/iwad.wad"
    \\pwad="$dev_wads/selected.wad"
    \\if [ ! -f "$iwad" ] || [ ! -f "$pwad" ]; then
    \\  /usr/bin/osascript -e 'display alert "DSDA-Doom development WAD is missing" message "Check the -Dapp-iwad and -Dapp-wad paths used by zig build."' >/dev/null 2>&1 || true
    \\  exit 1
    \\fi
    \\exec "$contents_dir/MacOS/dsda-doom-bin" -iwad "$iwad" -file "$pwad" "$@"
    \\
;

const launcher_without_pwad =
    \\#!/bin/sh
    \\set -eu
    \\app_dir="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
    \\contents_dir="$app_dir/Contents"
    \\dev_wads="$(dirname -- "$app_dir")/DSDA-Doom-WADs"
    \\iwad="$dev_wads/iwad.wad"
    \\if [ ! -f "$iwad" ]; then
    \\  /usr/bin/osascript -e 'display alert "DSDA-Doom development IWAD is missing" message "Check the -Dapp-iwad path used by zig build."' >/dev/null 2>&1 || true
    \\  exit 1
    \\fi
    \\exec "$contents_dir/MacOS/dsda-doom-bin" -iwad "$iwad" "$@"
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const options = try parseOptions(args);
    const cwd = Io.Dir.cwd();

    const archive_name = std.fs.path.basename(options.output);
    if (!std.mem.endsWith(u8, archive_name, ".zip")) return error.OutputMustBeZip;
    const package_name = archive_name[0 .. archive_name.len - ".zip".len];
    const staging_root = try std.fmt.allocPrint(arena, "{s}.staging", .{options.output});
    const package_dir = try std.fs.path.join(arena, &.{ staging_root, package_name });
    const app_dir = try std.fs.path.join(arena, &.{ package_dir, "DSDA-Doom.app" });
    const contents_dir = try std.fs.path.join(arena, &.{ app_dir, "Contents" });
    const macos_dir = try std.fs.path.join(arena, &.{ contents_dir, "MacOS" });
    const resources_dir = try std.fs.path.join(arena, &.{ contents_dir, "Resources" });
    const frameworks_dir = try std.fs.path.join(arena, &.{ contents_dir, "Frameworks" });
    const app_executable = try std.fs.path.join(arena, &.{ macos_dir, "dsda-doom" });

    cwd.deleteTree(io, staging_root) catch {};
    defer cwd.deleteTree(io, staging_root) catch {};
    try cwd.createDirPath(io, macos_dir);
    try cwd.createDirPath(io, resources_dir);
    try cwd.createDirPath(io, frameworks_dir);

    try Io.Dir.copyFile(cwd, options.executable, cwd, app_executable, io, .{});
    try Io.Dir.copyFile(
        cwd,
        options.wad,
        cwd,
        try std.fs.path.join(arena, &.{ resources_dir, "dsda-doom.wad" }),
        io,
        .{},
    );
    try Io.Dir.copyFile(
        cwd,
        options.icon,
        cwd,
        try std.fs.path.join(arena, &.{ resources_dir, "dsda-doom.icns" }),
        io,
        .{},
    );
    try Io.Dir.copyFile(
        cwd,
        options.license,
        cwd,
        try std.fs.path.join(arena, &.{ resources_dir, "COPYING.txt" }),
        io,
        .{},
    );

    const plist_source = try cwd.readFileAlloc(
        io,
        options.plist_template,
        arena,
        .limited(1024 * 1024),
    );
    const plist = try std.mem.replaceOwned(
        u8,
        arena,
        plist_source,
        "@PROJECT_VERSION@",
        options.version,
    );
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ contents_dir, "Info.plist" }),
        .data = plist,
    });
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ package_dir, "Troubleshooting.txt" }),
        .data = troubleshooting,
    });

    // Default Zig builds link their vendored dependencies statically. Only
    // invoke dylibbundler when the executable actually refers to a Homebrew
    // library; this keeps the static package independent of Homebrew tooling.
    if (try hasHomebrewDependencies(arena, io, app_executable)) {
        _ = try runChecked(arena, io, &.{
            "dylibbundler",
            "--bundle-deps",
            "--create-dir",
            "--overwrite-files",
            "--fix-file",
            app_executable,
            "--install-path",
            "@executable_path/../Frameworks",
            "--dest-dir",
            frameworks_dir,
        });
        try deduplicateFrameworkRPath(arena, io, app_executable);
    }

    // Homebrew's sdl2-compat loads SDL3 at runtime, which keeps it out of the
    // executable's Mach-O dependency table and therefore invisible to
    // dylibbundler.
    if (options.system_sdl) {
        const result = try runChecked(arena, io, &.{
            "pkg-config",
            "--variable=libdir",
            "sdl3",
        });
        const sdl3_dir = std.mem.trim(u8, result.stdout, " \t\r\n");
        const sdl3_source = try std.fs.path.join(arena, &.{ sdl3_dir, "libSDL3.dylib" });
        const sdl3_dest = try std.fs.path.join(arena, &.{ frameworks_dir, "libSDL3.dylib" });
        try Io.Dir.copyFile(cwd, sdl3_source, cwd, sdl3_dest, io, .{});
        _ = try runChecked(arena, io, &.{
            "/usr/bin/install_name_tool",
            "-id",
            "@rpath/libSDL3.dylib",
            sdl3_dest,
        });
    }

    _ = try runChecked(arena, io, &.{
        "/usr/bin/find",
        frameworks_dir,
        "-type",
        "f",
        "-name",
        "*.dylib",
        "-exec",
        "/usr/bin/codesign",
        "--force",
        "--sign",
        "-",
        "--timestamp=none",
        "{}",
        ";",
    });
    _ = try runChecked(arena, io, &.{
        "/usr/bin/codesign",
        "--force",
        "--sign",
        "-",
        "--timestamp=none",
        app_executable,
    });
    _ = try runChecked(arena, io, &.{
        "/usr/bin/codesign",
        "--force",
        "--sign",
        "-",
        "--timestamp=none",
        app_dir,
    });

    cwd.deleteFile(io, options.output) catch {};
    _ = try runChecked(arena, io, &.{
        "/usr/bin/ditto",
        "-c",
        "-k",
        "--sequesterRsrc",
        "--keepParent",
        package_dir,
        options.output,
    });

    try createDevelopmentApp(arena, io, options, app_dir);
}

fn createDevelopmentApp(
    allocator: std.mem.Allocator,
    io: Io,
    options: Options,
    release_app: []const u8,
) !void {
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, options.dev_output) catch {};
    _ = try runChecked(allocator, io, &.{ "/usr/bin/ditto", release_app, options.dev_output });

    const contents_dir = try std.fs.path.join(allocator, &.{ options.dev_output, "Contents" });
    const macos_dir = try std.fs.path.join(allocator, &.{ contents_dir, "MacOS" });
    const dev_prefix = std.fs.path.dirname(options.dev_output) orelse ".";
    const dev_wads_dir = try std.fs.path.join(allocator, &.{ dev_prefix, "DSDA-Doom-WADs" });
    const launcher = try std.fs.path.join(allocator, &.{ macos_dir, "dsda-doom" });
    const real_executable = try std.fs.path.join(allocator, &.{ macos_dir, "dsda-doom-bin" });
    const iwad_link = try std.fs.path.join(allocator, &.{ dev_wads_dir, "iwad.wad" });

    try Io.Dir.rename(cwd, launcher, cwd, real_executable, io);
    cwd.deleteTree(io, dev_wads_dir) catch {};
    try cwd.createDirPath(io, dev_wads_dir);
    try cwd.symLink(io, options.game_iwad, iwad_link, .{});

    const launcher_source = if (options.game_wad.len == 0)
        launcher_without_pwad
    else blk: {
        const wad_link = try std.fs.path.join(allocator, &.{ dev_wads_dir, "selected.wad" });
        try cwd.symLink(io, options.game_wad, wad_link, .{});
        break :blk launcher_with_pwad;
    };
    try cwd.writeFile(io, .{ .sub_path = launcher, .data = launcher_source });
    _ = try runChecked(allocator, io, &.{ "/bin/chmod", "+x", launcher });

    // Adding the launcher changes the bundle resource seal, and moving the
    // Mach-O invalidates its bundle-aware signature. Sign the renamed
    // executable and development app again after all mutations.
    _ = try runChecked(allocator, io, &.{
        "/usr/bin/codesign",
        "--force",
        "--sign",
        "-",
        "--timestamp=none",
        real_executable,
    });
    _ = try runChecked(allocator, io, &.{
        "/usr/bin/codesign",
        "--force",
        "--sign",
        "-",
        "--timestamp=none",
        options.dev_output,
    });
}

fn parseOptions(args: []const []const u8) !Options {
    var executable: ?[]const u8 = null;
    var wad: ?[]const u8 = null;
    var icon: ?[]const u8 = null;
    var license: ?[]const u8 = null;
    var plist_template: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var dev_output: ?[]const u8 = null;
    var game_iwad: ?[]const u8 = null;
    var game_wad: ?[]const u8 = null;
    var package_version: ?[]const u8 = null;
    var system_sdl = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--system-sdl")) {
            system_sdl = true;
            continue;
        }
        if (i + 1 >= args.len) return error.InvalidArguments;
        i += 1;
        const value = args[i];
        if (std.mem.eql(u8, arg, "--executable")) {
            executable = value;
        } else if (std.mem.eql(u8, arg, "--wad")) {
            wad = value;
        } else if (std.mem.eql(u8, arg, "--icon")) {
            icon = value;
        } else if (std.mem.eql(u8, arg, "--license")) {
            license = value;
        } else if (std.mem.eql(u8, arg, "--plist-template")) {
            plist_template = value;
        } else if (std.mem.eql(u8, arg, "--output")) {
            output = value;
        } else if (std.mem.eql(u8, arg, "--dev-output")) {
            dev_output = value;
        } else if (std.mem.eql(u8, arg, "--game-iwad")) {
            game_iwad = value;
        } else if (std.mem.eql(u8, arg, "--game-wad")) {
            game_wad = value;
        } else if (std.mem.eql(u8, arg, "--version")) {
            package_version = value;
        } else {
            return error.InvalidArguments;
        }
    }

    return .{
        .executable = executable orelse return error.MissingExecutable,
        .wad = wad orelse return error.MissingWad,
        .icon = icon orelse return error.MissingIcon,
        .license = license orelse return error.MissingLicense,
        .plist_template = plist_template orelse return error.MissingPlistTemplate,
        .output = output orelse return error.MissingOutput,
        .dev_output = dev_output orelse return error.MissingDevOutput,
        .game_iwad = game_iwad orelse return error.MissingGameIwad,
        .game_wad = game_wad orelse return error.MissingGameWad,
        .version = package_version orelse return error.MissingVersion,
        .system_sdl = system_sdl,
    };
}

fn runChecked(
    allocator: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
) !std.process.RunResult {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    switch (result.term) {
        .exited => |code| if (code == 0) return result,
        else => {},
    }

    std.debug.print(
        "package-macos: command failed: {s}\n{s}{s}\n",
        .{ argv[0], result.stdout, result.stderr },
    );
    return error.CommandFailed;
}

fn hasHomebrewDependencies(
    allocator: std.mem.Allocator,
    io: Io,
    executable: []const u8,
) !bool {
    const result = try runChecked(allocator, io, &.{ "/usr/bin/otool", "-L", executable });
    return std.mem.indexOf(u8, result.stdout, "/opt/homebrew/") != null or
        std.mem.indexOf(u8, result.stdout, "/usr/local/") != null;
}

fn deduplicateFrameworkRPath(
    allocator: std.mem.Allocator,
    io: Io,
    executable: []const u8,
) !void {
    const framework_rpath = "@executable_path/../Frameworks/";
    const result = try runChecked(allocator, io, &.{ "/usr/bin/otool", "-l", executable });
    const rpath_count = std.mem.count(u8, result.stdout, "path " ++ framework_rpath ++ " (offset");

    // dylibbundler 1.0.4 adds this LC_RPATH once per direct dependency.
    // dyld rejects a Mach-O with duplicate rpaths, so retain exactly one.
    if (rpath_count > 1) {
        for (1..rpath_count) |_| {
            _ = try runChecked(allocator, io, &.{
                "/usr/bin/install_name_tool",
                "-delete_rpath",
                framework_rpath,
                executable,
            });
        }
    }
}
