//! FLAC decoding (RFC 9639).
//!
//! The decoder reads a native FLAC stream. Integer samples are available through
//! `readInt`. `read` gives f32 with the integer scale 2^(bits-1). Memory is allocated
//! at init and on seek only.
const std = @import("std");
const codec = @import("../../codec.zig");
const io = @import("../io.zig");
const crc = @import("../crc.zig");
const wav = @import("../wav.zig");
const pcm = @import("../pcm.zig");
const flac_core = @import("core.zig");
const helpers = @import("../testing.zig");
const testing = std.testing;

pub const BadFramePolicy = flac_core.BadFramePolicy;
pub const Options = flac_core.Options;
pub const Stats = flac_core.Stats;
pub const SeekPoint = flac_core.SeekPoint;

/// Reads FLAC frames from an Input.
pub const Decoder = struct {
    core: flac_core.Core,

    pub fn init(gpa: std.mem.Allocator, input: *io.Input) codec.InitError!Decoder {
        return .{ .core = try .init(gpa, input) };
    }

    pub fn initOptions(gpa: std.mem.Allocator, input: *io.Input, options: Options) codec.InitError!Decoder {
        return .{ .core = try .initOptions(gpa, input, options) };
    }

    pub fn deinit(self: *Decoder) void {
        self.core.deinit();
        self.* = undefined;
    }

    pub fn info(self: *const Decoder) codec.Info {
        return self.core.info();
    }

    /// The seek points of the stream, without placeholders.
    pub fn seekPoints(self: *const Decoder) []const SeekPoint {
        return self.core.seekPoints();
    }

    pub fn stats(self: *const Decoder) Stats {
        return self.core.stats();
    }

    /// After the end of the stream: whether the decoded samples match the MD5 of the
    /// STREAMINFO. Null before the end, after a seek, when the stream has no MD5, or when a
    /// frame was skipped.
    pub fn md5Matches(self: *const Decoder) ?bool {
        return self.core.md5Matches();
    }

    /// Writes whole frames of f32 into `out` and returns the frame count. 0 means the end.
    /// `out` must hold at least one frame (`info().channels` samples). The samples are in
    /// [-1, 1).
    /// When the stream has more samples than the STREAMINFO total and `Options.strict_metadata`
    /// is off, the frames past the total are returned too.
    pub fn read(self: *Decoder, out: []f32) codec.ReadError!usize {
        return self.core.read(out);
    }

    /// Like `read`, with the integer sample values. A value that the stereo decorrelation put
    /// outside the sample depth is clamped to the depth and counted in `stats`.
    pub fn readInt(self: *Decoder, out: []i32) codec.ReadError!usize {
        return self.core.readInt(out);
    }

    /// Moves to a frame. `frame` equal to the frame count is the end of the data.
    pub fn seek(self: *Decoder, frame: u64) codec.SeekError!void {
        return self.core.seek(frame);
    }
};

const max_below_one = pcm.max_below_one;
const embed = helpers.embed;

const Vector = struct {
    data: []const u8,
    name: []const u8,
    rate: u32,
    channels: u8,
    bps: u8,
    frames: u64,
    /// MD5 of the samples (little endian, signed, ceil(bps/8) bytes, interleaved) from the flac 1.5.0 reference decoder.
    md5: []const u8,
};

const valid_vectors = [_]Vector{
    .{ .data = embed("s01-blocksize-4096"), .name = "s01-blocksize-4096", .rate = 44100, .channels = 2, .bps = 16, .frames = 24576, .md5 = "cbb1785e7dfb70808257ef014969f118" },
    .{ .data = embed("s02-blocksize-4608"), .name = "s02-blocksize-4608", .rate = 44100, .channels = 2, .bps = 16, .frames = 9216, .md5 = "5015a8af1742cd1daa2e2b1b8fdd865b" },
    .{ .data = embed("s03-blocksize-16"), .name = "s03-blocksize-16", .rate = 44100, .channels = 2, .bps = 16, .frames = 320, .md5 = "5f643261e46abae848e313658b6dd03c" },
    .{ .data = embed("s03b-short-last-frame"), .name = "s03b-short-last-frame", .rate = 44100, .channels = 2, .bps = 16, .frames = 60, .md5 = "42bb68e38ac87e3241150664a299c852" },
    .{ .data = embed("s04-blocksize-192"), .name = "s04-blocksize-192", .rate = 44100, .channels = 2, .bps = 16, .frames = 768, .md5 = "20963a2d332605ce8f2a167f53b515c7" },
    .{ .data = embed("s05-blocksize-254"), .name = "s05-blocksize-254", .rate = 44100, .channels = 2, .bps = 16, .frames = 1016, .md5 = "6bdde9b7338a8600dbdbaab6cefc4262" },
    .{ .data = embed("s06-blocksize-512"), .name = "s06-blocksize-512", .rate = 44100, .channels = 2, .bps = 16, .frames = 1536, .md5 = "e75f6f8cd55b23156898143301808241" },
    .{ .data = embed("s07-blocksize-725"), .name = "s07-blocksize-725", .rate = 44100, .channels = 2, .bps = 16, .frames = 2175, .md5 = "f993fd73c7e63c25a7b30709896742f2" },
    .{ .data = embed("s09-blocksize-1937"), .name = "s09-blocksize-1937", .rate = 44100, .channels = 2, .bps = 16, .frames = 3874, .md5 = "558f7196bdd973c48146b4ed4cc6205f" },
    .{ .data = embed("s10-blocksize-2304"), .name = "s10-blocksize-2304", .rate = 44100, .channels = 2, .bps = 16, .frames = 4608, .md5 = "c96e987ba37b5de7d4d0833c2ef3a436" },
    .{ .data = embed("s11-partition-order-8"), .name = "s11-partition-order-8", .rate = 44100, .channels = 2, .bps = 16, .frames = 4096, .md5 = "66ba7833ca483f715c036a6f5f567eae" },
    .{ .data = embed("s12-qlp-precision-15"), .name = "s12-qlp-precision-15", .rate = 44100, .channels = 2, .bps = 16, .frames = 4608, .md5 = "e547be51ba889d9b44357972ce11af08" },
    .{ .data = embed("s13-qlp-precision-2"), .name = "s13-qlp-precision-2", .rate = 44100, .channels = 2, .bps = 16, .frames = 4608, .md5 = "0cd23f6d6ca90cd68f136c30d786cafb" },
    .{ .data = embed("s14-wasted-bits"), .name = "s14-wasted-bits", .rate = 44100, .channels = 2, .bps = 16, .frames = 2048, .md5 = "6bbfc071ac1d29e47eeadfd68278178d" },
    .{ .data = embed("s15-verbatim"), .name = "s15-verbatim", .rate = 44100, .channels = 2, .bps = 16, .frames = 4096, .md5 = "15aae50d8e1b00a612c344ee6c76fdf7" },
    .{ .data = embed("s16-rice-escape"), .name = "s16-rice-escape", .rate = 44100, .channels = 2, .bps = 16, .frames = 4096, .md5 = "70ac1516e43bd605faa0bce143b13f71" },
    .{ .data = embed("s17-fixed-orders"), .name = "s17-fixed-orders", .rate = 44100, .channels = 2, .bps = 16, .frames = 5760, .md5 = "40ddf015d217aa51f114060b8f4de5da" },
    .{ .data = embed("s18-precision-search"), .name = "s18-precision-search", .rate = 44100, .channels = 2, .bps = 16, .frames = 12288, .md5 = "dc20f888cc074de02722907f004c0dee" },
    .{ .data = embed("s19-rate-35467"), .name = "s19-rate-35467", .rate = 35467, .channels = 2, .bps = 16, .frames = 4096, .md5 = "0a7da27e545560d0020ec8c124d83b31" },
    .{ .data = embed("s20-rate-39000"), .name = "s20-rate-39000", .rate = 39000, .channels = 2, .bps = 16, .frames = 4096, .md5 = "17a78dfb14ffee1a479aeb8781954ef7" },
    .{ .data = embed("s21-rate-22050"), .name = "s21-rate-22050", .rate = 22050, .channels = 2, .bps = 16, .frames = 4096, .md5 = "382e2a34fe7d51a59904058b8b3f32b3" },
    .{ .data = embed("s22-bps-12"), .name = "s22-bps-12", .rate = 44100, .channels = 2, .bps = 12, .frames = 8192, .md5 = "3639e05b4831e5a545e5cf6afb51d07b" },
    .{ .data = embed("s23-bps-8"), .name = "s23-bps-8", .rate = 44100, .channels = 2, .bps = 8, .frames = 12288, .md5 = "ff602f3785673f0625d639598f691eaa" },
    .{ .data = embed("s24-variable-flake"), .name = "s24-variable-flake", .rate = 44100, .channels = 2, .bps = 16, .frames = 18432, .md5 = "5286f53ba5de05c52f73808576ff3d31" },
    .{ .data = embed("s25-variable-small-blocks"), .name = "s25-variable-small-blocks", .rate = 44100, .channels = 2, .bps = 16, .frames = 16960, .md5 = "e80f85c24fec828716386119aa553fa9" },
    .{ .data = embed("s26-variable-cuetools"), .name = "s26-variable-cuetools", .rate = 44100, .channels = 2, .bps = 16, .frames = 12288, .md5 = "4bb25e6682dab713099a38cfbdab6aaf" },
    .{ .data = embed("s27-variable-old-format"), .name = "s27-variable-old-format", .rate = 44100, .channels = 2, .bps = 16, .frames = 18432, .md5 = "1e9b376e4dcda16a2f223d8e48e81dbe" },
    .{ .data = embed("s28-hires-96k-24bit"), .name = "s28-hires-96k-24bit", .rate = 96000, .channels = 2, .bps = 24, .frames = 4096, .md5 = "d09b71ade4d31c8e77b5acb0588cb466" },
    .{ .data = embed("s31-lpc-order-32"), .name = "s31-lpc-order-32", .rate = 96000, .channels = 2, .bps = 24, .frames = 8192, .md5 = "11c34a92c4339e38d47b68132b03bf6e" },
    .{ .data = embed("s33-rate-192000"), .name = "s33-rate-192000", .rate = 192000, .channels = 2, .bps = 24, .frames = 4096, .md5 = "de6617c81dcf365215e8bbe6c07cad16" },
    .{ .data = embed("s35-rate-134560"), .name = "s35-rate-134560", .rate = 134560, .channels = 2, .bps = 24, .frames = 4096, .md5 = "bd78cceb906ade8d5eb8518a5b910068" },
    .{ .data = embed("s38-channels-3"), .name = "s38-channels-3", .rate = 44100, .channels = 3, .bps = 16, .frames = 57344, .md5 = "f998c43afab3207a495fce831b498278" },
    .{ .data = embed("s39-channels-4"), .name = "s39-channels-4", .rate = 44100, .channels = 4, .bps = 16, .frames = 16384, .md5 = "0dfbe8aa4c20b52e1b8bf3cb6cbdf193" },
    .{ .data = embed("s40-channels-5"), .name = "s40-channels-5", .rate = 44100, .channels = 5, .bps = 16, .frames = 16384, .md5 = "95a7a1b2218167ba6fa90f181f132eb5" },
    .{ .data = embed("s41-channels-6"), .name = "s41-channels-6", .rate = 44100, .channels = 6, .bps = 16, .frames = 16384, .md5 = "c3e766ef56b26016233a0a43246474df" },
    .{ .data = embed("s42-channels-7"), .name = "s42-channels-7", .rate = 44100, .channels = 7, .bps = 16, .frames = 16384, .md5 = "d44591d49d6e0f6dd283f3f33af31749" },
    .{ .data = embed("s43-channels-8"), .name = "s43-channels-8", .rate = 44100, .channels = 8, .bps = 16, .frames = 16384, .md5 = "fc24a70351aadd94be628d23b1fc8afd" },
    .{ .data = embed("s46-no-frame-sizes"), .name = "s46-no-frame-sizes", .rate = 48000, .channels = 2, .bps = 16, .frames = 8192, .md5 = "748f30a27f6565fa0e9bf36e5f80b946" },
    .{ .data = embed("s47-only-streaminfo"), .name = "s47-only-streaminfo", .rate = 48000, .channels = 2, .bps = 16, .frames = 8192, .md5 = "ac1a33282ced78b119f83dca35c5f5d7" },
    .{ .data = embed("s60-mono"), .name = "s60-mono", .rate = 44100, .channels = 1, .bps = 16, .frames = 12288, .md5 = "91ff0dac5df86e798bfef5e573536b08" },
    .{ .data = embed("s61-overflow-16bit"), .name = "s61-overflow-16bit", .rate = 44100, .channels = 1, .bps = 16, .frames = 40960, .md5 = "3e8dcf896edb9d009a38cc1708ed2081" },
    .{ .data = embed("s62-overflow-20bit"), .name = "s62-overflow-20bit", .rate = 44100, .channels = 1, .bps = 20, .frames = 40960, .md5 = "933e258e9341c037250f136e798bb4b9" },
    .{ .data = embed("s63-overflow-24bit"), .name = "s63-overflow-24bit", .rate = 44100, .channels = 1, .bps = 24, .frames = 40960, .md5 = "322d261fd8c3de8b4725c1f88be0f8b5" },
    .{ .data = embed("s64-rice-escape-zero"), .name = "s64-rice-escape-zero", .rate = 44100, .channels = 1, .bps = 16, .frames = 8192, .md5 = "e4e64afaffcc6bea290104d8cbe186b6" },
    .{ .data = embed("u05a-bps-32-mid-side"), .name = "u05a-bps-32-mid-side", .rate = 44100, .channels = 2, .bps = 32, .frames = 4096, .md5 = "1f388a81db9209e4d61e05dfffbe993f" },
    .{ .data = embed("u05b-bps-32-left-side"), .name = "u05b-bps-32-left-side", .rate = 44100, .channels = 2, .bps = 32, .frames = 4096, .md5 = "d77a9c8a83f78aefd58d976fb34fd6a8" },
    .{ .data = embed("u05c-bps-32-right-side"), .name = "u05c-bps-32-right-side", .rate = 44100, .channels = 2, .bps = 32, .frames = 4096, .md5 = "6d18355a9c111b3dcfbbd0e9d4e9052a" },
    .{ .data = embed("u06-rate-768000"), .name = "u06-rate-768000", .rate = 768000, .channels = 2, .bps = 24, .frames = 4096, .md5 = "70233711551a87f334e201fe5d4893db" },
    .{ .data = embed("u07a-bps-15"), .name = "u07a-bps-15", .rate = 44100, .channels = 2, .bps = 15, .frames = 4096, .md5 = "b7ce959b0fc08311fd99ca847dafffc9" },
    .{ .data = embed("u07b-bps-15-mid-side"), .name = "u07b-bps-15-mid-side", .rate = 44100, .channels = 2, .bps = 15, .frames = 4096, .md5 = "7f06edf69f6b3f3d05b5c455269ee285" },
    .{ .data = embed("u09-rice-order-15"), .name = "u09-rice-order-15", .rate = 24000, .channels = 1, .bps = 16, .frames = 32768, .md5 = "6f23572b500f4c5b5cc1d3294ad8e207" },
};

