//! The params that a stream sends for its ports.
const std = @import("std");
const spa = @import("../spa.zig");
const pod = @import("../pod.zig");

pub const max_buffers = 32;

pub const Params = struct {
    buf: [4096]u8 = undefined,
    used: usize = 0,
    items: [8][]const u8 = undefined,
    n: usize = 0,

    pub fn rest(self: *Params) []u8 {
        return self.buf[self.used..];
    }

    pub fn push(self: *Params, built: []const u8) void {
        self.used += built.len;
        self.items[self.n] = built;
        self.n += 1;
    }
};

pub fn buildFormat(out: []u8, param: spa.ParamType) pod.Builder.Error![]const u8 {
    var b = pod.Builder.init(out);
    const o = try b.beginObject(@backingInt(spa.ObjectType.format), @backingInt(param));
    try b.prop(@backingInt(spa.FormatKey.media_type), .{});
    try b.id(@backingInt(spa.MediaType.audio));
    try b.prop(@backingInt(spa.FormatKey.media_subtype), .{});
    try b.id(@backingInt(spa.MediaSubtype.dsp));
    try b.prop(@backingInt(spa.FormatKey.audio_format), .{});
    try b.id(@backingInt(spa.AudioFormat.f32p));
    b.end(o);
    return b.bytesWritten();
}

pub fn buildBuffers(out: []u8) pod.Builder.Error![]const u8 {
    var b = pod.Builder.init(out);
    const o = try b.beginObject(@backingInt(spa.ObjectType.param_buffers), @backingInt(spa.ParamType.buffers));
    try b.prop(@backingInt(spa.ParamBuffersKey.buffers), .{});
    var c = try b.beginChoice(.range, 0);
    for ([_]i32{ 2, 1, max_buffers }) |v| try b.int(v);
    b.end(c);
    try b.prop(@backingInt(spa.ParamBuffersKey.blocks), .{});
    try b.int(1);
    try b.prop(@backingInt(spa.ParamBuffersKey.size), .{});
    c = try b.beginChoice(.range, 0);
    for ([_]i32{ 32768, 64, std.math.maxInt(i32) }) |v| try b.int(v);
    b.end(c);
    try b.prop(@backingInt(spa.ParamBuffersKey.stride), .{});
    try b.int(@sizeOf(f32));
    b.end(o);
    return b.bytesWritten();
}

pub fn buildIo(out: []u8, io: spa.IoType, size: usize) pod.Builder.Error![]const u8 {
    var b = pod.Builder.init(out);
    const o = try b.beginObject(@backingInt(spa.ObjectType.param_io), @backingInt(spa.ParamType.io));
    try b.prop(@backingInt(spa.ParamIoKey.id), .{});
    try b.id(@backingInt(io));
    try b.prop(@backingInt(spa.ParamIoKey.size), .{});
    try b.int(@intCast(size));
    b.end(o);
    return b.bytesWritten();
}

pub fn buildLatency(out: []u8, direction: spa.Direction) pod.Builder.Error![]const u8 {
    var b = pod.Builder.init(out);
    const o = try b.beginObject(@backingInt(spa.ObjectType.param_latency), @backingInt(spa.ParamType.latency));
    try b.prop(@backingInt(spa.ParamLatencyKey.direction), .{});
    try b.id(@backingInt(direction));
    try b.prop(@backingInt(spa.ParamLatencyKey.min_quantum), .{});
    try b.float(0);
    try b.prop(@backingInt(spa.ParamLatencyKey.max_quantum), .{});
    try b.float(0);
    try b.prop(@backingInt(spa.ParamLatencyKey.min_rate), .{});
    try b.int(0);
    try b.prop(@backingInt(spa.ParamLatencyKey.max_rate), .{});
    try b.int(0);
    try b.prop(@backingInt(spa.ParamLatencyKey.min_ns), .{});
    try b.long(0);
    try b.prop(@backingInt(spa.ParamLatencyKey.max_ns), .{});
    try b.long(0);
    b.end(o);
    return b.bytesWritten();
}

/// The name of a channel in a port property, for example FL.
pub fn channelName(buf: *[16]u8, channel: spa.AudioChannel) []const u8 {
    const v = @backingInt(channel);
    if (v >= spa.AudioChannel.aux_first and v <= spa.AudioChannel.aux_last) {
        return std.fmt.bufPrint(buf, "AUX{d}", .{v - spa.AudioChannel.aux_first}) catch "UNK";
    }
    const tag = std.enums.tagName(spa.AudioChannel, channel) orelse return "UNK";
    if (tag.len > buf.len) return "UNK";
    return std.ascii.upperString(buf, tag);
}

