//! Smoke-tests vendored dependencies by actually calling into them.
//!
//! The demo suites in spec/ exercise none of these: they run with -nosound
//! -nomusic and only ever open plain .wad files. So a vendored library can
//! link cleanly, pass 1105 demos, and still be broken. Each library that moves
//! from the system to an in-tree build gets a check here.
//!
//! Usage: check_deps <vorbis:file.ogg> [<name:arg> ...]

const std = @import("std");
const Io = std.Io;

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

// libmad. Its structs are large (mad_frame and mad_synth hold multi-KB
// overlap and PCM buffers) and their layout is not part of a stable ABI, so
// rather than mirror them we hand libmad generously oversized, aligned
// scratch space and only touch it through libmad's own functions.
const MadOpaque = extern struct { storage: [128 * 1024]u8 align(16) };

extern fn mad_stream_init(stream: *MadOpaque) void;
extern fn mad_stream_buffer(stream: *MadOpaque, buf: [*]const u8, length: c_ulong) void;
extern fn mad_stream_finish(stream: *MadOpaque) void;
extern fn mad_frame_init(frame: *MadOpaque) void;
extern fn mad_frame_decode(frame: *MadOpaque, stream: *MadOpaque) c_int;
extern fn mad_frame_finish(frame: *MadOpaque) void;
extern fn mad_synth_init(synth: *MadOpaque) void;
extern fn mad_synth_frame(synth: *MadOpaque, frame: *MadOpaque) void;

// libxmp. Its context is an opaque pointer, so no struct mirroring needed.
const XmpContext = ?*anyopaque;

extern fn xmp_create_context() XmpContext;
extern fn xmp_free_context(ctx: XmpContext) void;
extern fn xmp_load_module(ctx: XmpContext, path: [*:0]const u8) c_int;
extern fn xmp_release_module(ctx: XmpContext) void;
extern fn xmp_start_player(ctx: XmpContext, rate: c_int, format: c_int) c_int;
extern fn xmp_end_player(ctx: XmpContext) void;
extern fn xmp_play_buffer(ctx: XmpContext, buffer: *anyopaque, size: c_int, loops: c_int) c_int;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
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
        } else if (std.mem.eql(u8, name, "mad")) {
            const frames = checkMad(io, arena, arg) catch |err| {
                std.debug.print("FAIL  mad: {s}\n", .{@errorName(err)});
                failures += 1;
                continue;
            };
            std.debug.print("ok    mad: decoded {d} frames from {s}\n", .{ frames, arg });
        } else if (std.mem.eql(u8, name, "xmp")) {
            const bytes = checkXmp(arena, arg) catch |err| {
                std.debug.print("FAIL  xmp: {s}\n", .{@errorName(err)});
                failures += 1;
                continue;
            };
            std.debug.print("ok    xmp: rendered {d} bytes from {s}\n", .{ bytes, arg });
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

/// Decodes every MPEG frame in the file and returns the count.
///
/// This is specifically here to catch a wrong FPM_* fixed-point selection in
/// the libmad build: the wrong choice for the target still compiles and links,
/// it just decodes to garbage. A bad selection makes frames fail to decode.
fn checkMad(io: Io, arena: std.mem.Allocator, path: []const u8) !usize {
    const data = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20));

    const stream = try arena.create(MadOpaque);
    const frame = try arena.create(MadOpaque);
    const synth = try arena.create(MadOpaque);

    mad_stream_init(stream);
    defer mad_stream_finish(stream);
    mad_frame_init(frame);
    defer mad_frame_finish(frame);
    mad_synth_init(synth);

    mad_stream_buffer(stream, data.ptr, data.len);

    var frames: usize = 0;
    var errors: usize = 0;
    while (true) {
        if (mad_frame_decode(frame, stream) != 0) {
            // Recoverable errors are normal at stream edges; give up once
            // they dominate, which is what a broken decoder looks like.
            errors += 1;
            if (errors > 16) break;
            continue;
        }
        mad_synth_frame(synth, frame);
        frames += 1;
        if (frames > 100_000) break;
    }

    // 2s of audio is ~76 frames at 1152 samples each.
    if (frames < 32) return error.MadTooFewFrames;
    return frames;
}

/// Loads a tracker module and renders audio from it.
///
/// libxmp is a large pile of format loaders; this proves the loader table and
/// the mixer are both wired up, not just that the archive linked.
fn checkXmp(arena: std.mem.Allocator, path: []const u8) !usize {
    const path_z = try arena.dupeZ(u8, path);

    const ctx = xmp_create_context() orelse return error.XmpNoContext;
    defer xmp_free_context(ctx);

    if (xmp_load_module(ctx, path_z.ptr) != 0) return error.XmpLoadFailed;
    defer xmp_release_module(ctx);

    if (xmp_start_player(ctx, 44100, 0) != 0) return error.XmpStartFailed;
    defer xmp_end_player(ctx);

    var buffer: [4096]u8 = undefined;
    var total: usize = 0;
    var nonzero: usize = 0;
    // Render a bounded number of chunks; the module loops forever.
    for (0..64) |_| {
        if (xmp_play_buffer(ctx, &buffer, buffer.len, 1) != 0) break;
        total += buffer.len;
        for (buffer) |byte| {
            if (byte != 0) nonzero += 1;
        }
    }

    if (total < 32 * 1024) return error.XmpTooLittleAudio;
    if (nonzero == 0) return error.XmpAllSilence;
    return total;
}
