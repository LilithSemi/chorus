//! Ogg Vorbis: the headers, the codebooks, the packet layer, the decoder and the encoder.
pub const codebook = @import("vorbis/codebook.zig");
pub const header = @import("vorbis/header.zig");
pub const floor = @import("vorbis/floor.zig");
pub const residue = @import("vorbis/residue.zig");
pub const mdct = @import("vorbis/mdct.zig");
pub const window = @import("vorbis/window.zig");
pub const decode = @import("vorbis/decode.zig");
pub const psy = @import("vorbis/psy.zig");
pub const setup = @import("vorbis/setup.zig");
pub const encode = @import("vorbis/encode.zig");

pub const Options = decode.Options;
pub const Stats = decode.Stats;
pub const Decoder = decode.Decoder;
pub const Encoder = encode.Encoder;
pub const EncodeOptions = encode.EncodeOptions;
pub const isIdentification = decode.isIdentification;

test {
    _ = @import("vorbis/psy.zig");
    _ = @import("vorbis/setup.zig");
    _ = @import("vorbis/encode.zig");
    _ = codebook;
    _ = header;
    _ = floor;
    _ = residue;
    _ = mdct;
    _ = window;
    _ = decode;
    _ = @import("vorbis/testing.zig");
}