fn buildRawFormat(b: *pod.Builder, rate: ?u32, channels: []const spa.AudioChannel) pod.Builder.Error!void {
    try b.prop(@backingInt(spa.FormatKey.media_type), .{});
    try b.id(@backingInt(spa.MediaType.audio));
    try b.prop(@backingInt(spa.FormatKey.media_subtype), .{});
    try b.id(@backingInt(spa.MediaSubtype.raw));
    try b.prop(@backingInt(spa.FormatKey.audio_format), .{});
    try b.id(@backingInt(spa.AudioFormat.f32p));
    if (rate) |r| {
        try b.prop(@backingInt(spa.FormatKey.audio_rate), .{});
        try b.int(@intCast(r));
    }
    try b.prop(@backingInt(spa.FormatKey.audio_channels), .{});
    try b.int(@intCast(channels.len));
    try b.prop(@backingInt(spa.FormatKey.audio_position), .{});
    const arr = try b.beginArray();
    for (channels) |c| try b.id(@backingInt(c));
    b.end(arr);
}

/// The node level EnumFormat or Format: raw F32P audio with the channels of the stream.
pub fn buildNodeFormat(out: []u8, param: spa.ParamType, rate: u32, channels: []const spa.AudioChannel) pod.Builder.Error![]const u8 {
    var b = pod.Builder.init(out);
    const o = try b.beginObject(@backingInt(spa.ObjectType.format), @backingInt(param));
    try buildRawFormat(&b, rate, channels);
    b.end(o);
    return b.bytesWritten();
}

fn choiceId(b: *pod.Builder, kind: spa.ChoiceType, values: []const u32) pod.Builder.Error!void {
    const c = try b.beginChoice(kind, 0);
    for (values) |v| try b.id(v);
    b.end(c);
}

fn choiceBool(b: *pod.Builder, values: []const bool) pod.Builder.Error!void {
    const c = try b.beginChoice(.@"enum", 0);
    for (values) |v| try b.boolean(v);
    b.end(c);
}

pub fn buildEnumPortConfig(out: []u8, direction: spa.Direction) pod.Builder.Error![]const u8 {
    const dsp = @backingInt(spa.PortConfigMode.dsp);
    var b = pod.Builder.init(out);
    const o = try b.beginObject(@backingInt(spa.ObjectType.param_port_config), @backingInt(spa.ParamType.enum_port_config));
    try b.prop(@backingInt(spa.ParamPortConfigKey.direction), .{});
    try choiceId(&b, .none, &.{@backingInt(direction)});
    try b.prop(@backingInt(spa.ParamPortConfigKey.mode), .{});
    try choiceId(&b, .@"enum", &.{ dsp, dsp });
    try b.prop(@backingInt(spa.ParamPortConfigKey.monitor), .{});
    try choiceBool(&b, &.{ false, false });
    try b.prop(@backingInt(spa.ParamPortConfigKey.control), .{});
    try choiceBool(&b, &.{ false, false });
    b.end(o);
    return b.bytesWritten();
}

pub fn buildPortConfig(out: []u8, direction: spa.Direction, channels: []const spa.AudioChannel) pod.Builder.Error![]const u8 {
    var b = pod.Builder.init(out);
    const o = try b.beginObject(@backingInt(spa.ObjectType.param_port_config), @backingInt(spa.ParamType.port_config));
    try b.prop(@backingInt(spa.ParamPortConfigKey.direction), .{});
    try choiceId(&b, .none, &.{@backingInt(direction)});
    try b.prop(@backingInt(spa.ParamPortConfigKey.mode), .{});
    try b.id(@backingInt(spa.PortConfigMode.dsp));
    try b.prop(@backingInt(spa.ParamPortConfigKey.monitor), .{});
    try b.boolean(false);
    try b.prop(@backingInt(spa.ParamPortConfigKey.control), .{});
    try b.boolean(false);
    try b.prop(@backingInt(spa.ParamPortConfigKey.format), .{});
    const f = try b.beginObject(@backingInt(spa.ObjectType.format), @backingInt(spa.ParamType.port_config));
    try buildRawFormat(&b, null, channels);
    b.end(f);
    b.end(o);
    return b.bytesWritten();
}

pub const PropsValues = struct {
    volume: f32,
    mute: bool,
    soft_mute: bool,
    channel_volumes: []const f32,
    soft_volumes: []const f32,
};

pub fn buildProps(out: []u8, v: PropsValues) pod.Builder.Error![]const u8 {
    var b = pod.Builder.init(out);
    const o = try b.beginObject(@backingInt(spa.ObjectType.props), @backingInt(spa.ParamType.props));
    try b.prop(@backingInt(spa.PropKey.channel_volumes), .{});
    var a = try b.beginArray();
    for (v.channel_volumes) |x| try b.float(x);
    b.end(a);
    try b.prop(@backingInt(spa.PropKey.mute), .{});
    try b.boolean(v.mute);
    try b.prop(@backingInt(spa.PropKey.soft_volumes), .{});
    a = try b.beginArray();
    for (v.soft_volumes) |x| try b.float(x);
    b.end(a);
    try b.prop(@backingInt(spa.PropKey.soft_mute), .{});
    try b.boolean(v.soft_mute);
    try b.prop(@backingInt(spa.PropKey.volume), .{});
    try b.float(v.volume);
    b.end(o);
    return b.bytesWritten();
}
