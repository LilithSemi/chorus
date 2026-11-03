//! The interface between Chorus and one audio system.
const std = @import("std");
const builtin = @import("builtin");
const Format = @import("../Format.zig");
const Mixer = @import("../Mixer.zig");
const Stream = @import("../Stream.zig");
const Backend = @This();

ptr: *anyopaque,
vtable: *const VTable,
kind: Kind,

/// True where the PipeWire backend is built. Android has its own backend.
pub const pipewire_enabled = builtin.os.tag == .linux and !builtin.abi.isAndroid();

/// True where the AAudio backend is built. It needs bionic.
pub const aaudio_enabled = builtin.abi.isAndroid() and builtin.link_libc;

/// True where the CoreAudio backend is built. It needs the macOS frameworks.
pub const coreaudio_enabled = builtin.os.tag == .macos;

/// True where the web backend is built. It needs the browser host of wasm32-freestanding.
pub const web_enabled = builtin.cpu.arch == .wasm32 and builtin.os.tag == .freestanding;

pub const Kind = enum { pipewire, coreaudio, aaudio, web, null };
/// Whether the audio thread has realtime scheduling. `pending` while the backend still tries.
pub const Realtime = enum(u8) { pending, yes, no };
pub const Event = enum(u8) { none, disconnected, _ };
pub const ConnectError = error{ BackendUnavailable, OutOfMemory, Canceled };
pub const DispatchError = error{ OutOfMemory, Canceled };
/// Largest period in frames that Context accepts from a backend.
pub const max_period_frames = 65536;
pub const Negotiated = struct { native: Format, period_frames: u32 };
pub const InitContext = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mixer: *Mixer,
    app_name: []const u8,
    environ: ?*const std.process.Environ.Map = null,
};

/// `stopStream` and `closeStream` return only after the audio thread has left `render` and
/// `capture` for that stream. Context frees the Stream and swaps its pipeline on the app
/// thread after those calls.
/// `dispatch` returns `.disconnected` only after the audio thread has left every stream.
/// `reconnect` does nothing when the backend is already connected.
/// `closeStream` accepts a stream that the backend has no entry for.
/// A draining stream stays started in the backend until the backend calls `Stream.drained`.
pub const VTable = struct {
    deinit: *const fn (ptr: *anyopaque) void,
    dispatch: *const fn (ptr: *anyopaque) DispatchError!Event,
    reconnect: *const fn (ptr: *anyopaque) ConnectError!void,
    realtime: *const fn (ptr: *anyopaque) Realtime,
    /// The file descriptor that becomes readable when `dispatch` has work. Null when there is none.
    fd: *const fn (ptr: *anyopaque) ?i32,
    /// Milliseconds until `dispatch` has work that no `fd` wake covers, or null when there is none.
    /// 0 means call it now. Context takes the smallest of this and the pump hints.
    timeoutMs: *const fn (ptr: *anyopaque) ?u32,
    capabilities: *const fn (ptr: *anyopaque) Mixer.Capabilities,
    openStream: *const fn (ptr: *anyopaque, stream: *Stream) Stream.OpenError!Negotiated,
    closeStream: *const fn (ptr: *anyopaque, stream: *Stream) void,
    startStream: *const fn (ptr: *anyopaque, stream: *Stream) Stream.StartError!void,
    stopStream: *const fn (ptr: *anyopaque, stream: *Stream) void,
    setDefault: *const fn (ptr: *anyopaque, kind: Mixer.Kind, id: Mixer.Id) Mixer.Error!void,
    setVolume: *const fn (ptr: *anyopaque, target: Mixer.Target, values: []const f32) Mixer.Error!void,
    setMute: *const fn (ptr: *anyopaque, target: Mixer.Target, mute: bool) Mixer.Error!void,
    moveStream: *const fn (ptr: *anyopaque, stream_id: Mixer.Id, endpoint_id: Mixer.Id) Mixer.Error!void,
    setProfile: *const fn (ptr: *anyopaque, card_id: Mixer.Id, index: u32) Mixer.Error!void,
    setPort: *const fn (ptr: *anyopaque, endpoint_id: Mixer.Id, index: u32) Mixer.Error!void,
};

/// Backends that `auto` tries, in order.
pub const order: []const Kind = if (pipewire_enabled)
    &.{ .pipewire, .null }
else if (coreaudio_enabled)
    &.{ .coreaudio, .null }
else if (aaudio_enabled)
    &.{ .aaudio, .null }
else if (web_enabled)
    &.{ .web, .null }
else
    &.{.null};

pub fn compiled(kind: Kind) bool {
    return std.mem.indexOfScalar(Kind, order, kind) != null;
}

/// Gives the backend state when `T.kind == self.kind`.
pub fn as(self: Backend, comptime T: type) ?*T {
    if (self.kind != T.kind) return null;
    return @ptrCast(@alignCast(self.ptr));
}

pub fn deinit(self: Backend) void {
    self.vtable.deinit(self.ptr);
}

pub fn dispatch(self: Backend) DispatchError!Event {
    return self.vtable.dispatch(self.ptr);
}

pub fn reconnect(self: Backend) ConnectError!void {
    return self.vtable.reconnect(self.ptr);
}

pub fn realtime(self: Backend) Realtime {
    return self.vtable.realtime(self.ptr);
}

pub fn fd(self: Backend) ?i32 {
    return self.vtable.fd(self.ptr);
}

pub fn timeoutMs(self: Backend) ?u32 {
    return self.vtable.timeoutMs(self.ptr);
}

pub fn capabilities(self: Backend) Mixer.Capabilities {
    return self.vtable.capabilities(self.ptr);
}

pub fn openStream(self: Backend, stream: *Stream) Stream.OpenError!Negotiated {
    return self.vtable.openStream(self.ptr, stream);
}

pub fn closeStream(self: Backend, stream: *Stream) void {
    self.vtable.closeStream(self.ptr, stream);
}

pub fn startStream(self: Backend, stream: *Stream) Stream.StartError!void {
    return self.vtable.startStream(self.ptr, stream);
}

pub fn stopStream(self: Backend, stream: *Stream) void {
    self.vtable.stopStream(self.ptr, stream);
}

pub fn setDefault(self: Backend, kind: Mixer.Kind, id: Mixer.Id) Mixer.Error!void {
    return self.vtable.setDefault(self.ptr, kind, id);
}

pub fn setVolume(self: Backend, target: Mixer.Target, values: []const f32) Mixer.Error!void {
    return self.vtable.setVolume(self.ptr, target, values);
}

pub fn setMute(self: Backend, target: Mixer.Target, mute: bool) Mixer.Error!void {
    return self.vtable.setMute(self.ptr, target, mute);
}

pub fn moveStream(self: Backend, stream_id: Mixer.Id, endpoint_id: Mixer.Id) Mixer.Error!void {
    return self.vtable.moveStream(self.ptr, stream_id, endpoint_id);
}

pub fn setProfile(self: Backend, card_id: Mixer.Id, index: u32) Mixer.Error!void {
    return self.vtable.setProfile(self.ptr, card_id, index);
}

pub fn setPort(self: Backend, endpoint_id: Mixer.Id, index: u32) Mixer.Error!void {
    return self.vtable.setPort(self.ptr, endpoint_id, index);
}
