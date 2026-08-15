//! Validate the archive and development app emitted by package_macos.zig.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var package: ?[]const u8 = null;
    var dev_app: ?[]const u8 = null;
    var expect_universal = false;
    var dev_has_pwad = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--universal")) {
            expect_universal = true;
        } else if (std.mem.eql(u8, args[i], "--dev-pwad")) {
            dev_has_pwad = true;
        } else if (std.mem.eql(u8, args[i], "--package") and i + 1 < args.len) {
            i += 1;
            package = args[i];
        } else if (std.mem.eql(u8, args[i], "--dev-app") and i + 1 < args.len) {
            i += 1;
            dev_app = args[i];
        } else {
            return error.InvalidArguments;
        }
    }

    const package_path = package orelse return error.MissingPackage;
    const cwd = Io.Dir.cwd();
    const validation_dir = try std.fmt.allocPrint(arena, "{s}.validation", .{package_path});
    cwd.deleteTree(io, validation_dir) catch {};
    defer cwd.deleteTree(io, validation_dir) catch {};
    try cwd.createDirPath(io, validation_dir);

    _ = try runChecked(arena, io, &.{
        "/usr/bin/ditto",
        "-x",
        "-k",
        package_path,
        validation_dir,
    });

    const archive_name = std.fs.path.basename(package_path);
    if (!std.mem.endsWith(u8, archive_name, ".zip")) return error.PackageMustBeZip;
    const package_name = archive_name[0 .. archive_name.len - ".zip".len];
    const app_dir = try std.fs.path.join(
        arena,
        &.{ validation_dir, package_name, "DSDA-Doom.app" },
    );
    const contents_dir = try std.fs.path.join(arena, &.{ app_dir, "Contents" });
    const executable = try std.fs.path.join(arena, &.{ contents_dir, "MacOS", "dsda-doom" });
    const resources_dir = try std.fs.path.join(arena, &.{ contents_dir, "Resources" });
    const frameworks_dir = try std.fs.path.join(arena, &.{ contents_dir, "Frameworks" });
    const info_plist = try std.fs.path.join(arena, &.{ contents_dir, "Info.plist" });

    for ([_][]const u8{
        executable,
        info_plist,
        try std.fs.path.join(arena, &.{ resources_dir, "dsda-doom.wad" }),
        try std.fs.path.join(arena, &.{ resources_dir, "dsda-doom.icns" }),
        try std.fs.path.join(arena, &.{ resources_dir, "COPYING.txt" }),
    }) |required| {
        cwd.access(io, required, .{}) catch |err| {
            std.debug.print("validate-macos-package: missing {s}: {t}\n", .{ required, err });
            return error.MissingBundleFile;
        };
    }

    _ = try runChecked(arena, io, &.{ "/usr/bin/plutil", "-lint", info_plist });
    const identifier_result = try runChecked(arena, io, &.{
        "/usr/bin/plutil",
        "-extract",
        "CFBundleIdentifier",
        "raw",
        "-o",
        "-",
        info_plist,
    });
    const identifier = std.mem.trim(u8, identifier_result.stdout, " \t\r\n");
    if (!std.mem.eql(u8, identifier, "org.kraflab.dsda-doom")) {
        std.debug.print("validate-macos-package: unexpected bundle identifier '{s}'\n", .{identifier});
        return error.InvalidBundleIdentifier;
    }

    _ = try runChecked(arena, io, &.{
        "/usr/bin/codesign",
        "--verify",
        "--deep",
        "--strict",
        "--verbose=2",
        app_dir,
    });

    var mach_o_files: std.ArrayList([]const u8) = .empty;
    try mach_o_files.append(arena, executable);
    const find_result = try runChecked(arena, io, &.{
        "/usr/bin/find",
        frameworks_dir,
        "-type",
        "f",
        "-name",
        "*.dylib",
        "-print",
    });
    var paths = std.mem.tokenizeScalar(u8, find_result.stdout, '\n');
    while (paths.next()) |path| try mach_o_files.append(arena, path);

    for (mach_o_files.items) |mach_o_file| {
        const otool_result = try runChecked(arena, io, &.{
            "/usr/bin/otool",
            "-L",
            mach_o_file,
        });
        if (std.mem.indexOf(u8, otool_result.stdout, "/opt/homebrew/") != null or
            std.mem.indexOf(u8, otool_result.stdout, "/usr/local/") != null)
        {
            std.debug.print(
                "validate-macos-package: non-relocatable dependency in {s}:\n{s}\n",
                .{ mach_o_file, otool_result.stdout },
            );
            return error.NonRelocatableDependency;
        }
    }

    if (expect_universal) {
        const lipo_result = try runChecked(arena, io, &.{
            "/usr/bin/lipo",
            "-info",
            executable,
        });
        if (std.mem.indexOf(u8, lipo_result.stdout, "arm64") == null or
            std.mem.indexOf(u8, lipo_result.stdout, "x86_64") == null)
        {
            std.debug.print(
                "validate-macos-package: expected arm64 and x86_64 slices: {s}\n",
                .{lipo_result.stdout},
            );
            return error.NotUniversal;
        }
    }

    const test_home = try std.fs.path.join(arena, &.{ validation_dir, "home" });
    try cwd.createDirPath(io, test_home);
    const home_assignment = try std.fmt.allocPrint(arena, "HOME={s}", .{test_home});
    _ = try runChecked(arena, io, &.{
        "/usr/bin/env",
        home_assignment,
        executable,
        "-no_message_box",
        "--help",
    });

    std.debug.print("Validated {s}\n", .{app_dir});

    if (dev_app) |dev_app_dir| {
        try validateDevelopmentApp(
            arena,
            io,
            dev_app_dir,
            validation_dir,
            expect_universal,
            dev_has_pwad,
        );
    }
}