/// Streams whose first frames decode, followed by a frame that changes a stream property.
/// `frames` and `md5` cover the samples before the change, as the reference decoder gives them.
const change_vectors = [_]Vector{
    .{ .data = embed("u01-changing-rate"), .name = "u01-changing-rate", .rate = 32000, .channels = 2, .bps = 16, .frames = 4096, .md5 = "0628754d321376cacce412f7a4e77a62" },
    .{ .data = embed("u02-increasing-channels"), .name = "u02-increasing-channels", .rate = 44100, .channels = 1, .bps = 16, .frames = 4096, .md5 = "0829f71740aab1ab98b33eae21dee122" },
    .{ .data = embed("u03-decreasing-channels"), .name = "u03-decreasing-channels", .rate = 44100, .channels = 4, .bps = 16, .frames = 4096, .md5 = "3e51b62abbfba4632b958a6cb47fcb78" },
    .{ .data = embed("u04-changing-bitdepth"), .name = "u04-changing-bitdepth", .rate = 44100, .channels = 1, .bps = 16, .frames = 4096, .md5 = "bb4ee677048b6d88a84b736c34a29079" },
};

fn find(name: []const u8) Vector {
    for (valid_vectors) |v| {
        if (std.mem.eql(u8, v.name, name)) return v;
    }
    unreachable;
}

const Failure = struct {
    data: []const u8,
    name: []const u8,
    /// Error from init, or null when init works.
    init_err: ?anyerror,
    /// Error from reading, after `frames` frames.
    read_err: ?anyerror = null,
    frames: u64 = 0,
    /// The error needs Options.strict_metadata.
    strict: bool = false,
};

const failures = [_]Failure{
    .{ .data = embed("f01-wrong-max-blocksize"), .name = "f01", .init_err = null, .read_err = error.BadData },
    .{ .data = embed("f02-wrong-max-framesize"), .name = "f02", .init_err = null, .read_err = error.BadData, .frames = 13824, .strict = true },
    .{ .data = embed("f03-wrong-bit-depth"), .name = "f03", .init_err = null, .read_err = error.BadData },
    .{ .data = embed("f04-wrong-channels"), .name = "f04", .init_err = null, .read_err = error.BadData },
    .{ .data = embed("f05-wrong-total-samples"), .name = "f05", .init_err = null, .read_err = error.BadData, .frames = 36864, .strict = true },
    .{ .data = embed("f06-missing-streaminfo"), .name = "f06", .init_err = error.BadHeader },
    .{ .data = embed("f07-streaminfo-not-first"), .name = "f07", .init_err = error.BadHeader },
    .{ .data = embed("f09-blocksize-1"), .name = "f09", .init_err = error.BadHeader },
    .{ .data = embed("f10-invalid-vorbis-comment"), .name = "f10", .init_err = error.BadHeader },
    .{ .data = embed("f11-bad-metadata-length"), .name = "f11", .init_err = error.BadHeader },
    .{ .data = embed("u10-no-marker"), .name = "u10", .init_err = error.Unsupported },
    .{ .data = embed("u11-garbage-prefix"), .name = "u11", .init_err = error.Unsupported },
};

/// Reads everything with `chunk` frames per call. Returns the frame count and the MD5 of the samples.
fn drain(dec: *Decoder, chunk: usize, hash: *std.crypto.hash.Md5, frames: *u64) (codec.ReadError || error{OutOfMemory})!void {
    const channels: usize = dec.info().channels;
    const width: usize = (dec.info().bits_per_sample + 7) / 8;
    const buf = try testing.allocator.alloc(i32, chunk * channels);
    defer testing.allocator.free(buf);
    while (true) {
        const n = try dec.readInt(buf);
        if (n == 0) return;
        frames.* += n;
        for (buf[0 .. n * channels]) |v| {
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(i32, &tmp, v, .little);
            hash.update(tmp[0..width]);
        }
    }
}

fn expectHex(want: []const u8, digest: [16]u8) !void {
    const got = std.fmt.bytesToHex(digest, .lower);
    try testing.expectEqualStrings(want, &got);
}

test "vendored vectors decode to the reference samples" {
    for (valid_vectors) |v| {
        var input: io.Input = .init(.{ .bytes = v.data });
        var dec = try Decoder.init(testing.allocator, &input);
        defer dec.deinit();
        const info = dec.info();
        try testing.expectEqual(v.rate, info.rate);
        try testing.expectEqual(v.channels, info.channels);
        try testing.expectEqual(v.bps, info.bits_per_sample);
        try testing.expectEqual(@as(?u64, null), info.total_frames);
        var hash: std.crypto.hash.Md5 = .init(.{});
        var frames: u64 = 0;
        drain(&dec, 777, &hash, &frames) catch |err| {
            std.debug.print("{s}: {t}\n", .{ v.name, err });
            return err;
        };
        try testing.expectEqual(v.frames, frames);
        var digest: [16]u8 = undefined;
        hash.final(&digest);
        expectHex(v.md5, digest) catch |err| {
            std.debug.print("{s}\n", .{v.name});
            return err;
        };
        try testing.expectEqual(@as(?bool, null), dec.md5Matches());
        try testing.expectEqual(@as(u32, 0), dec.stats().crc_errors);
    }
}

test "reading one frame at a time gives the same samples" {
    for ([_]Vector{ find("s01-blocksize-4096"), find("s03-blocksize-16"), find("s23-bps-8") }) |v| {
        var input: io.Input = .init(.{ .bytes = v.data });
        var dec = try Decoder.init(testing.allocator, &input);
        defer dec.deinit();
        var hash: std.crypto.hash.Md5 = .init(.{});
        var frames: u64 = 0;
        try drain(&dec, 1, &hash, &frames);
        try testing.expectEqual(v.frames, frames);
        var digest: [16]u8 = undefined;
        hash.final(&digest);
        try expectHex(v.md5, digest);
    }
}

