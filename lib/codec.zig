//! Audio codecs and containers: WAV, FLAC, Ogg Vorbis and Opus.
const std = @import("std");

pub const io = @import("codec/io.zig");
pub const crc = @import("codec/crc.zig");
pub const flac = @import("codec/flac.zig");
pub const ogg = @import("codec/ogg.zig");
pub const opus = @import("codec/opus.zig");
pub const pcm = @import("codec/pcm.zig");
pub const resample = @import("codec/resample.zig");
pub const vorbis = @import("codec/vorbis.zig");
pub const vorbis_comment = @import("codec/vorbis_comment.zig");
pub const wav = @import("codec/wav.zig");
pub const Decoder = @import("codec/Decoder.zig");
pub const Encoder = @import("codec/Encoder.zig");

/// WAVE speaker positions. Bit i is the i-th channel in interleave order.
pub const ChannelMask = packed struct(u32) {
    front_left: bool = false,
    front_right: bool = false,
    front_center: bool = false,
    low_frequency: bool = false,
    back_left: bool = false,
    back_right: bool = false,
    front_left_of_center: bool = false,
    front_right_of_center: bool = false,
    back_center: bool = false,
    side_left: bool = false,
    side_right: bool = false,
    top_center: bool = false,
    top_front_left: bool = false,
    top_front_center: bool = false,
    top_front_right: bool = false,
    top_back_left: bool = false,
    top_back_center: bool = false,
    top_back_right: bool = false,
    reserved: u13 = 0,
    all: bool = false,
};

pub const Info = struct {
    /// Frames per second.
    rate: u32,
    channels: u8,
    /// The speaker positions. A decoder always sets it. An encoder takes 0 as the default
    /// mask of the channel count.
    mask: ChannelMask = .{},
    /// The frame count when the stream states it. A decoder can return more frames than
    /// this when the format allows it, for example FLAC without `strict_metadata`.
    /// An encoder ignores it.
    total_frames: ?u64 = null,
    /// The sample depth of the stream. 0 means that the codec is lossy or that no depth
    /// applies. Float formats give 32 or 64. An encoder ignores it.
    bits_per_sample: u8 = 0,
};

/// A forward-only reader cannot seek. A file reader seeks when the file allows it.
/// Format sniffing with `.auto` peeks 16 bytes, so a reader needs a buffer of that size.
/// A custom source seeks and starts at offset 0. Its reader should buffer, because the decoders
/// read small pieces.
pub const Source = union(enum) {
    bytes: []const u8,
    reader: *std.Io.Reader,
    file: *std.Io.File.Reader,
    custom: *const SeekableSource,
};

/// A seekable byte source that the caller implements. `ctx` goes to every function.
pub const SeekableSource = struct {
    ctx: ?*anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Reads up to `buf.len` bytes at the current position. 0 means the end.
        read: *const fn (ctx: ?*anyopaque, buf: []u8) error{ReadFailed}!usize,
        /// Moves to an absolute offset. The caller checks it against `length` first.
        seekTo: *const fn (ctx: ?*anyopaque, offset: u64) error{ ReadFailed, Unseekable }!void,
        /// The size in bytes when it is known.
        length: *const fn (ctx: ?*anyopaque) ?u64,
    };

    pub fn read(self: *const SeekableSource, buf: []u8) error{ReadFailed}!usize {
        return self.vtable.read(self.ctx, buf);
    }

    pub fn seekTo(self: *const SeekableSource, offset: u64) error{ ReadFailed, Unseekable }!void {
        return self.vtable.seekTo(self.ctx, offset);
    }

    pub fn length(self: *const SeekableSource) ?u64 {
        return self.vtable.length(self.ctx);
    }
};

/// `.auto` picks the format from the first bytes. `.ogg` is any Ogg codec, which the first
/// packet of the first stream selects. `.ogg_flac`, `.ogg_vorbis` and `.ogg_opus` follow the first
/// stream of that codec.
pub const Format = enum { auto, wav, flac, ogg, ogg_flac, ogg_vorbis, ogg_opus };

pub const EncodeOptions = union(enum) {
    wav: struct { sample: pcm.Sample = .s16 },
    flac: struct { level: u4 = 5, bits: u8 = 16 },
    ogg_flac: struct { level: u4 = 5, bits: u8 = 16, serial: u32 = 0 },
    ogg_vorbis: vorbis.EncodeOptions,
    ogg_opus: opus.EncodeOptions,
};

pub const InitError = error{ OutOfMemory, Unsupported, BadHeader, BadData, Truncated, ReadFailed };
pub const EncoderInitError = error{ OutOfMemory, Unsupported };
/// The errors of decoding the packets of a stream.
pub const DecodeError = error{ BadData, Truncated, ReadFailed };
pub const ReadError = DecodeError || error{StreamChanged};
pub const SeekError = error{ OutOfMemory, Unsupported, Unseekable, BadData, Truncated, ReadFailed };
pub const WriteError = error{ OutOfMemory, Unsupported, WriteFailed };

test {
    _ = io;
    _ = crc;
    _ = flac;
    _ = ogg;
    _ = opus;
    _ = @import("codec/ogg_chain.zig");
    _ = pcm;
    _ = resample;
    _ = vorbis;
    _ = vorbis_comment;
    _ = wav;
    _ = Decoder;
    _ = Encoder;
}

test "Info needs only the rate and the channel count" {
    const info: Info = .{ .rate = 8000, .channels = 1 };
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(info.mask)));
    try std.testing.expectEqual(@as(?u64, null), info.total_frames);
    try std.testing.expectEqual(@as(u8, 0), info.bits_per_sample);
}

test "channel mask bits follow the WAVE speaker table" {
    const quad: ChannelMask = .{ .front_left = true, .front_right = true, .back_left = true, .back_right = true };
    try std.testing.expectEqual(@as(u32, 0x33), @as(u32, @bitCast(quad)));
    try std.testing.expectEqual(@as(u32, 0x20000), @as(u32, @bitCast(ChannelMask{ .top_back_right = true })));
    try std.testing.expectEqual(@as(u32, 0x80000000), @as(u32, @bitCast(ChannelMask{ .all = true })));
}
