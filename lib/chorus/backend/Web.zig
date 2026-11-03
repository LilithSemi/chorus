//! The browser backend. One AudioContext, one GainNode per stream. Each `dispatch` renders 20 ms
//! chunks and schedules them ahead of `currentTime`.
const std = @import("std");
const Format = @import("../Format.zig");
const Mixer = @import("../Mixer.zig");
const Stream = @import("../Stream.zig");
const Backend = @import("Backend.zig");
const web = @import("web/api.zig");
const js = if (Backend.web_enabled) @import("web/js.zig") else struct {};
const Web = @This();

pub const kind: Backend.Kind = .web;

pub const Options = struct {
    /// The context rate. Null means the browser rate.
    rate: ?u32 = null,
    /// The least time in milliseconds of audio that stays queued. `create` raises it to two chunks.
    lead_ms: u32 = 80,
    /// `create` raises 0 to 1.
    chunk_ms: u32 = 20,
    /// The browser. Null means the table of the real binding, where the target has one.
    api: ?web.Binding = null,
};

const max_native_channels = 2;
/// Spare slots in the ring above the chunks of the largest lead.
const ring_spare = 2;
const max_lead_ms = 250;
const lead_step_up_ms = 40;
const lead_step_down_ms = 20;
const quiet_seconds = 10.0;
const resume_gap_ms = 1000.0;
const max_frames: f64 = 1 << 53;
const ramp_seconds = 0.010;

const Slot = struct { src: web.Handle, end: u64 };

const Entry = struct {
    stream: *Stream,
    app_id: Mixer.Id,
    gain: web.Handle,
    channels: u8,
    next_frame: u64 = 0,
    started: bool = false,
    ring: []Slot,
    queued: usize = 0,
    /// Each channel value divided by the largest one. The gain node has the largest.
    ratios: [max_native_channels]f32 = @splat(1),
    interleaved: []u8,
    planar: []f32,
};

gpa: std.mem.Allocator,
mixer: *Mixer,
app_name: []const u8,
options: Options,
binding: web.Binding,
context: web.Handle = 0,
connected: bool = false,
rate: u32 = 0,
chunk_frames: u32 = 0,
sink: Mixer.Id = undefined,
last_id: u32 = 0,
entries: std.ArrayList(*Entry) = .empty,
lead_ms: u32,
/// The clock value of the last xrun or lead decrease.
quiet_since: f64 = 0,
/// The wall clock value in milliseconds of the last `resume` call.
last_resume: ?f64 = null,
/// True after a `resume` call that bypassed the limit in the current user gesture.
gesture_resumed: bool = false,

const vtable: Backend.VTable = .{
    .deinit = deinitImpl,
    .dispatch = dispatchImpl,
    .reconnect = reconnectImpl,
    .realtime = realtimeImpl,
    .fd = fdImpl,
    .timeoutMs = timeoutMsImpl,
    .capabilities = capabilitiesImpl,
    .openStream = openStreamImpl,
    .closeStream = closeStreamImpl,
    .startStream = startStreamImpl,
    .stopStream = stopStreamImpl,
    .setDefault = setDefaultImpl,
    .setVolume = setVolumeImpl,
    .setMute = setMuteImpl,
    .moveStream = moveStreamImpl,
    .setProfile = setProfileImpl,
    .setPort = setPortImpl,
};

pub fn create(ictx: Backend.InitContext, options: Options) Backend.ConnectError!Backend {
    const binding = options.api orelse if (Backend.web_enabled) js.binding else return error.BackendUnavailable;
    if (!binding.table.available(binding.self)) return error.BackendUnavailable;
    var clamped = options;
    clamped.chunk_ms = @max(1, options.chunk_ms);
    clamped.lead_ms = @max(options.lead_ms, 2 *| clamped.chunk_ms);
    const self = try ictx.gpa.create(Web);
    errdefer ictx.gpa.destroy(self);
    self.* = .{
        .gpa = ictx.gpa,
        .mixer = ictx.mixer,
        .app_name = ictx.app_name,
        .options = clamped,
        .binding = binding,
        .lead_ms = clamped.lead_ms,
    };
    try self.connect();
    return .{ .ptr = self, .vtable = &vtable, .kind = kind };
}