test "f32 output is the integer scaled by 2^(bits-1)" {
    for (valid_vectors) |v| {
        var a_in: io.Input = .init(.{ .bytes = v.data });
        var b_in: io.Input = .init(.{ .bytes = v.data });
        var a = try Decoder.init(testing.allocator, &a_in);
        defer a.deinit();
        var b = try Decoder.init(testing.allocator, &b_in);
        defer b.deinit();
        const channels: usize = v.channels;
        var ints: [8 * 256]i32 = undefined;
        var floats: [8 * 256]f32 = undefined;
        const scale: f64 = @floatFromInt(@as(u64, 1) << @intCast(v.bps - 1));
        while (true) {
            const n = try a.readInt(ints[0 .. 256 * channels]);
            const m = try b.read(floats[0 .. 256 * channels]);
            try testing.expectEqual(n, m);
            if (n == 0) break;
            for (ints[0 .. n * channels], floats[0 .. n * channels]) |i, f| {
                const want: f32 = pcm.clampUnit(@floatCast(@as(f64, @floatFromInt(i)) / scale));
                try testing.expectEqual(want, f);
                try testing.expect(f >= -1.0 and f < 1.0);
            }
        }
    }
}

test "the default channel mask follows the stream channel count" {
    for (valid_vectors) |v| {
        var input: io.Input = .init(.{ .bytes = v.data });
        var dec = try Decoder.init(testing.allocator, &input);
        defer dec.deinit();
        try testing.expectEqual(wav.defaultMask(v.channels), @as(u32, @bitCast(dec.info().mask)));
    }
}

test "streams that change a property decode up to the change" {
    for (change_vectors) |v| {
        var input: io.Input = .init(.{ .bytes = v.data });
        var dec = try Decoder.initOptions(testing.allocator, &input, .{ .on_bad_frame = .fail });
        defer dec.deinit();
        var hash: std.crypto.hash.Md5 = .init(.{});
        var frames: u64 = 0;
        try testing.expectError(error.BadData, drain(&dec, 1000, &hash, &frames));
        try testing.expectEqual(v.frames, frames);
        var digest: [16]u8 = undefined;
        hash.final(&digest);
        try expectHex(v.md5, digest);
        var one: [8]i32 = undefined;
        try testing.expectError(error.BadData, dec.readInt(&one));
    }
}

test "faulty and unsupported streams give an error" {
    for (failures) |f| {
        var input: io.Input = .init(.{ .bytes = f.data });
        if (f.init_err) |want| {
            try testing.expectError(@as(anyerror, want), @as(anyerror!Decoder, Decoder.init(testing.allocator, &input)));
            continue;
        }
        var dec = try Decoder.initOptions(testing.allocator, &input, .{ .strict_metadata = f.strict, .on_bad_frame = .fail });
        defer dec.deinit();
        var hash: std.crypto.hash.Md5 = .init(.{});
        var frames: u64 = 0;
        const result = drain(&dec, 1000, &hash, &frames);
        if (f.read_err) |want| {
            try testing.expectError(@as(anyerror, want), @as(anyerror!void, result));
        } else {
            try result;
        }
        testing.expectEqual(f.frames, frames) catch |err| {
            std.debug.print("{s}\n", .{f.name});
            return err;
        };
    }
}

test "strict metadata gives BadData under the resync policy" {
    var seen: usize = 0;
    for (failures) |f| {
        if (!f.strict or f.init_err != null) continue;
        var input: io.Input = .init(.{ .bytes = f.data });
        var dec = try Decoder.initOptions(testing.allocator, &input, .{ .strict_metadata = true, .on_bad_frame = .resync });
        defer dec.deinit();
        var hash: std.crypto.hash.Md5 = .init(.{});
        var frames: u64 = 0;
        try testing.expectError(error.BadData, drain(&dec, 1000, &hash, &frames));
        try testing.expectEqual(f.frames, frames);
        try testing.expectEqual(@as(u32, 0), dec.stats().resyncs);
        seen += 1;
    }
    try testing.expect(seen > 0);
}

/// Decodes as far as possible with either CRC policy. Errors are fine, crashes are not.
fn decodeQuietly(data: []const u8, policy: BadFramePolicy) !void {
    var input: io.Input = .init(.{ .bytes = data });
    var dec = Decoder.initOptions(testing.allocator, &input, .{ .on_bad_frame = policy }) catch return;
    defer dec.deinit();
    var buf: [8 * 64]i32 = undefined;
    var guard: usize = 0;
    while (guard < 100000) : (guard += 1) {
        const n = dec.readInt(&buf) catch return;
        if (n == 0) return;
    }
}

test "faulty files cut at ten offsets never crash" {
    for (failures) |f| {
        for (0..10) |i| {
            const cut = f.data.len * i / 10;
            try decodeQuietly(f.data[0..cut], .fail);
            try decodeQuietly(f.data[0..cut], .resync);
        }
    }
}

test "valid files cut at ten offsets end with Truncated or a clean end" {
    for (valid_vectors[0..8]) |v| {
        for (1..10) |i| {
            const cut = v.data.len * i / 10;
            var input: io.Input = .init(.{ .bytes = v.data[0..cut] });
            var dec = Decoder.init(testing.allocator, &input) catch |err| {
                try testing.expectEqual(error.Truncated, err);
                continue;
            };
            defer dec.deinit();
            var hash: std.crypto.hash.Md5 = .init(.{});
            var frames: u64 = 0;
            drain(&dec, 100, &hash, &frames) catch |err| try testing.expectEqual(error.Truncated, err);
        }
    }
}

test "flipped bytes never crash the decoder" {
    var prng: std.Random.DefaultPrng = .init(0x464c4143);
    const rand = prng.random();

    for ([_][]const u8{ "s01-blocksize-4096", "s14-wasted-bits", "s17-fixed-orders", "s38-channels-3", "s31-lpc-order-32", "u05a-bps-32-mid-side" }) |name| {
        const v = find(name);
        const copy = try testing.allocator.dupe(u8, v.data);
        defer testing.allocator.free(copy);
        for (0..120) |_| {
            const at = rand.intRangeLessThan(usize, 0, copy.len);
            const old = copy[at];
            copy[at] ^= @as(u8, 1) << rand.int(u3);
            try decodeQuietly(copy, .fail);
            try decodeQuietly(copy, .resync);
            copy[at] = old;
        }
    }
}

test "a wrong frame CRC-16 is an error unless the decoder resyncs" {
    const v = find("s02-blocksize-4608");
    const copy = try testing.allocator.dupe(u8, v.data);
    defer testing.allocator.free(copy);
    copy[copy.len - 1] ^= 0x55;

    var input: io.Input = .init(.{ .bytes = copy });
    var dec = try Decoder.initOptions(testing.allocator, &input, .{ .on_bad_frame = .fail });
    defer dec.deinit();
    var hash: std.crypto.hash.Md5 = .init(.{});
    var frames: u64 = 0;
    try testing.expectError(error.BadData, drain(&dec, 1000, &hash, &frames));
    try testing.expectEqual(@as(u64, 4608), frames);
    try testing.expectEqual(@as(u32, 1), dec.stats().crc_errors);
    try testing.expectEqual(@as(u32, 0), dec.stats().resyncs);

    // The default drops the last frame. Nothing follows it, so the stream ends.
    var input2: io.Input = .init(.{ .bytes = copy });
    var dec2 = try Decoder.init(testing.allocator, &input2);
    defer dec2.deinit();
    const starts = try frameStarts(testing.allocator, v.data);
    defer testing.allocator.free(starts.pos);
    defer testing.allocator.free(starts.len);
    var hash2: std.crypto.hash.Md5 = .init(.{});
    var frames2: u64 = 0;
    try drain(&dec2, 1000, &hash2, &frames2);
    try testing.expectEqual(@as(u64, 4608), frames2);
    try testing.expectEqual(@as(u32, 1), dec2.stats().crc_errors);
    try testing.expectEqual(@as(u32, 1), dec2.stats().resyncs);
    try testing.expectEqual(@as(u64, copy.len - starts.pos[1]), dec2.stats().skipped_bytes);
}

/// Where each frame of a file starts in the bytes and how many samples it has.
fn frameStarts(gpa: std.mem.Allocator, data: []const u8) !struct { pos: []u64, len: []u32 } {
    var input: io.Input = .init(.{ .bytes = data });
    var dec = try Decoder.init(gpa, &input);
    defer dec.deinit();
    var pos: std.ArrayList(u64) = .empty;
    errdefer pos.deinit(gpa);
    var len: std.ArrayList(u32) = .empty;
    errdefer len.deinit(gpa);
    while (true) {
        const at = dec.core.bits.bytePosition();
        if (!try dec.core.loadBlock()) break;
        try pos.append(gpa, at);
        try len.append(gpa, @intCast(dec.core.block_len));
    }
    return .{ .pos = try pos.toOwnedSlice(gpa), .len = try len.toOwnedSlice(gpa) };
}

/// Damages the frames in `lost`, decodes with the default options and checks that the
/// rest of the samples come out unchanged.
fn expectResync(name: []const u8, lost: []const usize, forward_only: bool) !void {
    const gpa = testing.allocator;
    const v = find(name);
    const channels: usize = v.channels;
    const starts = try frameStarts(gpa, v.data);
    defer gpa.free(starts.pos);
    defer gpa.free(starts.len);
    var clean_input: io.Input = .init(.{ .bytes = v.data });
    var clean = try Decoder.init(gpa, &clean_input);
    defer clean.deinit();
    const all = try readAllInts(gpa, &clean, 1 << 20);
    defer gpa.free(all);

    var want: std.ArrayList(i32) = .empty;
    defer want.deinit(gpa);
    const copy = try gpa.dupe(u8, v.data);
    defer gpa.free(copy);
    var skipped: u64 = 0;
    var at: usize = 0;
    for (starts.pos, starts.len, 0..) |pos, len, k| {
        const end: u64 = if (k + 1 < starts.pos.len) starts.pos[k + 1] else v.data.len;
        const bytes = all[at * channels ..][0 .. len * channels];
        at += len;
        if (std.mem.indexOfScalar(usize, lost, k) != null) {
            copy[@intCast((pos + end) / 2)] ^= 0x55;
            skipped += end - pos;
        } else {
            try want.appendSlice(gpa, bytes);
        }
    }

    var reader: std.Io.Reader = .fixed(copy);
    var input: io.Input = .init(if (forward_only) .{ .reader = &reader } else .{ .bytes = copy });
    var dec = try Decoder.init(gpa, &input);
    defer dec.deinit();
    const got = try readAllInts(gpa, &dec, 1 << 20);
    defer gpa.free(got);
    try testing.expectEqualSlices(i32, want.items, got);
    try testing.expectEqual(@as(u32, @intCast(lost.len)), dec.stats().resyncs);
    try testing.expectEqual(skipped, dec.stats().skipped_bytes);
    try testing.expect(dec.stats().crc_errors <= lost.len);
    try testing.expectEqual(@as(?bool, null), dec.md5Matches());

    // With `.fail` the first bad frame ends the stream with an error.
    var fail_input: io.Input = .init(.{ .bytes = copy });
    var fail = try Decoder.initOptions(gpa, &fail_input, .{ .on_bad_frame = .fail });
    defer fail.deinit();
    var hash: std.crypto.hash.Md5 = .init(.{});
    var frames: u64 = 0;
    try testing.expectError(error.BadData, drain(&fail, 1000, &hash, &frames));
    var before: u64 = 0;
    for (starts.len[0..lost[0]]) |len| before += len;
    try testing.expectEqual(before, frames);
}

