//! CELT: static tables, bit allocation, PVQ codewords, the decoder and the encoder.
pub const tables = @import("celt/tables.zig");
pub const rate = @import("celt/rate.zig");
pub const cwrs = @import("celt/cwrs.zig");
pub const mdct = @import("celt/mdct.zig");
pub const energy = @import("celt/energy.zig");
pub const vq = @import("celt/vq.zig");
pub const bands = @import("celt/bands.zig");
pub const pitch = @import("celt/pitch.zig");
pub const decode = @import("celt/decode.zig");
pub const encode = @import("celt/encode.zig");

test {
    _ = tables;
    _ = rate;
    _ = cwrs;
    _ = mdct;
    _ = energy;
    _ = vq;
    _ = bands;
    _ = pitch;
    _ = decode;
    _ = encode;
}