fn from(ptr: *anyopaque) *Web {
    return @ptrCast(@alignCast(ptr));
}

fn api(self: *const Web) *const web.Api {
    return self.binding.table;
}

fn me(self: *const Web) *anyopaque {
    return self.binding.self;
}

fn newId(self: *Web) Mixer.Id {
    self.last_id += 1;
    return @fromBackingInt(self.last_id);
}

/// Makes the context and the sink endpoint.
fn connect(self: *Web) Backend.ConnectError!void {
    const context = self.api().createContext(self.me(), self.options.rate);
    if (context == 0) return error.BackendUnavailable;
    errdefer {
        self.api().close(self.me(), context);
        self.api().release(self.me(), context);
    }
    const reported = self.api().sampleRate(self.me(), context);
    if (!std.math.isFinite(reported) or reported < Format.min_rate or reported > Format.max_rate) {
        return error.BackendUnavailable;
    }
    const rate: u32 = @intFromFloat(@round(reported));
    const chunk: f64 = @round(@as(f64, @floatFromInt(rate)) * @as(f64, @floatFromInt(self.options.chunk_ms)) / 1000);
    self.context = context;
    self.rate = rate;
    self.chunk_frames = @intFromFloat(std.math.clamp(chunk, 1, Backend.max_period_frames));
    self.quiet_since = self.clock();
    self.last_resume = null;
    self.gesture_resumed = false;
    self.sink = self.newId();
    try self.mixer.putEndpoint(.{
        .id = self.sink,
        .kind = .sink,
        .name = "default",
        .description = "Default output",
        .volume = .init(&.{ 1, 1 }),
    });
    self.mixer.putDefault(.sink, self.sink);
    self.connected = true;
}

fn rateF64(self: *const Web) f64 {
    return @floatFromInt(self.rate);
}

fn clock(self: *const Web) f64 {
    const t = self.api().currentTime(self.me(), self.context);
    return if (std.math.isFinite(t) and t > 0) t else 0;
}

fn frameOf(self: *const Web, time: f64) u64 {
    return @intFromFloat(@min(@ceil(time * self.rateF64()), max_frames));
}

fn leadFrames(self: *const Web, hidden: bool) u64 {
    var ms = self.lead_ms;
    if (hidden) ms = @max(ms, max_lead_ms);
    return @intFromFloat(@round(self.rateF64() * @as(f64, @floatFromInt(ms)) / 1000));
}

fn maxLead(self: *const Web) u32 {
    return @max(max_lead_ms, self.options.lead_ms);
}

fn stopSources(self: *Web, entry: *Entry) void {
    for (entry.ring[0..entry.queued]) |slot| {
        self.api().stopSource(self.me(), slot.src, 0);
        self.api().release(self.me(), slot.src);
    }
    entry.queued = 0;
    entry.started = false;
}

fn prune(self: *Web, entry: *Entry, now_frame: u64) void {
    var done: usize = 0;
    while (done < entry.queued and entry.ring[done].end <= now_frame) : (done += 1) {
        self.api().release(self.me(), entry.ring[done].src);
    }
    if (done == 0) return;
    entry.queued -= done;
    std.mem.copyForwards(Slot, entry.ring[0..entry.queued], entry.ring[done..][0..entry.queued]);
}

fn destroyEntry(self: *Web, entry: *Entry) void {
    self.stopSources(entry);
    self.api().disconnect(self.me(), entry.gain);
    self.api().release(self.me(), entry.gain);
    self.mixer.removeStream(entry.app_id);
    entry.stream.backend_data = null;
    self.gpa.free(entry.ring);
    self.gpa.free(entry.interleaved);
    self.gpa.free(entry.planar);
    self.gpa.destroy(entry);
}

fn dropAll(self: *Web) void {
    while (self.entries.pop()) |entry| self.destroyEntry(entry);
    self.mixer.removeEndpoint(self.sink);
    self.api().release(self.me(), self.context);
    self.context = 0;
    self.connected = false;
}

fn find(self: *Web, stream: *Stream) ?*Entry {
    const entry: *Entry = @ptrCast(@alignCast(stream.backend_data orelse return null));
    if (std.mem.indexOfScalar(*Entry, self.entries.items, entry) == null) return null;
    return entry;
}