test "a damaged frame is skipped and the rest of the stream decodes" {
    for ([_]bool{ false, true }) |forward_only| {
        // Frame 5 of the six frames of s01.
        try expectResync("s01-blocksize-4096", &.{4}, forward_only);
        try expectResync("s01-blocksize-4096", &.{ 1, 3 }, forward_only);
        try expectResync("s01-blocksize-4096", &.{0}, forward_only);
        try expectResync("s01-blocksize-4096", &.{5}, forward_only);
        try expectResync("s38-channels-3", &.{ 2, 7, 11 }, forward_only);
        try expectResync("s24-variable-flake", &.{ 3, 4 + 3 }, forward_only);
        try expectResync("s23-bps-8", &.{2}, forward_only);
    }
}

test "a damaged frame header is skipped" {
    const gpa = testing.allocator;
    const v = find("s01-blocksize-4096");
    const starts = try frameStarts(gpa, v.data);
    defer gpa.free(starts.pos);
    defer gpa.free(starts.len);
    const copy = try gpa.dupe(u8, v.data);
    defer gpa.free(copy);
    // The sync code of the third frame.
    copy[@intCast(starts.pos[2])] ^= 0x01;
    var input: io.Input = .init(.{ .bytes = copy });
    var dec = try Decoder.init(gpa, &input);
    defer dec.deinit();
    const got = try readAllInts(gpa, &dec, 1 << 20);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, (24576 - 4096) * 2), got.len);
    try testing.expectEqual(@as(u32, 1), dec.stats().resyncs);
    try testing.expectEqual(starts.pos[3] - starts.pos[2], dec.stats().skipped_bytes);
    try testing.expectEqual(@as(u32, 0), dec.stats().crc_errors);
}

test "the frame number sets the position after a skipped frame" {
    const gpa = testing.allocator;
    const v = find("s01-blocksize-4096");
    const starts = try frameStarts(gpa, v.data);
    defer gpa.free(starts.pos);
    defer gpa.free(starts.len);
    const copy = try gpa.dupe(u8, v.data);
    defer gpa.free(copy);
    patchTotal(copy, 24576);
    copy[@intCast((starts.pos[2] + starts.pos[3]) / 2)] ^= 0x55;
    var input: io.Input = .init(.{ .bytes = copy });
    var dec = try Decoder.init(gpa, &input);
    defer dec.deinit();
    // A lost frame in the middle is no error, and no sample counts as more than the total.
    const got = try readAllInts(gpa, &dec, 1 << 20);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, (24576 - 4096) * 2), got.len);
    try testing.expectEqual(@as(u64, 0), dec.stats().excess_samples);
    try testing.expectEqual(@as(?bool, null), dec.md5Matches());

    // A lost last frame leaves the stream shorter than its total.
    const last = try gpa.dupe(u8, copy);
    defer gpa.free(last);
    @memcpy(last, v.data);
    patchTotal(last, 24576);
    last[@intCast((starts.pos[5] + v.data.len) / 2)] ^= 0x55;
    var input2: io.Input = .init(.{ .bytes = last });
    var dec2 = try Decoder.init(gpa, &input2);
    defer dec2.deinit();
    var buf: [2 * 4096]i32 = undefined;
    for (0..5) |_| try testing.expectEqual(@as(usize, 4096), try dec2.readInt(&buf));
    try testing.expectError(error.Truncated, dec2.readInt(&buf));
}

test "strict metadata checks the frame that a resync scan finds" {
    const gpa = testing.allocator;
    const v = find("s01-blocksize-4096");
    const starts = try frameStarts(gpa, v.data);
    defer gpa.free(starts.pos);
    defer gpa.free(starts.len);
    const copy = try gpa.dupe(u8, v.data);
    defer gpa.free(copy);
    patchTotal(copy, 12288);
    copy[@intCast((starts.pos[2] + starts.pos[3]) / 2)] ^= 0x55;
    var input: io.Input = .init(.{ .bytes = copy });
    var dec = try Decoder.initOptions(gpa, &input, .{ .strict_metadata = true, .on_bad_frame = .resync });
    defer dec.deinit();
    var buf: [2 * 4096]i32 = undefined;
    for (0..2) |_| try testing.expectEqual(@as(usize, 4096), try dec.readInt(&buf));
    try testing.expectError(error.BadData, dec.readInt(&buf));
    try testing.expectEqual(@as(u64, 0), dec.stats().excess_samples);
}

test "resync does not hide a stream that ends inside a frame" {
    const v = find("s01-blocksize-4096");
    var input: io.Input = .init(.{ .bytes = v.data[0 .. v.data.len - 20] });
    var dec = try Decoder.init(testing.allocator, &input);
    defer dec.deinit();
    var buf: [2 * 4096]i32 = undefined;
    for (0..5) |_| try testing.expectEqual(@as(usize, 4096), try dec.readInt(&buf));
    try testing.expectError(error.Truncated, dec.readInt(&buf));
    try testing.expectEqual(@as(u32, 0), dec.stats().resyncs);
}

test "a stream that changes a property ends at the change when the decoder resyncs" {
    for (change_vectors) |v| {
        var input: io.Input = .init(.{ .bytes = v.data });
        var dec = try Decoder.init(testing.allocator, &input);
        defer dec.deinit();
        var hash: std.crypto.hash.Md5 = .init(.{});
        var frames: u64 = 0;
        try drain(&dec, 1000, &hash, &frames);
        try testing.expectEqual(v.frames, frames);
        try testing.expect(dec.stats().resyncs >= 1);
        try testing.expect(dec.stats().skipped_bytes > 0);
    }
}

test "md5Matches compares the decoded samples with STREAMINFO" {
    for ([_][]const u8{ "s01-blocksize-4096", "s14-wasted-bits", "s31-lpc-order-32", "u05a-bps-32-mid-side", "s22-bps-12" }) |name| {
        const v = find(name);
        const copy = try testing.allocator.dupe(u8, v.data);
        defer testing.allocator.free(copy);
        // STREAMINFO body starts at byte 8, its MD5 at body offset 18.
        _ = try std.fmt.hexToBytes(copy[26..42], v.md5);

        var input: io.Input = .init(.{ .bytes = copy });
        var dec = try Decoder.init(testing.allocator, &input);
        defer dec.deinit();
        var buf: [8 * 100]i32 = undefined;
        try testing.expectEqual(@as(?bool, null), dec.md5Matches());
        while (try dec.readInt(&buf) != 0) {}
        try testing.expectEqual(@as(?bool, true), dec.md5Matches());

        copy[26] ^= 1;
        var input2: io.Input = .init(.{ .bytes = copy });
        var dec2 = try Decoder.init(testing.allocator, &input2);
        defer dec2.deinit();
        while (try dec2.readInt(&buf) != 0) {}
        try testing.expectEqual(@as(?bool, false), dec2.md5Matches());
    }
}

fn readAllInts(gpa: std.mem.Allocator, dec: *Decoder, max_frames: usize) ![]i32 {
    const channels: usize = dec.info().channels;
    const all = try gpa.alloc(i32, max_frames * channels);
    errdefer gpa.free(all);
    var got: usize = 0;
    while (got < max_frames) {
        const n = try dec.readInt(all[got * channels .. @min(got + 500, max_frames) * channels]);
        if (n == 0) break;
        got += n;
    }
    return gpa.realloc(all, got * channels);
}

fn expectSeeksMatch(data: []const u8, targets: []const u64) !void {
    var input: io.Input = .init(.{ .bytes = data });
    var full = try Decoder.init(testing.allocator, &input);
    defer full.deinit();
    const channels: usize = full.info().channels;
    const all = try readAllInts(testing.allocator, &full, 1 << 20);
    defer testing.allocator.free(all);
    const total: u64 = all.len / channels;

    var input2: io.Input = .init(.{ .bytes = data });
    var dec = try Decoder.init(testing.allocator, &input2);
    defer dec.deinit();
    var buf: [8 * 300]i32 = undefined;
    for (targets) |t| {
        try dec.seek(t);
        const n = try dec.readInt(buf[0 .. 300 * channels]);
        const want = @min(total - t, 300);
        try testing.expect(n > 0 or t == total);
        try testing.expect(n <= want);
        try testing.expectEqualSlices(i32, all[@as(usize, @intCast(t)) * channels ..][0 .. n * channels], buf[0 .. n * channels]);
    }
    try testing.expectError(error.Truncated, dec.seek(total + 100000));
}

test "seek with bisection on frame sync matches a full decode" {
    // s38 has no seek table.
    try expectSeeksMatch(embed("s38-channels-3"), &.{ 0, 1, 4095, 4096, 5000, 9999, 30000, 57000, 57343 });
    // s25 and s27 have variable block sizes.
    try expectSeeksMatch(embed("s25-variable-small-blocks"), &.{ 0, 63, 64, 1000, 5000, 9000, 16000, 16959 });
    try expectSeeksMatch(embed("s27-variable-old-format"), &.{ 0, 4607, 4608, 7000, 9999, 13824, 18000 });
}

test "seek with a seek table matches a full decode" {
    // s01 has a one point table. u07a also has a point past the end of the data.
    try expectSeeksMatch(embed("s01-blocksize-4096"), &.{ 0, 2, 4095, 4096, 4097, 12345, 24575 });
    try expectSeeksMatch(embed("u07a-bps-15"), &.{ 0, 3000, 4095 });
}

