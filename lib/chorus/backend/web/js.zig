//! The real table of the web backend. It calls the Web Audio binding that webidl.zig generates
//! from `web/audio.webidl`. Only builds for wasm32-freestanding import this file.
//! A JS exception cannot be caught here and skips the Zig defers, so each call checks the inputs
//! that the browser can refuse first.
const std = @import("std");
const webidl = @import("webidl");
const audio = @import("web_audio");
const api = @import("api.zig");

const min_rate = 3000;
const max_rate = 768000;
const max_buffer_channels = 32;

const Unit = struct {};
const unit: Unit = .{};

/// The functions keep no state, so `self` points at a value with no size.
pub const binding: api.Binding = .{ .self = @ptrCast(@constCast(&unit)), .table = &table };

pub const table: api.Api = .{
    .available = available,
    .createContext = createContext,
    .close = close,
    .release = release,
    .currentTime = currentTime,
    .now = now,
    .sampleRate = sampleRate,
    .state = state,
    .@"resume" = @"resume",
    .activated = activated,
    .transient = transient,
    .hidden = hidden,
    .maxChannels = maxChannels,
    .createGain = createGain,
    .rampGain = rampGain,
    .disconnect = disconnect,
    .play = play,
    .stopSource = stopSource,
};

fn context(h: api.Handle) audio.AudioContext {
    return .{ .handle = h };
}

fn available(self: *anyopaque) bool {
    _ = self;
    return audio.globalThis.get_AudioContext();
}

fn createContext(self: *anyopaque, rate: ?u32) api.Handle {
    _ = self;
    const wanted = rate orelse return audio.AudioContext.init().handle;
    if (wanted < min_rate or wanted > max_rate) return 0;
    const options = audio.Object.init();
    defer options.unref();
    options.set_sampleRate(@floatFromInt(wanted));
    options.set_latencyHint("interactive");
    return audio.AudioContext.init1(options).handle;
}

fn close(self: *anyopaque, h: api.Handle) void {
    _ = self;
    context(h).close();
}

fn release(self: *anyopaque, h: api.Handle) void {
    _ = self;
    webidl.rt.release(h);
}

fn currentTime(self: *anyopaque, h: api.Handle) f64 {
    _ = self;
    return context(h).get_currentTime();
}

fn now(self: *anyopaque) f64 {
    _ = self;
    return audio.performance.now();
}

fn sampleRate(self: *anyopaque, h: api.Handle) f32 {
    _ = self;
    return context(h).get_sampleRate();
}

fn state(self: *anyopaque, h: api.Handle) api.State {
    _ = self;
    const name = context(h).get_state();
    defer webidl.rt.freeStr(name);
    inline for (.{ "suspended", "running", "closed", "interrupted" }) |known| {
        if (std.mem.eql(u8, name, known)) return @field(api.State, known);
    }
    return .unknown;
}

fn @"resume"(self: *anyopaque, h: api.Handle) void {
    _ = self;
    context(h).@"resume"();
}

fn activated(self: *anyopaque) bool {
    _ = self;
    const activation = audio.navigator.get_userActivation() orelse return true;
    defer activation.unref();
    return activation.get_hasBeenActive();
}

fn transient(self: *anyopaque) bool {
    _ = self;
    const activation = audio.navigator.get_userActivation() orelse return false;
    defer activation.unref();
    return activation.get_isActive();
}

fn hidden(self: *anyopaque) bool {
    _ = self;
    return audio.document.get_hidden();
}

fn maxChannels(self: *anyopaque, h: api.Handle) u32 {
    _ = self;
    const destination = context(h).get_destination();
    defer destination.unref();
    return destination.get_maxChannelCount();
}

fn createGain(self: *anyopaque, h: api.Handle) api.Handle {
    _ = self;
    const ctx = context(h);
    const gain = ctx.createGain();
    const destination = ctx.get_destination();
    defer destination.unref();
    gain.connect(destination).unref();
    return gain.handle;
}

fn rampGain(self: *anyopaque, h: api.Handle, gain: api.Handle, value: f32, seconds: f64) void {
    _ = self;
    const start = context(h).get_currentTime();
    const param = (audio.GainNode{ .handle = gain }).get_gain();
    defer param.unref();
    param.cancelScheduledValues(start).unref();
    param.setValueAtTime(param.get_value(), start).unref();
    param.linearRampToValueAtTime(value, start + seconds).unref();
}

fn disconnect(self: *anyopaque, node: api.Handle) void {
    _ = self;
    (audio.GainNode{ .handle = node }).disconnect();
}

fn play(
    self: *anyopaque,
    h: api.Handle,
    gain: api.Handle,
    planar: []const []const f32,
    frames: u32,
    rate: f32,
    when: f64,
) api.Handle {
    _ = self;
    if (planar.len < 1 or planar.len > max_buffer_channels or frames == 0) return 0;
    if (!(rate >= min_rate and rate <= max_rate)) return 0;
    for (planar) |channel| if (channel.len < frames) return 0;
    const ctx = context(h);
    const buffer = ctx.createBuffer(@intCast(planar.len), frames, rate);
    defer buffer.unref();
    for (planar, 0..) |channel, index| {
        // The host only reads the view.
        buffer.copyToChannel(@constCast(channel[0..frames]), @intCast(index), 0);
    }
    const source = ctx.createBufferSource();
    source.set_buffer(buffer);
    source.connect(.{ .handle = gain }).unref();
    source.start(when);
    return source.handle;
}

fn stopSource(self: *anyopaque, src: api.Handle, when: f64) void {
    _ = self;
    (audio.AudioBufferSourceNode{ .handle = src }).stop(when);
}
