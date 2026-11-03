//! One audio stream of the application, in the format the application asks for.
const std = @import("std");
const builtin = @import("builtin");
const Format = @import("Format.zig");
const dsp = @import("dsp.zig");
const Pipeline = @import("Pipeline.zig");
const Mixer = @import("Mixer.zig");
const Context = @import("Context.zig");
const Backend = @import("backend/Backend.zig");
const Stream = @This();

context: *Context,
options: Options,
negotiated: Backend.Negotiated,
pipeline: Pipeline,
resume_on_reconnect: bool = false,
/// Owned by the backend.
backend_data: ?*anyopaque = null,
/// Set by the backend. It names the device, so that a reattach finds it again.
backend_target: Target = .{},
/// A native format that the backend wants. The backend writes it on the app thread, during
/// `dispatch` or a Mixer call, and `Context.dispatch` reads and clears it.
pending_native: ?Backend.Negotiated = null,
/// True while the backend has an entry for the stream.
attached: bool = false,
/// The state that the last dispatch reported. App thread only.
last_state: State = .idle,
state_value: std.atomic.Value(State) = .init(.idle),
frames_total: std.atomic.Value(u32) = .init(0),
xrun_total: std.atomic.Value(u32) = .init(0),
/// App thread only. The totals before `frames_seen` and `xruns_seen`, which `Context.dispatch`
/// updates.
frames_base: u64 = 0,
frames_seen: u32 = 0,
xruns_base: u64 = 0,
xruns_seen: u32 = 0,

pub const Direction = Pipeline.Direction;
pub const Status = Pipeline.Status;
pub const Role = enum { media, ui, game, communication, notification, alarm };
pub const State = enum(u8) { idle, running, draining, stopped };
pub const Buffer = struct { bytes: []u8, frames: u32, format: Format };
/// The callback runs on the audio thread. To end the stream it returns `.drain` or `.stop`.
/// It must not call `stop`, `close` or any Context function.
pub const Callback = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, stream: *Stream, buffer: Buffer) Status,
};

/// Runs on the app thread during `Context.dispatch`.
pub const StateListener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, stream: *Stream, state: State) void,
};

pub const Options = struct {
    direction: Direction,
    format: Format,
    /// A sink or a source of the Mixer. A playback stream needs a sink. A capture stream takes a
    /// source, or a sink to record what it plays. The stream keeps its device after a reconnect
    /// although the Mixer ids change. After `Mixer.moveStream` a reconnect goes back to the first
    /// device. A later phase will fix this.
    device: ?Mixer.Id = null,
    latency_frames: u32 = 512,
    role: Role = .media,
    callback: Callback,
    on_state: ?StateListener = null,
    quality: dsp.resample.Quality = .good,
};

pub const Stats = struct { frames: u64, xruns: u64 };

/// The device of a stream by name. A name of more than 255 bytes is not kept.
pub const Target = struct {
    buf: [255]u8 = undefined,
    len: u8 = 0,
    /// True when a capture stream listens to a sink.
    monitor: bool = false,

    pub fn set(self: *Target, device_name: []const u8, monitor: bool) void {
        self.monitor = monitor;
        if (device_name.len > self.buf.len) {
            self.len = 0;
            return;
        }
        self.len = @intCast(device_name.len);
        @memcpy(self.buf[0..device_name.len], device_name);
    }

    pub fn name(self: *const Target) ?[]const u8 {
        if (self.len == 0) return null;
        return self.buf[0..self.len];
    }
};
/// `PermissionDenied` is for systems where the user must allow the access to a device, as with a
/// microphone.
pub const OpenError = error{ OutOfMemory, UnsupportedFormat, UnknownDevice, Disconnected, PermissionDenied };
pub const StartError = error{Disconnected};

pub fn start(self: *Stream) StartError!void {
    var seen = self.state();
    while (true) switch (seen) {
        .running => return,
        .draining => seen = self.swap(.draining, .running) orelse return,
        .idle, .stopped => {
            self.pipeline.reset();
            if (self.swap(seen, .running)) |actual| {
                seen = actual;
                continue;
            }
            self.context.backend.startStream(self) catch |err| {
                _ = self.swap(.running, seen);
                return err;
            };
            return;
        },
    };
}

pub fn stop(self: *Stream) void {
    var seen = self.state();
    while (seen != .stopped) seen = self.swap(seen, .stopped) orelse break;
    self.context.backend.stopStream(self);
}