test "seek to the end and reading after it" {
    var input: io.Input = .init(.{ .bytes = embed("s02-blocksize-4608") });
    var dec = try Decoder.init(testing.allocator, &input);
    defer dec.deinit();
    var buf: [2 * 64]i32 = undefined;
    try dec.seek(9216);
    try testing.expectEqual(@as(usize, 0), try dec.readInt(&buf));
    try dec.seek(9200);
    try testing.expectEqual(@as(usize, 16), try dec.readInt(&buf));
    try testing.expectEqual(@as(usize, 0), try dec.readInt(&buf));
}

test "a forward only reader cannot seek" {
    var r: std.Io.Reader = .fixed(embed("s02-blocksize-4608"));
    var input: io.Input = .init(.{ .reader = &r });
    var dec = try Decoder.init(testing.allocator, &input);
    defer dec.deinit();
    try testing.expectError(error.Unseekable, dec.seek(10));
    var buf: [2 * 64]i32 = undefined;
    try testing.expect(try dec.readInt(&buf) > 0);
}

test "a file source decodes and seeks" {
    if (!io.has_files) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = embed("s38-channels-3");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.flac", .data = data });
    var file = try tmp.dir.openFile(testing.io, "a.flac", .{});
    defer file.close(testing.io);
    var fbuf: [100]u8 = undefined;
    var fr = file.reader(testing.io, &fbuf);
    var input: io.Input = .init(.{ .file = &fr });
    var dec = try Decoder.init(testing.allocator, &input);
    defer dec.deinit();
    var buf: [3 * 50]i32 = undefined;
    try dec.seek(30000);
    try testing.expectEqual(@as(usize, 50), try dec.readInt(&buf));

    var input2: io.Input = .init(.{ .bytes = data });
    var ref = try Decoder.init(testing.allocator, &input2);
    defer ref.deinit();
    try ref.seek(30000);
    var want: [3 * 50]i32 = undefined;
    try testing.expectEqual(@as(usize, 50), try ref.readInt(&want));
    try testing.expectEqualSlices(i32, &want, &buf);
}

const FrameSpec = struct {
    variable: bool = false,
    /// The frame number, or the sample number when `variable` is set.
    number: u32 = 0,
    bs_code: u4,
    /// Block size minus one, for the codes 6 and 7.
    bs_field: u16 = 0,
    rate_code: u4 = 0,
    /// The rate field, for the codes 12 to 14.
    rate_field: u16 = 0,
    ch_code: u4,
    size_code: u3 = 0,
};

fn writeUtf8(bw: *io.BitWriter, n32: u32) !void {
    const n: u64 = n32;
    if (n < 0x80) return bw.writeBits(n, 8);
    const extra: u6 = if (n < 0x800) 1 else if (n < 0x10000) 2 else 3;
    const lead: u64 = (@as(u64, 0xff00) >> (extra + 1)) & 0xff;
    try bw.writeBits(lead | (n >> (extra * 6)), 8);
    var i: u6 = extra;
    while (i > 0) {
        i -= 1;
        try bw.writeBits(0x80 | ((n >> (i * 6)) & 0x3f), 8);
    }
}

fn startFrame(bw: *io.BitWriter, s: FrameSpec) !void {
    try bw.writeBits(0b111111111111100, 15);
    try bw.writeBits(@intFromBool(s.variable), 1);
    try bw.writeBits(s.bs_code, 4);
    try bw.writeBits(s.rate_code, 4);
    try bw.writeBits(s.ch_code, 4);
    try bw.writeBits(s.size_code, 3);
    try bw.writeBits(0, 1);
    try writeUtf8(bw, s.number);
    if (s.bs_code == 6) try bw.writeBits(s.bs_field, 8);
    if (s.bs_code == 7) try bw.writeBits(s.bs_field, 16);
    if (s.rate_code == 12) try bw.writeBits(s.rate_field, 8);
    if (s.rate_code == 13 or s.rate_code == 14) try bw.writeBits(s.rate_field, 16);
    try bw.writeBits(crc.flac8.hash(bw.bytes()), 8);
}

fn endFrame(bw: *io.BitWriter) !void {
    try bw.alignByte();
    try bw.writeBits(crc.flac16.hash(bw.bytes()), 16);
}

const InfoSpec = struct {
    min_block: u16,
    max_block: u16,
    channels: u8,
    bps: u8,
    rate: u32 = 44100,
    last: bool = true,
};

fn appendStreamInfo(list: *std.ArrayList(u8), s: InfoSpec) !void {
    const gpa = testing.allocator;
    try list.appendSlice(gpa, "fLaC");
    try list.appendSlice(gpa, &.{ if (s.last) 0x80 else 0x00, 0, 0, 34 });
    var body: [34]u8 = @splat(0);
    std.mem.writeInt(u16, body[0..2], s.min_block, .big);
    std.mem.writeInt(u16, body[2..4], s.max_block, .big);
    const tail = (@as(u64, s.rate) << 44) | (@as(u64, s.channels - 1) << 41) | (@as(u64, s.bps - 1) << 36);
    std.mem.writeInt(u64, body[10..18], tail, .big);
    try list.appendSlice(gpa, &body);
}

fn subframeHead(bw: *io.BitWriter, kind: u6) !void {
    try bw.writeBits(0, 1);
    try bw.writeBits(kind, 6);
    try bw.writeBits(0, 1);
}

test "an LPC subframe of order 20 follows the predictor equation" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(20);
    const rand = prng.random();
    var coefs: [20]i64 = undefined;
    for (&coefs, 0..) |*c, j| c.* = if (j % 4 == 0) 3 else if (j % 4 == 2) -1 else 0;
    var want: [64]i64 = undefined;
    var bw: io.BitWriter = .init(gpa);
    defer bw.deinit();
    try startFrame(&bw, .{ .bs_code = 6, .bs_field = 63, .ch_code = 0, .size_code = 4 });
    try subframeHead(&bw, 32 + 19);
    for (want[0..20]) |*w| {
        w.* = rand.intRangeAtMost(i64, -1000, 1000);
        try bw.writeSigned(w.*, 16);
    }
    try bw.writeBits(7, 4);
    try bw.writeBits(5, 5);
    for (coefs) |c| try bw.writeSigned(c, 8);
    try bw.writeBits(0, 2);
    try bw.writeBits(0, 4);
    try bw.writeBits(3, 4);
    for (20..64) |i| {
        const r = rand.intRangeAtMost(i64, -50, 50);
        var sum: i64 = 0;
        for (coefs, 0..) |c, j| sum += c * want[i - 1 - j];
        want[i] = (sum >> 5) + r;
        try bw.writeRice(r, 3);
    }
    try endFrame(&bw);

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try appendStreamInfo(&list, .{ .min_block = 64, .max_block = 64, .channels = 1, .bps = 16 });
    try list.appendSlice(gpa, bw.bytes());
    var input: io.Input = .init(.{ .bytes = list.items });
    var dec = try Decoder.init(gpa, &input);
    defer dec.deinit();
    var got: [64]i32 = undefined;
    try testing.expectEqual(@as(usize, 64), try dec.readInt(&got));
    for (want, got) |w, g| try testing.expectEqual(w, g);
    try testing.expectEqual(@as(usize, 0), try dec.readInt(&got));
}

test "block size 65535 decodes and 65536 is rejected" {
    const gpa = testing.allocator;
    var bw: io.BitWriter = .init(gpa);
    defer bw.deinit();
    try startFrame(&bw, .{ .variable = true, .bs_code = 7, .bs_field = 0xfffe, .ch_code = 1, .size_code = 4 });
    for ([_]i64{ -3, 1234 }) |v| {
        try subframeHead(&bw, 0);
        try bw.writeSigned(v, 16);
    }
    try endFrame(&bw);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try appendStreamInfo(&list, .{ .min_block = 16, .max_block = 65535, .channels = 2, .bps = 16 });
    try list.appendSlice(gpa, bw.bytes());
    var input: io.Input = .init(.{ .bytes = list.items });
    var dec = try Decoder.init(gpa, &input);
    defer dec.deinit();
    const out = try readAllInts(gpa, &dec, 70000);
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 65535 * 2), out.len);
    try testing.expectEqual(@as(i32, -3), out[0]);
    try testing.expectEqual(@as(i32, 1234), out[out.len - 1]);

    var bad: io.BitWriter = .init(gpa);
    defer bad.deinit();
    try startFrame(&bad, .{ .variable = true, .bs_code = 7, .bs_field = 0xffff, .ch_code = 1, .size_code = 4 });
    var list2: std.ArrayList(u8) = .empty;
    defer list2.deinit(gpa);
    try appendStreamInfo(&list2, .{ .min_block = 16, .max_block = 65535, .channels = 2, .bps = 16 });
    try list2.appendSlice(gpa, bad.bytes());
    var input2: io.Input = .init(.{ .bytes = list2.items });
    var dec2 = try Decoder.initOptions(gpa, &input2, .{ .on_bad_frame = .fail });
    defer dec2.deinit();
    var one: [2]i32 = undefined;
    try testing.expectError(error.BadData, dec2.readInt(&one));
}

test "rice partition orders 12 and 15 decode" {
    const gpa = testing.allocator;
    for ([_]struct { method: u2, order: u4, k: u6 }{ .{ .method = 1, .order = 12, .k = 2 }, .{ .method = 0, .order = 15, .k = 1 }, .{ .method = 0, .order = 9, .k = 0 } }) |t| {
        var bw: io.BitWriter = .init(gpa);
        defer bw.deinit();
        try startFrame(&bw, .{ .bs_code = 15, .ch_code = 0, .size_code = 4 });
        try subframeHead(&bw, 8);
        try bw.writeBits(t.method, 2);
        try bw.writeBits(t.order, 4);
        const parts = @as(usize, 1) << t.order;
        const per = 32768 / parts;
        var want: [32768]i32 = undefined;
        for (0..parts) |p| {
            try bw.writeBits(t.k, if (t.method == 0) 4 else 5);
            for (0..per) |i| {
                const r: i32 = @intCast(((p * per + i) * 7) % 13);
                want[p * per + i] = r - 6;
                try bw.writeRice(r - 6, t.k);
            }
        }
        try endFrame(&bw);
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(gpa);
        try appendStreamInfo(&list, .{ .min_block = 32768, .max_block = 32768, .channels = 1, .bps = 16 });
        try list.appendSlice(gpa, bw.bytes());
        var input: io.Input = .init(.{ .bytes = list.items });
        var dec = try Decoder.init(gpa, &input);
        defer dec.deinit();
        const out = try readAllInts(gpa, &dec, 40000);
        defer gpa.free(out);
        try testing.expectEqualSlices(i32, &want, out);
    }
}

