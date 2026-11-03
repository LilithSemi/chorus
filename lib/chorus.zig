//! Cross platform audio: streams, a player, codecs and a system mixer.
const std = @import("std");
const builtin = @import("builtin");

pub const codec = @import("codec");
pub const Format = @import("chorus/Format.zig");
pub const dsp = @import("chorus/dsp.zig");
pub const Pipeline = @import("chorus/Pipeline.zig");
pub const Mixer = @import("chorus/Mixer.zig");
pub const spsc = @import("chorus/spsc.zig");
pub const Spsc = spsc.Spsc;
pub const FrameRing = spsc.FrameRing;
pub const Stream = @import("chorus/Stream.zig");
pub const Context = @import("chorus/Context.zig");
pub const Player = @import("chorus/Player.zig");
pub const Recorder = @import("chorus/Recorder.zig");
pub const backend = struct {
    pub const Backend = @import("chorus/backend/Backend.zig");
    pub const Null = @import("chorus/backend/Null.zig");
    pub const PipeWire = if (Backend.pipewire_enabled) @import("chorus/backend/PipeWire.zig") else struct {};
    pub const Web = @import("chorus/backend/Web.zig");
    pub const AAudio = if (Backend.aaudio_enabled) @import("chorus/backend/AAudio.zig") else struct {};
    pub const CoreAudio = @import("chorus/backend/CoreAudio.zig");
};

test {
    _ = Format;
    _ = dsp;
    _ = Pipeline;
    _ = Mixer;
    _ = spsc;
    _ = Stream;
    _ = backend.Backend;
    _ = Context;
    _ = Player;
    _ = Recorder;
    _ = backend.Null;
    _ = backend.Web;
    _ = @import("chorus/backend/web/backend_test.zig");
    if (backend.Backend.pipewire_enabled) {
        _ = @import("chorus/backend/pipewire/rt.zig");
        _ = @import("chorus/backend/pipewire/map.zig");
        _ = backend.PipeWire;
        _ = @import("chorus/backend/pipewire/live_test.zig");
    }
    _ = @import("chorus/backend/web/api.zig");
    _ = @import("chorus/backend/web/fake.zig");
    _ = @import("chorus/backend/aaudio/api.zig");
    _ = @import("chorus/backend/aaudio/map.zig");
    _ = @import("chorus/backend/aaudio/jni.zig");
    _ = @import("chorus/backend/aaudio/fake_jni.zig");
    if (backend.Backend.aaudio_enabled) _ = @import("chorus/backend/aaudio/live_test.zig");
    _ = @import("chorus/backend/coreaudio/api.zig");
    _ = @import("chorus/backend/coreaudio/map.zig");
    _ = @import("chorus/backend/coreaudio/permission.zig");
    if (backend.Backend.coreaudio_enabled) _ = @import("chorus/backend/coreaudio/live_test.zig");
    _ = backend.CoreAudio;
    if (builtin.os.tag == .linux) {
        _ = @import("chorus/backend/aaudio/devices.zig");
        _ = @import("chorus/backend/AAudio.zig");
    }
    std.testing.refAllDecls(Stream);
    std.testing.refAllDecls(backend.Backend);
}