fn deinitImpl(ptr: *anyopaque) void {
    const self = from(ptr);
    if (self.connected) {
        while (self.entries.pop()) |entry| self.destroyEntry(entry);
        self.mixer.removeEndpoint(self.sink);
        self.api().close(self.me(), self.context);
        self.api().release(self.me(), self.context);
    }
    self.entries.deinit(self.gpa);
    self.gpa.destroy(self);
}

fn stalled(state: web.State) bool {
    return switch (state) {
        .suspended, .interrupted => true,
        .running, .closed, .unknown => false,
    };
}

fn dispatchImpl(ptr: *anyopaque) Backend.DispatchError!Backend.Event {
    const self = from(ptr);
    if (!self.connected) return .none;
    const state = self.api().state(self.me(), self.context);
    if (state == .closed) {
        self.dropAll();
        return .disconnected;
    }
    const time = self.clock();
    const now_frame = self.frameOf(time);
    if (self.lead_ms > self.options.lead_ms and time - self.quiet_since >= quiet_seconds) {
        self.lead_ms = @max(self.options.lead_ms, self.lead_ms -| lead_step_down_ms);
        self.quiet_since = time;
    }
    if (self.gesture_resumed and !self.api().transient(self.me())) self.gesture_resumed = false;
    const waiting = stalled(state);
    if (waiting and self.anyActive()) self.tryResume();
    const pass: Pass = .{
        .time = time,
        .now_frame = now_frame,
        .hidden = self.api().hidden(self.me()),
        .waiting = waiting,
    };
    var raised = false;
    for (self.entries.items) |entry| self.service(entry, pass, &raised);
    return .none;
}

fn anyActive(self: *const Web) bool {
    for (self.entries.items) |entry| {
        switch (entry.stream.state()) {
            .running, .draining => return true,
            .idle, .stopped => {},
        }
    }
    return false;
}

/// Calls `resume` after a user gesture, at most once each second of wall time.
/// The first call in a user gesture has no limit.
fn tryResume(self: *Web) void {
    if (!self.api().activated(self.me())) return;
    const wall = self.api().now(self.me());
    const in_gesture = self.api().transient(self.me());
    if (self.last_resume) |last| {
        const bypass = in_gesture and !self.gesture_resumed;
        if (!bypass and !(wall - last >= resume_gap_ms)) return;
    }
    if (in_gesture) self.gesture_resumed = true;
    self.last_resume = wall;
    self.api().@"resume"(self.me(), self.context);
}

const Pass = struct { time: f64, now_frame: u64, hidden: bool, waiting: bool };

fn service(self: *Web, entry: *Entry, pass: Pass, raised: *bool) void {
    const stream = entry.stream;
    const now_frame = pass.now_frame;
    self.prune(entry, now_frame);
    switch (stream.state()) {
        .idle, .stopped => {
            if (entry.started) self.stopSources(entry);
            return;
        },
        .draining => {
            if (!entry.started or now_frame >= entry.next_frame) stream.drained();
            return;
        },
        .running => {},
    }
    if (!entry.started) {
        entry.started = true;
        entry.next_frame = now_frame + self.chunk_frames;
    } else if (pass.waiting) {
        // The clock of a stalled context does not tell the truth about the queue.
        return;
    } else if (entry.next_frame <= now_frame) {
        stream.noteXrun();
        entry.next_frame = now_frame + self.chunk_frames;
        if (!raised.*) {
            raised.* = true;
            self.lead_ms = @min(self.lead_ms + lead_step_up_ms, self.maxLead());
        }
        self.quiet_since = pass.time;
    }
    const target = now_frame + self.leadFrames(pass.hidden);
    var failed = false;
    while (stream.state() == .running and entry.next_frame < target and entry.queued < entry.ring.len) {
        if (!self.schedule(entry)) failed = true;
    }
    if (failed) stream.noteXrun();
}