test "32 bit stereo decorrelation uses a 33 bit side channel" {
    const gpa = testing.allocator;
    const max = std.math.maxInt(i32);
    const min = std.math.minInt(i32);
    const left = [16]i64{ max, min, 0, -1, max, min, 5, 7, max, 0, min, 1, 2, 3, -4, -5 };
    const right = [16]i64{ min, max, 0, 5, max, min, -9, 7, 0, min, max, -1, -2, 3, 4, -5 };
    for ([_]u4{ 8, 9, 10 }) |ch_code| {
        var bw: io.BitWriter = .init(gpa);
        defer bw.deinit();
        try startFrame(&bw, .{ .bs_code = 6, .bs_field = 15, .ch_code = ch_code, .size_code = 7 });
        for (0..2) |c| {
            try subframeHead(&bw, 1);
            for (left, right) |l, r| {
                const side = l - r;
                const mid = (l + r) >> 1;
                const v: i64, const bits: u6 = switch (ch_code) {
                    8 => if (c == 0) .{ l, 32 } else .{ side, 33 },
                    9 => if (c == 0) .{ side, 33 } else .{ r, 32 },
                    else => if (c == 0) .{ mid, 32 } else .{ side, 33 },
                };
                try bw.writeSigned(v, bits);
            }
        }
        try endFrame(&bw);
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(gpa);
        try appendStreamInfo(&list, .{ .min_block = 16, .max_block = 16, .channels = 2, .bps = 32 });
        try list.appendSlice(gpa, bw.bytes());
        var input: io.Input = .init(.{ .bytes = list.items });
        var dec = try Decoder.init(gpa, &input);
        defer dec.deinit();
        const out = try readAllInts(gpa, &dec, 100);
        defer gpa.free(out);
        try testing.expectEqual(@as(usize, 32), out.len);
        for (0..16) |i| {
            try testing.expectEqual(@as(i32, @intCast(left[i])), out[i * 2]);
            try testing.expectEqual(@as(i32, @intCast(right[i])), out[i * 2 + 1]);
        }
    }
}

test "a short block must be the last one" {
    const gpa = testing.allocator;
    var bw: io.BitWriter = .init(gpa);
    defer bw.deinit();
    try startFrame(&bw, .{ .bs_code = 6, .bs_field = 11, .ch_code = 0, .size_code = 4 });
    try subframeHead(&bw, 0);
    try bw.writeSigned(9, 16);
    try endFrame(&bw);
    var tail: io.BitWriter = .init(gpa);
    defer tail.deinit();
    try startFrame(&tail, .{ .bs_code = 6, .bs_field = 15, .ch_code = 0, .size_code = 4 });
    try subframeHead(&tail, 0);
    try tail.writeSigned(9, 16);
    try endFrame(&tail);

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try appendStreamInfo(&list, .{ .min_block = 16, .max_block = 16, .channels = 1, .bps = 16 });
    try list.appendSlice(gpa, bw.bytes());
    var alone: io.Input = .init(.{ .bytes = list.items });
    var one = try Decoder.init(gpa, &alone);
    defer one.deinit();
    const ok = try readAllInts(gpa, &one, 100);
    defer gpa.free(ok);
    try testing.expectEqual(@as(usize, 12), ok.len);

    try list.appendSlice(gpa, tail.bytes());
    var input: io.Input = .init(.{ .bytes = list.items });
    var dec = try Decoder.initOptions(gpa, &input, .{ .on_bad_frame = .fail });
    defer dec.deinit();
    var buf: [100]i32 = undefined;
    try testing.expectEqual(@as(usize, 12), try dec.readInt(&buf));
    try testing.expectError(error.BadData, dec.readInt(&buf));
}

fn appendBlock(list: *std.ArrayList(u8), kind: u8, last: bool, body: []const u8) !void {
    const gpa = testing.allocator;
    try list.append(gpa, kind | if (last) @as(u8, 0x80) else 0);
    var len: [3]u8 = undefined;
    std.mem.writeInt(u24, &len, @intCast(body.len), .big);
    try list.appendSlice(gpa, &len);
    try list.appendSlice(gpa, body);
}

fn vorbisComment(list: *std.ArrayList(u8), comments: []const []const u8) !void {
    const gpa = testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, 3, .little);
    try body.appendSlice(gpa, &n);
    try body.appendSlice(gpa, "abc");
    std.mem.writeInt(u32, &n, @intCast(comments.len), .little);
    try body.appendSlice(gpa, &n);
    for (comments) |c| {
        std.mem.writeInt(u32, &n, @intCast(c.len), .little);
        try body.appendSlice(gpa, &n);
        try body.appendSlice(gpa, c);
    }
    try appendBlock(list, 4, true, body.items);
}

test "metadata of unknown and unused types is skipped" {
    const gpa = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "ID3\x04\x00\x00\x00\x00\x00\x05\x00\x00\x00\x00\x00");
    try appendStreamInfo(&list, .{ .min_block = 16, .max_block = 16, .channels = 6, .bps = 24, .rate = 48000, .last = false });
    try appendBlock(&list, 2, false, "appl1234");
    try appendBlock(&list, 5, false, "cue sheet data");
    try appendBlock(&list, 6, false, "picture");
    try appendBlock(&list, 100, false, "reserved");
    try appendBlock(&list, 1, false, &@as([20]u8, @splat(0)));
    try vorbisComment(&list, &.{ "TITLE=x", "waveformatextensible_channel_mask=0x3F" });
    var input: io.Input = .init(.{ .bytes = list.items });
    var dec = try Decoder.init(gpa, &input);
    defer dec.deinit();
    const info = dec.info();
    try testing.expectEqual(@as(u32, 48000), info.rate);
    try testing.expectEqual(@as(u8, 6), info.channels);
    try testing.expectEqual(@as(u8, 24), info.bits_per_sample);
    try testing.expectEqual(@as(u32, 0x3f), @as(u32, @bitCast(info.mask)));
    var buf: [6]i32 = undefined;
    try testing.expectEqual(@as(usize, 0), try dec.readInt(&buf));
    try testing.expectEqual(@as(?bool, null), dec.md5Matches());
}

test "a channel mask that does not fit the channel count is ignored" {
    const gpa = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try appendStreamInfo(&list, .{ .min_block = 16, .max_block = 16, .channels = 6, .bps = 16, .last = false });
    try vorbisComment(&list, &.{"WAVEFORMATEXTENSIBLE_CHANNEL_MASK=0x3"});
    var input: io.Input = .init(.{ .bytes = list.items });
    var dec = try Decoder.init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(u32, 0x60f), @as(u32, @bitCast(dec.info().mask)));
}

test "metadata errors are BadHeader" {
    const gpa = testing.allocator;
    // Reserved block type 127.
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    try appendStreamInfo(&a, .{ .min_block = 16, .max_block = 16, .channels = 1, .bps = 16, .last = false });
    try appendBlock(&a, 127, true, "");
    // A second STREAMINFO.
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try appendStreamInfo(&b, .{ .min_block = 16, .max_block = 16, .channels = 1, .bps = 16, .last = false });
    try appendBlock(&b, 0, true, &@as([34]u8, @splat(0)));
    // A seek table that is not a multiple of 18 bytes.
    var c: std.ArrayList(u8) = .empty;
    defer c.deinit(gpa);
    try appendStreamInfo(&c, .{ .min_block = 16, .max_block = 16, .channels = 1, .bps = 16, .last = false });
    try appendBlock(&c, 3, true, &@as([20]u8, @splat(0)));
    // A seek table that is not ascending.
    var d: std.ArrayList(u8) = .empty;
    defer d.deinit(gpa);
    try appendStreamInfo(&d, .{ .min_block = 16, .max_block = 16, .channels = 1, .bps = 16, .last = false });
    var points: [36]u8 = @splat(0);
    points[7] = 9;
    points[25] = 9;
    try appendBlock(&d, 3, true, &points);
    // A vorbis comment with more comments than data.
    var e: std.ArrayList(u8) = .empty;
    defer e.deinit(gpa);
    try appendStreamInfo(&e, .{ .min_block = 16, .max_block = 16, .channels = 1, .bps = 16, .last = false });
    try appendBlock(&e, 4, true, "\x00\x00\x00\x00\x09\x00\x00\x00");
    // A block that is longer than the data.
    var f: std.ArrayList(u8) = .empty;
    defer f.deinit(gpa);
    try appendStreamInfo(&f, .{ .min_block = 16, .max_block = 16, .channels = 1, .bps = 16, .last = false });
    try f.appendSlice(gpa, &.{ 0x01, 0xff, 0xff, 0xff });
    for ([_][]const u8{ a.items, b.items, c.items, d.items, e.items }) |bytes| {
        var input: io.Input = .init(.{ .bytes = bytes });
        try testing.expectError(error.BadHeader, Decoder.init(gpa, &input));
    }
    var input: io.Input = .init(.{ .bytes = f.items });
    try testing.expectError(error.Truncated, Decoder.init(gpa, &input));
}

test "seek points skip placeholders" {
    const gpa = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try appendStreamInfo(&list, .{ .min_block = 16, .max_block = 16, .channels = 1, .bps = 16, .last = false });
    var points: [54]u8 = @splat(0);
    std.mem.writeInt(u64, points[18..26], 16, .big);
    std.mem.writeInt(u64, points[26..34], 100, .big);
    @memset(points[36..44], 0xff);
    try appendBlock(&list, 3, true, &points);
    var input: io.Input = .init(.{ .bytes = list.items });
    var dec = try Decoder.init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(usize, 2), dec.seekPoints().len);
    try testing.expectEqual(@as(u64, 16), dec.seekPoints()[1].sample);
    try testing.expectEqual(@as(u64, 100), dec.seekPoints()[1].offset);
}