comptime {
    refDecls(codec);
    refDecls(codec.io);
    refDecls(codec.io.Input);
    refDecls(codec.io.BitReader);
    refDecls(codec.io.BitWriter);
    refDecls(codec.crc);
    refDecls(codec.pcm);
    refDecls(codec.SeekableSource);
    refDecls(codec.vorbis_comment);
    refDecls(codec.vorbis_comment.Comments);
    refDecls(codec.vorbis_comment.Comments.Iterator);
    refDecls(codec.ogg);
    refDecls(codec.ogg.PacketReader);
    refDecls(codec.ogg.PacketWriter);
    refDecls(codec.ogg.Link);
    refDecls(codec.opus);
    refDecls(codec.opus.range);
    refDecls(codec.opus.range.Decoder);
    refDecls(codec.opus.range.Encoder);
    refDecls(codec.opus.packet);
    refDecls(codec.opus.packet.Toc);
    refDecls(codec.opus.packet.Packet);
    refDecls(codec.opus.glue);
    refDecls(codec.opus.encode);
    refDecls(codec.opus.ogg);
    refDecls(codec.opus.head);
    refDecls(codec.opus.head.Head);
    refDecls(codec.opus.Decoder);
    refDecls(codec.opus.Options);
    refDecls(codec.opus.Stats);
    refDecls(codec.opus.Encoder);
    refDecls(codec.opus.EncodeOptions);
    refDecls(codec.opus.PacketEncoder);
    refDecls(codec.opus.PacketDecoder);
    refDecls(codec.opus.multistream);
    refDecls(codec.opus.multistream.Layout);
    refDecls(codec.opus.multistream.Encoder);
    refDecls(codec.resample);
    refDecls(codec.resample.Resampler);
    refDecls(codec.wav);
    refDecls(codec.wav.Decoder);
    refDecls(codec.wav.Encoder);
    refDecls(codec.flac);
    refDecls(codec.flac.decode);
    refDecls(codec.flac.Decoder);
    refDecls(codec.flac.Options);
    refDecls(codec.flac.decode.Stats);
    refDecls(codec.flac.decode.BadFramePolicy);
    refDecls(codec.flac.encode);
    refDecls(codec.flac.Encoder);
    refDecls(codec.flac.lpc);
    refDecls(codec.flac.lpc.Levinson);
    refDecls(codec.flac.search);
    refDecls(codec.flac.search.Search);
    refDecls(codec.flac.ogg);
    refDecls(codec.flac.ogg.Decoder);
    refDecls(codec.vorbis);
    refDecls(codec.vorbis.Decoder);
    refDecls(codec.vorbis.Options);
    refDecls(codec.vorbis.Stats);
    refDecls(codec.vorbis.header);
    refDecls(codec.vorbis.header.Setup);
    refDecls(codec.vorbis.codebook);
    refDecls(codec.vorbis.codebook.Codebook);
    refDecls(codec.vorbis.floor);
    refDecls(codec.vorbis.residue);
    refDecls(codec.vorbis.mdct);
    refDecls(codec.vorbis.mdct.Mdct);
    refDecls(codec.vorbis.window);
    refDecls(codec.vorbis.window.Windows);
    refDecls(codec.vorbis.decode);
    refDecls(codec.vorbis.encode);
    refDecls(codec.vorbis.Encoder);
    refDecls(codec.vorbis.EncodeOptions);
    refDecls(codec.vorbis.encode.Stats);
    refDecls(codec.vorbis.setup);
    refDecls(codec.vorbis.setup.Tuning);
    refDecls(codec.vorbis.psy);
    refDecls(codec.vorbis.psy.Model);
    refDecls(codec.Decoder);
    refDecls(codec.Decoder.Options);
    refDecls(codec.Encoder);
    refDecls(codec.flac.ogg.Encoder);
    refDecls(Format);
    refDecls(dsp);
    refDecls(dsp.convert);
    refDecls(dsp.gain);
    refDecls(dsp.mix);
    refDecls(dsp.remap);
    refDecls(Pipeline);
    refDecls(Mixer);
    refDecls(Stream);
    refDecls(Context);
    refDecls(Player);
    refDecls(Recorder);
    refDecls(backend.Backend);
    refDecls(backend.Null);
    refDecls(backend.Web);
    if (backend.Backend.pipewire_enabled) refDecls(backend.PipeWire);
    if (backend.Backend.aaudio_enabled) refDecls(backend.AAudio);
    refDecls(backend.CoreAudio);
}

// Outside tests nothing else forces the compiler to check unused declarations.
fn refDecls(comptime T: type) void {
    inline for (comptime std.meta.declarations(T)) |name| {
        _ = &@field(T, name);
    }
}