/// Renders one chunk and gives it to the browser at the next frame of the entry. Gives false
/// when the browser refuses the chunk.
fn schedule(self: *Web, entry: *Entry) bool {
    const chunk: usize = self.chunk_frames;
    const count: usize = entry.channels;
    entry.stream.render(entry.interleaved);
    const samples = std.mem.bytesAsSlice(f32, entry.interleaved);
    var slices: [max_native_channels][]const f32 = undefined;
    for (0..count) |c| {
        const channel = entry.planar[c * chunk ..][0..chunk];
        const ratio = entry.ratios[c];
        for (channel, 0..) |*out, i| out.* = samples[i * count + c] * ratio;
        slices[c] = channel;
    }
    const when = @as(f64, @floatFromInt(entry.next_frame)) / self.rateF64();
    const rate_f32: f32 = @floatFromInt(self.rate);
    const src = self.api().play(self.me(), self.context, entry.gain, slices[0..count], self.chunk_frames, rate_f32, when);
    const end = entry.next_frame + chunk;
    entry.next_frame = end;
    if (src == 0) return false;
    entry.ring[entry.queued] = .{ .src = src, .end = end };
    entry.queued += 1;
    return true;
}

fn reconnectImpl(ptr: *anyopaque) Backend.ConnectError!void {
    const self = from(ptr);
    if (self.connected) return;
    try self.connect();
}

fn realtimeImpl(ptr: *anyopaque) Backend.Realtime {
    _ = ptr;
    return .no;
}

fn fdImpl(ptr: *anyopaque) ?i32 {
    _ = ptr;
    return null;
}

fn timeoutMsImpl(ptr: *anyopaque) ?u32 {
    const self = from(ptr);
    if (!self.connected) return null;
    const waiting = stalled(self.api().state(self.me(), self.context));
    const now_frame = self.frameOf(self.clock());
    const is_hidden = self.api().hidden(self.me());
    // A hidden page queues at least 250 ms. It can wait until half of that is left.
    const lead = if (is_hidden) self.leadFrames(true) / 2 else self.leadFrames(false);
    const cap: u32 = if (is_hidden) @max(self.options.chunk_ms, @max(self.lead_ms, max_lead_ms) / 2) else self.options.chunk_ms;
    var best: ?u32 = null;
    for (self.entries.items) |entry| {
        // A refill needs `next_frame < now + lead`, so one more frame has to pass at the end.
        const needed: u64 = switch (entry.stream.state()) {
            .idle, .stopped => continue,
            .draining => if (entry.started) entry.next_frame -| now_frame else 0,
            .running => if (entry.started) (entry.next_frame + 1) -| (now_frame + lead) else 0,
        };
        var ms: u32 = cap;
        if (!waiting) {
            const exact = (needed * 1000 + self.rate - 1) / self.rate;
            ms = @intCast(@min(exact, cap));
        }
        best = if (best) |b| @min(b, ms) else ms;
    }
    return best;
}

fn capabilitiesImpl(ptr: *anyopaque) Mixer.Capabilities {
    _ = ptr;
    return .{ .stream_volume = true };
}

fn openStreamImpl(ptr: *anyopaque, stream: *Stream) Stream.OpenError!Backend.Negotiated {
    const self = from(ptr);
    if (!self.connected) return error.Disconnected;
    const options = stream.options;
    if (options.direction == .capture) return error.UnknownDevice;
    if (options.device) |device| {
        if (device != self.sink) return error.UnknownDevice;
    }
    const wide = options.format.channels.count > 1 and
        self.api().maxChannels(self.me(), self.context) >= 2;
    const channels: u8 = if (wide) 2 else 1;
    const native: Format = .{
        .sample = .f32,
        .rate = self.rate,
        .channels = if (wide) .stereo else .mono,
    };
    const entry = try self.gpa.create(Entry);
    errdefer self.gpa.destroy(entry);
    const interleaved = try self.gpa.alloc(u8, self.chunk_frames * native.frameBytes());
    errdefer self.gpa.free(interleaved);
    const planar = try self.gpa.alloc(f32, @as(usize, self.chunk_frames) * channels);
    errdefer self.gpa.free(planar);
    const slots = (self.maxLead() + self.options.chunk_ms - 1) / self.options.chunk_ms;
    const ring = try self.gpa.alloc(Slot, slots + ring_spare);
    errdefer self.gpa.free(ring);
    try self.entries.ensureUnusedCapacity(self.gpa, 1);
    const gain = self.api().createGain(self.me(), self.context);
    if (gain == 0) return error.Disconnected;
    errdefer {
        self.api().disconnect(self.me(), gain);
        self.api().release(self.me(), gain);
    }
    entry.* = .{
        .stream = stream,
        .app_id = self.newId(),
        .gain = gain,
        .channels = channels,
        .ring = ring,
        .interleaved = interleaved,
        .planar = planar,
    };
    try self.mixer.putStream(.{
        .id = entry.app_id,
        .direction = .playback,
        .app_name = self.app_name,
        .name = self.app_name,
        .endpoint = self.sink,
        .volume = .init(([_]f32{ 1, 1 })[0..channels]),
    });
    self.entries.appendAssumeCapacity(entry);
    stream.backend_data = entry;
    return .{ .native = native, .period_frames = self.chunk_frames };
}