test "every block size code and sample rate code decodes" {
    const gpa = testing.allocator;
    const sizes = [_]struct { code: u4, size: usize }{
        .{ .code = 1, .size = 192 },    .{ .code = 2, .size = 576 },   .{ .code = 3, .size = 1152 },
        .{ .code = 4, .size = 2304 },   .{ .code = 5, .size = 4608 },  .{ .code = 8, .size = 256 },
        .{ .code = 9, .size = 512 },    .{ .code = 10, .size = 1024 }, .{ .code = 11, .size = 2048 },
        .{ .code = 12, .size = 4096 },  .{ .code = 13, .size = 8192 }, .{ .code = 14, .size = 16384 },
        .{ .code = 15, .size = 32768 },
    };
    for (sizes) |s| {
        var bw: io.BitWriter = .init(gpa);
        defer bw.deinit();
        try startFrame(&bw, .{ .bs_code = s.code, .ch_code = 0, .size_code = 4 });
        try subframeHead(&bw, 0);
        try bw.writeSigned(-7, 16);
        try endFrame(&bw);
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(gpa);
        try appendStreamInfo(&list, .{ .min_block = 16, .max_block = 32768, .channels = 1, .bps = 16 });
        try list.appendSlice(gpa, bw.bytes());
        var input: io.Input = .init(.{ .bytes = list.items });
        var dec = try Decoder.init(gpa, &input);
        defer dec.deinit();
        const out = try readAllInts(gpa, &dec, 40000);
        defer gpa.free(out);
        try testing.expectEqual(s.size, out.len);
        try testing.expectEqual(@as(i32, -7), out[out.len - 1]);
    }
    const rates = [_]struct { code: u4, field: u16 = 0, rate: u32 }{
        .{ .code = 1, .rate = 88200 },                  .{ .code = 2, .rate = 176400 },
        .{ .code = 3, .rate = 192000 },                 .{ .code = 4, .rate = 8000 },
        .{ .code = 5, .rate = 16000 },                  .{ .code = 6, .rate = 22050 },
        .{ .code = 7, .rate = 24000 },                  .{ .code = 8, .rate = 32000 },
        .{ .code = 9, .rate = 44100 },                  .{ .code = 10, .rate = 48000 },
        .{ .code = 11, .rate = 96000 },                 .{ .code = 12, .field = 39, .rate = 39000 },
        .{ .code = 13, .field = 35467, .rate = 35467 }, .{ .code = 14, .field = 13456, .rate = 134560 },
    };
    for (rates) |r| {
        var bw: io.BitWriter = .init(gpa);
        defer bw.deinit();
        try startFrame(&bw, .{ .bs_code = 1, .rate_code = r.code, .rate_field = r.field, .ch_code = 0, .size_code = 4 });
        try subframeHead(&bw, 0);
        try bw.writeSigned(3, 16);
        try endFrame(&bw);
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(gpa);
        try appendStreamInfo(&list, .{ .min_block = 192, .max_block = 192, .channels = 1, .bps = 16, .rate = r.rate });
        try list.appendSlice(gpa, bw.bytes());
        var input: io.Input = .init(.{ .bytes = list.items });
        var dec = try Decoder.init(gpa, &input);
        defer dec.deinit();
        var buf: [192]i32 = undefined;
        try testing.expectEqual(@as(usize, 192), try dec.readInt(&buf));

        // A different rate in STREAMINFO is a stream change.
        list.items[4 + 4 + 11] ^= 0x10;
        var input2: io.Input = .init(.{ .bytes = list.items });
        var dec2 = try Decoder.initOptions(gpa, &input2, .{ .on_bad_frame = .fail });
        defer dec2.deinit();
        try testing.expectError(error.BadData, dec2.readInt(&buf));
    }
}

fn patchTotal(data: []u8, total: u64) void {
    // The total is the low 36 bits of the eight bytes at 10 in the STREAMINFO body at 8.
    data[8 + 13] = (data[8 + 13] & 0xf0) | @as(u8, @intCast(total >> 32));
    std.mem.writeInt(u32, data[8 + 14 ..][0..4], @truncate(total), .big);
}

test "frames larger than the STREAMINFO maximum are counted unless strict" {
    var input: io.Input = .init(.{ .bytes = embed("f02-wrong-max-framesize") });
    var dec = try Decoder.init(testing.allocator, &input);
    defer dec.deinit();
    var hash: std.crypto.hash.Md5 = .init(.{});
    var frames: u64 = 0;
    // The cut file keeps the total of the whole source file, so it ends early.
    try testing.expectError(error.Truncated, drain(&dec, 1000, &hash, &frames));
    try testing.expectEqual(@as(u64, 36864), frames);
    try testing.expect(dec.stats().oversized_frames > 0);
}

test "samples past the STREAMINFO total are counted unless strict" {
    var input: io.Input = .init(.{ .bytes = embed("f05-wrong-total-samples") });
    var dec = try Decoder.init(testing.allocator, &input);
    defer dec.deinit();
    var hash: std.crypto.hash.Md5 = .init(.{});
    var frames: u64 = 0;
    try drain(&dec, 1000, &hash, &frames);
    try testing.expectEqual(@as(u64, 40960), frames);
    try testing.expectEqual(@as(u64, 40960 - 39842), dec.stats().excess_samples);
    try testing.expectEqual(@as(?bool, false), dec.md5Matches());
}

test "a nonzero total gives the end, seeks to the end and errors past it" {
    for ([_][]const u8{ embed("s02-blocksize-4608"), embed("s38-channels-3") }, [_]u64{ 9216, 57344 }) |data, total| {
        const copy = try testing.allocator.dupe(u8, data);
        defer testing.allocator.free(copy);
        patchTotal(copy, total);
        var input: io.Input = .init(.{ .bytes = copy });
        var dec = try Decoder.init(testing.allocator, &input);
        defer dec.deinit();
        try testing.expectEqual(@as(?u64, total), dec.info().total_frames);
        const channels: usize = dec.info().channels;
        const all = try readAllInts(testing.allocator, &dec, 1 << 20);
        defer testing.allocator.free(all);
        try testing.expectEqual(total * channels, all.len);
        var buf: [3 * 8]i32 = undefined;
        try testing.expectEqual(@as(usize, 0), try dec.readInt(&buf));

        try dec.seek(total);
        try testing.expectEqual(@as(usize, 0), try dec.readInt(&buf));
        try dec.seek(total - 3);
        try testing.expectEqual(@as(usize, 3), try dec.readInt(buf[0 .. 3 * channels]));
        try testing.expectEqualSlices(i32, all[@as(usize, @intCast(total - 3)) * channels ..], buf[0 .. 3 * channels]);
        try dec.seek(100);
        try testing.expectEqual(@as(usize, 8), try dec.readInt(buf[0 .. 8 * channels]));
        try testing.expectEqualSlices(i32, all[100 * channels ..][0 .. 8 * channels], buf[0 .. 8 * channels]);

        // A failed seek leaves no samples to read.
        try testing.expectError(error.Truncated, dec.seek(total + 1));
        try testing.expectError(error.Truncated, dec.readInt(&buf));
        try dec.seek(0);
        try testing.expectEqual(@as(usize, 8), try dec.readInt(buf[0 .. 8 * channels]));
    }
}

test "a failed seek in a stream without a total resets the position" {
    var input: io.Input = .init(.{ .bytes = embed("s02-blocksize-4608") });
    var dec = try Decoder.init(testing.allocator, &input);
    defer dec.deinit();
    var buf: [2 * 8]i32 = undefined;
    try dec.seek(100);
    try testing.expectEqual(@as(usize, 8), try dec.readInt(&buf));
    try testing.expectError(error.Truncated, dec.seek(100000));
    try testing.expectError(error.Truncated, dec.readInt(&buf));
    try dec.seek(100);
    try testing.expectEqual(@as(usize, 8), try dec.readInt(&buf));
}

test "a seek point that does not match its frame is ignored" {
    const data = embed("s01-blocksize-4096");
    for ([_]struct { sample: u64, offset: u64 }{ .{ .sample = 8192, .offset = 0 }, .{ .sample = 4096, .offset = 3 }, .{ .sample = 4096, .offset = 5000 } }) |p| {
        const copy = try testing.allocator.dupe(u8, data);
        defer testing.allocator.free(copy);
        // The only seek point starts at byte 46, after the STREAMINFO block.
        std.mem.writeInt(u64, copy[46..54], p.sample, .big);
        std.mem.writeInt(u64, copy[54..62], p.offset, .big);
        try expectSeeksMatch(copy, &.{ 0, 4096, 5000, 12345, 20000, 24575 });
    }
}

test "trailing ID3v1 and APE tags end the stream" {
    const id3 = "TAG".* ++ @as([125]u8, @splat(0));
    const ape = "APETAGEX".* ++ @as([24]u8, @splat(0));
    for ([_][]const u8{ &id3, &ape }) |tag| {
        const base = embed("s02-blocksize-4608");
        const copy = try testing.allocator.alloc(u8, base.len + tag.len);
        defer testing.allocator.free(copy);
        @memcpy(copy[0..base.len], base);
        @memcpy(copy[base.len..], tag);
        var input: io.Input = .init(.{ .bytes = copy });
        var dec = try Decoder.init(testing.allocator, &input);
        defer dec.deinit();
        var hash: std.crypto.hash.Md5 = .init(.{});
        var frames: u64 = 0;
        try drain(&dec, 1000, &hash, &frames);
        try testing.expectEqual(@as(u64, 9216), frames);
        var digest: [16]u8 = undefined;
        hash.final(&digest);
        try expectHex(find("s02-blocksize-4608").md5, digest);
        var one: [2]i32 = undefined;
        try testing.expectEqual(@as(usize, 0), try dec.readInt(&one));
    }
    // Other bytes after the last frame are an error.
    const base = embed("s02-blocksize-4608");
    const copy = try testing.allocator.alloc(u8, base.len + 8);
    defer testing.allocator.free(copy);
    @memcpy(copy[0..base.len], base);
    @memcpy(copy[base.len..], "TAx!abcd");
    var input: io.Input = .init(.{ .bytes = copy });
    var dec = try Decoder.initOptions(testing.allocator, &input, .{ .on_bad_frame = .fail });
    defer dec.deinit();
    var hash: std.crypto.hash.Md5 = .init(.{});
    var frames: u64 = 0;
    try testing.expectError(error.BadData, drain(&dec, 1000, &hash, &frames));
    try testing.expectEqual(@as(u64, 9216), frames);

    // The default skips the bytes and ends the stream.
    var input2: io.Input = .init(.{ .bytes = copy });
    var dec2 = try Decoder.init(testing.allocator, &input2);
    defer dec2.deinit();
    var hash2: std.crypto.hash.Md5 = .init(.{});
    var frames2: u64 = 0;
    try drain(&dec2, 1000, &hash2, &frames2);
    try testing.expectEqual(@as(u64, 9216), frames2);
    try testing.expectEqual(@as(u32, 1), dec2.stats().resyncs);
    try testing.expectEqual(@as(u64, 8), dec2.stats().skipped_bytes);
}

