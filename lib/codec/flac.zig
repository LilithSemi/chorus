//! FLAC decoding and encoding.
pub const decode = @import("flac/decode.zig");
pub const encode = @import("flac/encode.zig");
pub const lpc = @import("flac/lpc.zig");
pub const search = @import("flac/search.zig");
pub const ogg = @import("flac/ogg.zig");

pub const Options = decode.Options;
pub const Decoder = decode.Decoder;
pub const Encoder = encode.Encoder;

test {
    _ = @import("flac/md5.zig");
    _ = decode;
    _ = encode;
    _ = lpc;
    _ = search;
    _ = ogg;
}
