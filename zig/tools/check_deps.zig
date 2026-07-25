//! Smoke-tests vendored dependencies by actually calling into them.
//!
//! The demo suites in spec/ exercise none of these: they run with -nosound
//! -nomusic and only ever open plain .wad files. So a vendored library can
//! link cleanly, pass 1105 demos, and still be broken. Each library that moves
//! from the system to an in-tree build gets a check here.
//!
//! Usage: check_deps <vorbis:file.ogg> [<name:arg> ...]

const std = @import("std");

// libvorbisfile. Only the handful of entry points needed to prove the decoder
// produces sane PCM; OggVorbis_File is opaque here, sized generously.
const OggVorbisFile = extern struct { opaque_storage: [2048]u8 };

extern fn ov_fopen(path: [*:0]const u8, vf: *OggVorbisFile) c_int;
extern fn ov_read(
    vf: *OggVorbisFile,
    buffer: [*]u8,
    length: c_int,
    bigendianp: c_int,
    word: c_int,
    sgned: c_int,
    bitstream: *c_int,
) c_long;
extern fn ov_clear(vf: *OggVorbisFile) c_int;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: check_deps <name:arg> [...]\n", .{});
        return error.InvalidArguments;
    }

    var failures: usize = 0;
    for (args[1..]) |spec| {
        const sep = std.mem.indexOfScalar(u8, spec, ':') orelse {
            std.debug.print("FAIL  malformed check spec '{s}'\n", .{spec});
            failures += 1;
            continue;
        };
        const name = spec[0..sep];
        const arg = spec[sep + 1 ..];

        if (std.mem.eql(u8, name, "vorbis")) {
            checkVorbis(arena, arg) catch |err| {
                std.debug.print("FAIL  vorbis: {s}\n", .{@errorName(err)});
                failures += 1;
                continue;
            };
            std.debug.print("ok    vorbis: decoded {s}\n", .{arg});
        } else {
            std.debug.print("FAIL  unknown check '{s}'\n", .{name});
            failures += 1;
        }
    }

    if (failures != 0) return error.ChecksFailed;
}

/// Decodes the whole file and asserts it produced a plausible amount of
/// non-silent 16-bit PCM. A stub or miswired library fails this even though it
/// links.
fn checkVorbis(arena: std.mem.Allocator, path: []const u8) !void {
    const path_z = try arena.dupeZ(u8, path);

    var vf: OggVorbisFile = undefined;
    if (ov_fopen(path_z.ptr, &vf) != 0) return error.OggOpenFailed;
    defer _ = ov_clear(&vf);

    var buffer: [4096]u8 = undefined;
    var total: usize = 0;
    var nonzero: usize = 0;
    var bitstream: c_int = 0;
    while (true) {
        const n = ov_read(&vf, &buffer, buffer.len, 0, 2, 1, &bitstream);
        if (n < 0) return error.OggDecodeError;
        if (n == 0) break;
        const got: usize = @intCast(n);
        total += got;
        for (buffer[0..got]) |byte| {
            if (byte != 0) nonzero += 1;
        }
    }

    // 2s of 44.1kHz stereo 16-bit is ~350KB; anything in the right ballpark
    // means the decoder ran rather than bailing on the first packet.
    if (total < 64 * 1024) return error.OggTooLittlePcm;
    if (nonzero * 4 < total) return error.OggMostlySilence;
}