fn closeStreamImpl(ptr: *anyopaque, stream: *Stream) void {
    const self = from(ptr);
    const entry = self.find(stream) orelse return;
    const i = std.mem.indexOfScalar(*Entry, self.entries.items, entry).?;
    _ = self.entries.swapRemove(i);
    self.destroyEntry(entry);
}

fn startStreamImpl(ptr: *anyopaque, stream: *Stream) Stream.StartError!void {
    const self = from(ptr);
    const entry = self.find(stream) orelse return error.Disconnected;
    self.stopSources(entry);
    if (stalled(self.api().state(self.me(), self.context))) self.tryResume();
}

fn stopStreamImpl(ptr: *anyopaque, stream: *Stream) void {
    const self = from(ptr);
    const entry = self.find(stream) orelse return;
    self.stopSources(entry);
}

fn setDefaultImpl(ptr: *anyopaque, k: Mixer.Kind, id: Mixer.Id) Mixer.Error!void {
    _ = ptr;
    _ = k;
    _ = id;
    return error.Unsupported;
}

fn entryOf(self: *Web, id: Mixer.Id) ?*Entry {
    for (self.entries.items) |entry| {
        if (entry.app_id == id) return entry;
    }
    return null;
}

/// Sets the gain node to the largest value and the ratios to the rest.
fn applyVolume(self: *Web, entry: *Entry, volume: Mixer.Volume, mute: bool) void {
    const values = volume.slice();
    var top: f32 = 0;
    for (values) |v| top = @max(top, v);
    for (values, 0..) |v, c| entry.ratios[c] = if (top > 0) v / top else 1;
    self.api().rampGain(self.me(), self.context, entry.gain, if (mute) 0 else top, ramp_seconds);
}

fn setVolumeImpl(ptr: *anyopaque, target: Mixer.Target, values: []const f32) Mixer.Error!void {
    const self = from(ptr);
    const id = switch (target) {
        .stream => |id| id,
        .endpoint => return error.Unsupported,
    };
    const entry = self.entryOf(id) orelse return error.UnknownObject;
    var value = (self.mixer.stream(id) orelse return error.UnknownObject).*;
    value.volume = try .initChecked(values);
    if (value.volume.count != entry.channels) return error.InvalidVolume;
    try self.mixer.putStream(value);
    self.applyVolume(entry, value.volume, value.mute);
}

fn setMuteImpl(ptr: *anyopaque, target: Mixer.Target, mute: bool) Mixer.Error!void {
    const self = from(ptr);
    const id = switch (target) {
        .stream => |id| id,
        .endpoint => return error.Unsupported,
    };
    const entry = self.entryOf(id) orelse return error.UnknownObject;
    var value = (self.mixer.stream(id) orelse return error.UnknownObject).*;
    value.mute = mute;
    try self.mixer.putStream(value);
    self.applyVolume(entry, value.volume, mute);
}

fn moveStreamImpl(ptr: *anyopaque, stream_id: Mixer.Id, endpoint_id: Mixer.Id) Mixer.Error!void {
    _ = ptr;
    _ = stream_id;
    _ = endpoint_id;
    return error.Unsupported;
}

fn setProfileImpl(ptr: *anyopaque, card_id: Mixer.Id, index: u32) Mixer.Error!void {
    _ = ptr;
    _ = card_id;
    _ = index;
    return error.Unsupported;
}

fn setPortImpl(ptr: *anyopaque, endpoint_id: Mixer.Id, index: u32) Mixer.Error!void {
    _ = ptr;
    _ = endpoint_id;
    _ = index;
    return error.Unsupported;
}