test "stereo decorrelation that leaves the sample depth is clamped on output and counted" {
    const gpa = testing.allocator;
    // The pairs are (left, side) with side = left - right, and right = left - side.
    const pairs = [_][2]i64{ .{ 32767, -10 }, .{ -32768, 10 }, .{ 100, 5 }, .{ -32768, 0 } };
    const true_right = [_]i64{ 32777, -32778, 95, -32768 };
    var bw: io.BitWriter = .init(gpa);
    defer bw.deinit();
    try startFrame(&bw, .{ .bs_code = 6, .bs_field = 15, .ch_code = 8, .size_code = 4 });
    try subframeHead(&bw, 1);
    for (0..16) |i| try bw.writeSigned(if (i < pairs.len) pairs[i][0] else 0, 16);
    try subframeHead(&bw, 1);
    for (0..16) |i| try bw.writeSigned(if (i < pairs.len) pairs[i][1] else 0, 17);
    try endFrame(&bw);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try appendStreamInfo(&list, .{ .min_block = 16, .max_block = 16, .channels = 2, .bps = 16 });
    try list.appendSlice(gpa, bw.bytes());

    var input: io.Input = .init(.{ .bytes = list.items });
    var dec = try Decoder.init(gpa, &input);
    defer dec.deinit();
    var ints: [32]i32 = undefined;
    try testing.expectEqual(@as(usize, 16), try dec.readInt(&ints));
    try testing.expectEqualSlices(i32, &.{ 32767, 32767, -32768, -32768, 100, 95, -32768, -32768 }, ints[0..8]);
    try testing.expectEqual(@as(u64, 2), dec.stats().clipped_samples);
    // The block keeps the true values, and the MD5 uses them.
    for (true_right, 0..) |r, i| try testing.expectEqual(r, dec.core.chan(1)[i]);

    var input2: io.Input = .init(.{ .bytes = list.items });
    var dec2 = try Decoder.init(gpa, &input2);
    defer dec2.deinit();
    var floats: [32]f32 = undefined;
    try testing.expectEqual(@as(usize, 16), try dec2.read(&floats));
    try testing.expectEqual(@as(f32, 32767.0 / 32768.0), floats[0]);
    try testing.expectEqual(max_below_one, floats[1]);
    try testing.expectEqual(@as(f32, -1.0), floats[2]);
    try testing.expectEqual(@as(f32, -1.0), floats[3]);
    for (floats) |x| try testing.expect(x >= -1.0 and x < 1.0);
}

test "mid side decorrelation that leaves the sample depth is clamped" {
    const gpa = testing.allocator;
    var bw: io.BitWriter = .init(gpa);
    defer bw.deinit();
    try startFrame(&bw, .{ .bs_code = 6, .bs_field = 15, .ch_code = 10, .size_code = 4 });
    // mid 32767 and side 30000 give left 47767 and right 17767.
    try subframeHead(&bw, 1);
    for (0..16) |i| try bw.writeSigned(if (i == 0) 32767 else 0, 16);
    try subframeHead(&bw, 1);
    for (0..16) |i| try bw.writeSigned(if (i == 0) 30000 else 0, 17);
    try endFrame(&bw);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try appendStreamInfo(&list, .{ .min_block = 16, .max_block = 16, .channels = 2, .bps = 16 });
    try list.appendSlice(gpa, bw.bytes());
    var input: io.Input = .init(.{ .bytes = list.items });
    var dec = try Decoder.init(gpa, &input);
    defer dec.deinit();
    var ints: [32]i32 = undefined;
    try testing.expectEqual(@as(usize, 16), try dec.readInt(&ints));
    try testing.expectEqualSlices(i32, &.{ 32767, 17767 }, ints[0..2]);
    try testing.expectEqual(@as(u64, 1), dec.stats().clipped_samples);
}

test "f32 output stays below 1.0 at full scale" {
    const gpa = testing.allocator;
    for ([_]struct { bps: u8, size_code: u3, max: i64, min: i64, top: f32 }{
        .{ .bps = 32, .size_code = 7, .max = std.math.maxInt(i32), .min = std.math.minInt(i32), .top = 0x1.fffffep-1 },
        .{ .bps = 24, .size_code = 6, .max = (1 << 23) - 1, .min = -(1 << 23), .top = 1.0 - 0x1p-23 },
    }) |t| {
        var bw: io.BitWriter = .init(gpa);
        defer bw.deinit();
        try startFrame(&bw, .{ .bs_code = 6, .bs_field = 15, .ch_code = 1, .size_code = t.size_code });
        try subframeHead(&bw, 0);
        try bw.writeSigned(t.max, @intCast(t.bps));
        try subframeHead(&bw, 0);
        try bw.writeSigned(t.min, @intCast(t.bps));
        try endFrame(&bw);
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(gpa);
        try appendStreamInfo(&list, .{ .min_block = 16, .max_block = 16, .channels = 2, .bps = t.bps });
        try list.appendSlice(gpa, bw.bytes());
        var input: io.Input = .init(.{ .bytes = list.items });
        var dec = try Decoder.init(gpa, &input);
        defer dec.deinit();
        var out: [32]f32 = undefined;
        try testing.expectEqual(@as(usize, 16), try dec.read(&out));
        try testing.expectEqual(t.top, out[0]);
        try testing.expect(out[0] < 1.0);
        try testing.expectEqual(@as(f32, -1.0), out[1]);
    }
}

test "a predictor order that is not smaller than the block size is rejected" {
    const gpa = testing.allocator;
    for ([_]struct { kind: u6, order: usize, ok: bool }{
        .{ .kind = 8 + 3, .order = 3, .ok = true },
        .{ .kind = 8 + 4, .order = 4, .ok = false },
        .{ .kind = 32 + 3, .order = 4, .ok = false },
    }) |t| {
        var bw: io.BitWriter = .init(gpa);
        defer bw.deinit();
        try startFrame(&bw, .{ .bs_code = 6, .bs_field = 3, .ch_code = 0, .size_code = 4 });
        try subframeHead(&bw, t.kind);
        for (0..t.order) |_| try bw.writeSigned(5, 16);
        if (t.kind >= 32) {
            try bw.writeBits(3, 4);
            try bw.writeBits(0, 5);
            for (0..t.order) |_| try bw.writeSigned(1, 4);
        }
        try bw.writeBits(0, 2);
        try bw.writeBits(0, 4);
        try bw.writeBits(0, 4);
        if (t.order < 4) try bw.writeRice(0, 0);
        try endFrame(&bw);
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(gpa);
        try appendStreamInfo(&list, .{ .min_block = 16, .max_block = 16, .channels = 1, .bps = 16 });
        try list.appendSlice(gpa, bw.bytes());
        var input: io.Input = .init(.{ .bytes = list.items });
        var dec = try Decoder.initOptions(gpa, &input, .{ .on_bad_frame = .fail });
        defer dec.deinit();
        var buf: [8]i32 = undefined;
        if (t.ok) {
            try testing.expectEqual(@as(usize, 4), try dec.readInt(&buf));
        } else {
            try testing.expectError(error.BadData, dec.readInt(&buf));
        }
    }
}

test "seeking a large file bisects with few seeks on the input" {
    if (!io.has_files) return error.SkipZigTest;
    const gpa = testing.allocator;
    const frames = 200;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try appendStreamInfo(&list, .{ .min_block = 1024, .max_block = 1024, .channels = 1, .bps = 16 });
    for (0..frames) |f| {
        var bw: io.BitWriter = .init(gpa);
        defer bw.deinit();
        try startFrame(&bw, .{ .number = @intCast(f), .bs_code = 10, .ch_code = 0, .size_code = 4 });
        try subframeHead(&bw, 1);
        for (0..1024) |i| try bw.writeSigned(@as(i64, @intCast((f * 1024 + i) % 30000)) - 15000, 16);
        try endFrame(&bw);
        try list.appendSlice(gpa, bw.bytes());
    }
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big.flac", .data = list.items });
    var file = try tmp.dir.openFile(testing.io, "big.flac", .{});
    defer file.close(testing.io);
    var fbuf: [512]u8 = undefined;
    var fr = file.reader(testing.io, &fbuf);
    var input: io.Input = .init(.{ .file = &fr });
    var dec = try Decoder.init(gpa, &input);
    defer dec.deinit();
    var buf: [100]i32 = undefined;
    for ([_]u64{ 150 * 1024 + 17, 3 * 1024 + 1000, 199 * 1024 + 5 }) |target| {
        const before = dec.stats().input_seeks;
        try dec.seek(target);
        try testing.expect(dec.stats().input_seeks - before <= 16);
        try testing.expectEqual(@as(usize, 100), try dec.readInt(&buf));
        for (buf, 0..) |v, i| try testing.expectEqual(@as(i32, @intCast((target + i) % 30000)) - 15000, v);
    }
    try testing.expect(dec.stats().input_seeks <= 40);
}

test "seeking to the total ends the stream" {
    const base = embed("s02-blocksize-4608");
    const copy = try testing.allocator.dupe(u8, base);
    defer testing.allocator.free(copy);
    patchTotal(copy, 9216);
    var buf: [2 * 8]i32 = undefined;

    var input: io.Input = .init(.{ .bytes = copy });
    var fresh = try Decoder.init(testing.allocator, &input);
    defer fresh.deinit();
    try fresh.seek(9216);
    try testing.expectEqual(@as(usize, 0), try fresh.readInt(&buf));

    var input2: io.Input = .init(.{ .bytes = copy });
    var moved = try Decoder.init(testing.allocator, &input2);
    defer moved.deinit();
    try moved.seek(100);
    try testing.expectEqual(@as(usize, 8), try moved.readInt(&buf));
    try moved.seek(9216);
    try testing.expectEqual(@as(usize, 0), try moved.readInt(&buf));
}

test "seeking does not change the stats" {
    var input: io.Input = .init(.{ .bytes = embed("f05-wrong-total-samples") });
    var dec = try Decoder.init(testing.allocator, &input);
    defer dec.deinit();
    try dec.seek(38000);
    try testing.expectEqual(@as(u64, 0), dec.stats().excess_samples);
    try testing.expectEqual(@as(u32, 0), dec.stats().crc_errors);
}