pub fn close(self: *Stream) void {
    self.context.closeStream(self);
}

pub fn state(self: *const Stream) State {
    return self.state_value.load(.acquire);
}

/// `frames` counts native frames. The audio thread keeps 32 bit counters, and `Context.dispatch`
/// widens them. The totals stay right while `dispatch` runs at least once for each 2^32 frames.
/// App thread only.
pub fn stats(self: *const Stream) Stats {
    return .{
        .frames = self.frames_base + (self.frames_total.load(.monotonic) -% self.frames_seen),
        .xruns = self.xruns_base + (self.xrun_total.load(.monotonic) -% self.xruns_seen),
    };
}

/// Moves the 32 bit deltas into the 64 bit bases. App thread only.
pub fn foldStats(self: *Stream) void {
    const frames = self.frames_total.load(.monotonic);
    const xruns = self.xrun_total.load(.monotonic);
    self.frames_base += frames -% self.frames_seen;
    self.xruns_base += xruns -% self.xruns_seen;
    self.frames_seen = frames;
    self.xruns_seen = xruns;
}

/// The user format.
pub fn format(self: *const Stream) Format {
    return self.options.format;
}

pub fn nativeFormat(self: *const Stream) Format {
    return self.negotiated.native;
}

/// Fills `native` with any whole number of native frames.
pub fn render(self: *Stream, native: []u8) void {
    const native_format = self.negotiated.native;
    if (self.state() != .running) {
        dsp.convert.silence(native_format.sample, native);
        return;
    }
    const frame_bytes = native_format.frameBytes();
    const chunk = self.negotiated.period_frames * frame_bytes;
    var status: Status = .@"continue";
    var offset: usize = 0;
    while (offset < native.len) {
        if (status != .@"continue") {
            dsp.convert.silence(native_format.sample, native[offset..]);
            break;
        }
        const end = @min(native.len, offset + chunk);
        status = self.pipeline.pull(self.user(), native[offset..end]);
        offset = end;
    }
    self.addFrames(native.len / frame_bytes);
    self.apply(status);
}

/// Takes any whole number of native frames.
pub fn capture(self: *Stream, native: []const u8) void {
    if (self.state() != .running) return;
    const frame_bytes = self.negotiated.native.frameBytes();
    const chunk = self.negotiated.period_frames * frame_bytes;
    var status: Status = .@"continue";
    var offset: usize = 0;
    while (offset < native.len and status == .@"continue") {
        const end = @min(native.len, offset + chunk);
        status = self.pipeline.push(self.user(), native[offset..end]);
        offset = end;
    }
    self.addFrames(offset / frame_bytes);
    self.apply(status);
}

pub fn noteXrun(self: *Stream) void {
    self.noteXruns(1);
}

pub fn noteXruns(self: *Stream, count: u32) void {
    _ = self.xrun_total.fetchAdd(count, .monotonic);
}

/// A backend calls it when the queued audio of a draining stream has played.
pub fn drained(self: *Stream) void {
    _ = self.swap(.draining, .stopped);
}

/// Context calls it when the connection is lost. Gives true when the stream was running
/// or draining.
pub fn markDisconnected(self: *Stream) bool {
    var seen = self.state();
    while (seen == .running or seen == .draining) {
        seen = self.swap(seen, .stopped) orelse return true;
    }
    return false;
}

/// Gives null when the swap happened, else the state that the stream has.
fn swap(self: *Stream, from: State, to: State) ?State {
    return self.state_value.cmpxchgStrong(from, to, .acq_rel, .acquire);
}

fn user(self: *Stream) Pipeline.User {
    return .{ .ctx = self, .func = callUser };
}

fn callUser(ctx: *anyopaque, bytes: []u8, frames: u32) Status {
    const self: *Stream = @ptrCast(@alignCast(ctx));
    const buffer: Buffer = .{ .bytes = bytes, .frames = frames, .format = self.options.format };
    return self.options.callback.func(self.options.callback.ctx, self, buffer);
}

fn addFrames(self: *Stream, frames: usize) void {
    _ = self.frames_total.fetchAdd(@truncate(frames), .monotonic);
}

fn apply(self: *Stream, status: Status) void {
    // When the app changed the state during the callback, the swap fails and the app wins.
    switch (status) {
        .@"continue" => {},
        .drain => _ = self.swap(.running, .draining),
        .stop => _ = self.swap(.running, .stopped),
    }
}