fn validateDevelopmentApp(
    allocator: std.mem.Allocator,
    io: Io,
    app_dir: []const u8,
    validation_dir: []const u8,
    expect_universal: bool,
    has_pwad: bool,
) !void {
    const cwd = Io.Dir.cwd();
    const contents_dir = try std.fs.path.join(allocator, &.{ app_dir, "Contents" });
    const macos_dir = try std.fs.path.join(allocator, &.{ contents_dir, "MacOS" });
    const resources_dir = try std.fs.path.join(allocator, &.{ contents_dir, "Resources" });
    const frameworks_dir = try std.fs.path.join(allocator, &.{ contents_dir, "Frameworks" });
    const launcher = try std.fs.path.join(allocator, &.{ macos_dir, "dsda-doom" });
    const executable = try std.fs.path.join(allocator, &.{ macos_dir, "dsda-doom-bin" });
    const dev_wads_dir = try std.fs.path.join(allocator, &.{ resources_dir, "WADs" });
    const iwad_file = try std.fs.path.join(allocator, &.{ dev_wads_dir, "iwad.wad" });

    for ([_][]const u8{ launcher, executable, iwad_file }) |required| {
        cwd.access(io, required, .{}) catch |err| {
            std.debug.print("validate-macos-package: missing {s}: {t}\n", .{ required, err });
            return error.MissingDevelopmentFile;
        };
    }
    _ = try runChecked(allocator, io, &.{ "/bin/test", "-f", iwad_file });
    _ = try runChecked(allocator, io, &.{ "/bin/test", "!", "-L", iwad_file });
    if (has_pwad) {
        const pwad_file = try std.fs.path.join(allocator, &.{ dev_wads_dir, "selected.wad" });
        cwd.access(io, pwad_file, .{}) catch |err| {
            std.debug.print("validate-macos-package: missing {s}: {t}\n", .{ pwad_file, err });
            return error.MissingDevelopmentFile;
        };
        _ = try runChecked(allocator, io, &.{ "/bin/test", "-f", pwad_file });
        _ = try runChecked(allocator, io, &.{ "/bin/test", "!", "-L", pwad_file });
    }

    _ = try runChecked(allocator, io, &.{
        "/usr/bin/codesign",
        "--verify",
        "--deep",
        "--strict",
        "--verbose=2",
        app_dir,
    });

    var mach_o_files: std.ArrayList([]const u8) = .empty;
    try mach_o_files.append(allocator, executable);
    const find_result = try runChecked(allocator, io, &.{
        "/usr/bin/find",
        frameworks_dir,
        "-type",
        "f",
        "-name",
        "*.dylib",
        "-print",
    });
    var paths = std.mem.tokenizeScalar(u8, find_result.stdout, '\n');
    while (paths.next()) |path| try mach_o_files.append(allocator, path);
    for (mach_o_files.items) |mach_o_file| {
        const otool_result = try runChecked(allocator, io, &.{ "/usr/bin/otool", "-L", mach_o_file });
        if (std.mem.indexOf(u8, otool_result.stdout, "/opt/homebrew/") != null or
            std.mem.indexOf(u8, otool_result.stdout, "/usr/local/") != null)
        {
            return error.NonRelocatableDependency;
        }
    }

    if (expect_universal) {
        const lipo_result = try runChecked(allocator, io, &.{ "/usr/bin/lipo", "-info", executable });
        if (std.mem.indexOf(u8, lipo_result.stdout, "arm64") == null or
            std.mem.indexOf(u8, lipo_result.stdout, "x86_64") == null)
        {
            return error.NotUniversal;
        }
    }

    const test_home = try std.fs.path.join(allocator, &.{ validation_dir, "dev-home" });
    try cwd.createDirPath(io, test_home);
    const home_assignment = try std.fmt.allocPrint(allocator, "HOME={s}", .{test_home});
    const relocated_app = try std.fs.path.join(allocator, &.{ validation_dir, "DSDA-Doom-development.app" });
    _ = try runChecked(allocator, io, &.{ "/usr/bin/ditto", app_dir, relocated_app });
    const relocated_launcher = try std.fs.path.join(
        allocator,
        &.{ relocated_app, "Contents", "MacOS", "dsda-doom" },
    );
    _ = try runChecked(allocator, io, &.{ "/usr/bin/env", home_assignment, relocated_launcher, "--help" });

    std.debug.print("Validated development app {s}\n", .{app_dir});
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
        "validate-macos-package: command failed: {s}\n{s}{s}\n",
        .{ argv[0], result.stdout, result.stderr },
    );
    return error.CommandFailed;
}
