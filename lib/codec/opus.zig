//! Opus (RFC 6716) and Ogg Opus (RFC 7845): packet and Ogg decoders and encoders.
const builtin = @import("builtin");
pub const range = @import("opus/range.zig");
pub const packet = @import("opus/packet.zig");
pub const celt = @import("opus/celt.zig");
pub const silk = @import("opus/silk.zig");
pub const glue = @import("opus/glue.zig");
pub const head = @import("opus/head.zig");
pub const ogg = @import("opus/ogg.zig");
pub const encode = @import("opus/encode.zig");
pub const multistream = @import("opus/multistream.zig");
pub const ogg_encode = @import("opus/ogg_encode.zig");
const encode_test = if (builtin.is_test) @import("opus/encode_test.zig") else struct {};
/// Helpers for the tests of the decoders, empty outside a test build. It is public only because
/// vectors_test.zig is a separate test module that can reach this package through `codec` alone.
pub const test_util = if (builtin.is_test) @import("opus/test_util.zig") else struct {};

pub const PacketDecoder = glue.PacketDecoder;
pub const PacketEncoder = encode.PacketEncoder;
pub const Decoder = ogg.Decoder;
pub const Encoder = ogg_encode.Encoder;
pub const Stats = ogg.Stats;
pub const isHead = head.isHead;
pub const Head = head.Head;

/// Decoder settings.
pub const Options = struct {
    /// What to do with a packet that does not parse.
    on_bad_packet: enum { resync, fail } = .resync,
    /// Apply the stereo phase inversion of CELT intensity stereo.
    phase_inversion: bool = true,
};

/// What the encoder is tuned for.
pub const Application = enum { audio, voip, low_delay };

/// Encoder settings.
pub const EncodeOptions = struct {
    /// Bits per second for all streams. `Encoder` refuses a value under 500, or over 1024000 for each
    /// channel, and limits the rate to 256000 for each channel. `PacketEncoder` clamps the value to
    /// 500 and 750000 for each channel. 0 picks a rate: for `PacketEncoder` the one of libopus
    /// for the frame size (see `PacketEncoder.initRate`), for `Encoder` the one of opusenc
    /// (64 kbit/s for a mono stream and 96 kbit/s for a coupled one, less below 44.1 kHz).
    bitrate: u32 = 0,
    application: Application = .audio,
    /// Constrained variable bitrate. False gives packets of a fixed size.
    vbr: bool = true,
    /// 2.5, 5, 10, 20, 40, 60, 80, 100 or 120. Frames above 20 ms need SILK or several frames in one packet.
    frame_ms: f32 = 20,
    /// The Ogg stream serial number.
    serial: u32 = 0,
    /// The packet loss in percent that the encoder expects, 0 to 100. A value above 0 turns on the
    /// low bit rate redundancy (in band FEC) of the SILK layer and sets the loss rate of CELT.
    packet_loss: u8 = 0,
    /// The effort of the encoder from 0 to 10, as OPUS_SET_COMPLEXITY. A larger value is refused.
    /// The default 9 gives the best quality of the encoder, but not the bytes of libopus. A value
    /// up to 6 gives the same bytes as libopus.
    complexity: u4 = 9,
};

test {
    _ = range;
    _ = packet;
    _ = celt;
    _ = silk;
    _ = glue;
    _ = head;
    _ = ogg;
    _ = encode;
    _ = multistream;
    _ = ogg_encode;
    _ = encode_test;
    _ = test_util;
}
