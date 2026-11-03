//! The Android backend. It plays and records through AAudio.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const Format = @import("../Format.zig");
const Mixer = @import("../Mixer.zig");
const Stream = @import("../Stream.zig");
const dsp = @import("../dsp.zig");
const Backend = @import("Backend.zig");
const aaudio = @import("aaudio/api.zig");
const map = @import("aaudio/map.zig");
const audio_manager = @import("aaudio/devices.zig");
const java = @import("aaudio/jni.zig");
const AAudio = @This();

pub const kind: Backend.Kind = .aaudio;

pub const Options = struct {
    /// `JavaVM*` of the app. Null means one default sink and source and no volume.
    java_vm: ?*anyopaque = null,
    /// Global ref to an android.content.Context. The app keeps it alive while the Context lives.
    android_context: ?*anyopaque = null,
    performance: enum { low_latency, none, power_saving } = .low_latency,
    exclusive: bool = false,
    /// Milliseconds between the tries to reopen a stream that the system disconnected.
    reopen_retry_ms: u32 = 100,
    /// Milliseconds after the first failed reopen at which the tries stop and the stream counts as lost.
    reopen_give_up_ms: u32 = 3000,
    /// Milliseconds that a reopened stream must live before the give up time starts again.
    reopen_stable_ms: u32 = 1000,
    /// Milliseconds between device scans while a JavaVM and a Context are given.
    poll_ms: u32 = 1000,
    /// Test seam. Null means the table of the system libaaudio.
    api: ?*const aaudio.Api = null,
};

/// An Android device that a Mixer endpoint stands for. `android_id` is the AudioDeviceInfo id,
/// and 0 lets the system choose.
pub const Device = struct { id: Mixer.Id, android_id: i32, kind: Mixer.Kind };

const Entry = struct {
    backend: *AAudio,
    stream: *Stream,
    app_id: Mixer.Id,
    handle: ?*aaudio.AStream = null,
    android_device: i32 = aaudio.unspecified,
    /// 1 while the data callback runs.
    in_callback: std.atomic.Value(u32) = .init(0),
    /// 0 makes the data callback write silence and skip the stream.
    wanted_running: std.atomic.Value(u32) = .init(0),
    error_code: std.atomic.Value(i32) = .init(0),
    /// The handle that `error_code` belongs to.
    error_handle: std.atomic.Value(usize) = .init(0),
    dirty: std.atomic.Value(u32) = .init(0),
    xruns_seen: std.atomic.Value(u32) = .init(0),
    playback: bool,
    /// The native format of the open handle. The app thread writes them while no callback runs.
    sample: Format.Sample = .f32,
    frame_bytes: usize = 0,
    /// App thread only. True between a successful `requestStart` and the stop.
    started: bool = false,
    /// App thread only. 1 after `requestStop` for a draining stream.
    drain_stage: u8 = 0,
    /// App thread only. Monotonic time at which the tries to reopen stop. 0 means no outage runs.
    /// A reopen keeps it until the new stream has lived for `reopen_stable_ms`.
    retry_until_ns: u64 = 0,
    /// App thread only. True while a try to reopen waits for `retry_at_ns`.
    retrying: bool = false,
    /// App thread only. Monotonic time of the next try.
    retry_at_ns: u64 = 0,
    /// App thread only. True when the stream ran before a reopen that has not worked yet.
    restart: bool = false,
    /// App thread only. True after the last try failed, until the outage window ends. The stream
    /// still reads running until then, with no handle and no callback.
    gave_up: bool = false,
    /// App thread only. True after the stream gave up in a window that has ended, until it works again.
    stale: bool = false,
    /// App thread only. Monotonic time of the last reopen that worked.
    opened_ns: u64 = 0,

    fn setNative(self: *Entry, native: Format) void {
        self.sample = native.sample;
        self.frame_bytes = native.frameBytes();
    }
};

const Opened = struct { handle: *aaudio.AStream, negotiated: Backend.Negotiated };

/// Of the masks that map gives, AAudio takes only 5.1 for input.
const input_5_1 = aaudio.ChannelMask.surround_5_1;

const Order = enum { close_first, open_first };

/// Milliseconds between polls of a stream that AAudio is stopping after a drain.
const drain_poll_ms = 10;
const stop_wait_ns: i64 = 2 * std.time.ns_per_s;

gpa: std.mem.Allocator,
mixer: *Mixer,
app_name: []const u8,
options: Options,
/// The functions of AAudio. `api` points here, so the pointer stays valid for the life of the backend.
table: aaudio.Api,
api: *const aaudio.Api,
entries: std.ArrayList(*Entry) = .empty,
/// Closed entries. A late error callback of AAudio can still point at one, so `dispatch` frees them.
retired: std.ArrayList(*Entry) = .empty,
/// The Mixer endpoints that map to Android devices. A device scan adds and removes rows.
devices: std.ArrayList(Device) = .empty,
last_id: u32 = 0,
/// The entry where the next dispatch looks first for a stream to reopen.
rotate: usize = 0,
connected: bool = true,
/// The result code of the last failed open.
last_result: aaudio.Result = aaudio.ResultCode.ok,
/// 0 pending, 1 yes, 2 no.
rt: std.atomic.Value(u32) = .init(0),
/// An epoll that holds `wake_fd` and `timer_fd`.
wait_fd: i32 = -1,
/// An eventfd that the error callback and the drain of a stream write.
wake_fd: i32 = -1,
/// A short timer polls the streams that wait for AAudio to stop. The device scan arms it too.
timer_fd: i32 = -1,
/// The interval that the timer has. `rearm` makes the next `updateTimer` set it again.
timer_ms: u32 = 0,
/// Present when the app gave a JavaVM and a Context and the setup of JNI worked.
view: ?audio_manager.View = null,
/// Why the setup of JNI failed. Null when it worked or the app gave no handles.
jni_error: ?java.Error = null,
/// Monotonic time of the next device scan.
next_scan_ns: u64 = 0,
/// How many device scans failed in a Java call.
scan_errors: u32 = 0,

const rearm = std.math.maxInt(u32);

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
    const table: aaudio.Api = if (options.api) |t|
        t.*
    else if (comptime Backend.aaudio_enabled)
        aaudio.loadNative()
    else
        return error.BackendUnavailable;
    const self = try ictx.gpa.create(AAudio);
    errdefer ictx.gpa.destroy(self);
    self.* = .{
        .gpa = ictx.gpa,
        .mixer = ictx.mixer,
        .app_name = ictx.app_name,
        .options = options,
        .table = table,
        .api = undefined,
    };
    self.api = &self.table;
    try self.makeWait();
    errdefer self.closeWait();
    errdefer self.devices.deinit(self.gpa);
    errdefer self.removeEndpoints();
    try self.addDefault(.sink);
    try self.addDefault(.source);
    if (options.java_vm) |vm| {
        if (options.android_context) |context| {
            // Without JNI the audio still works, so a failed setup leaves the default endpoints.
            self.view = audio_manager.View.init(vm, context) catch |err| blk: {
                self.jni_error = err;
                break :blk null;
            };
        }
    }
    errdefer if (self.view) |*view| view.deinit();
    if (self.view != null) {
        try self.pollScan();
        self.updateTimer();
    }
    return .{ .ptr = self, .vtable = &vtable, .kind = kind };
}

fn removeEndpoints(self: *AAudio) void {
    for (self.devices.items) |row| self.mixer.removeEndpoint(row.id);
}

/// Gives ids 1, 2, 3 and so on.
pub fn newId(self: *AAudio) Mixer.Id {
    self.last_id += 1;
    return @fromBackingInt(self.last_id);
}

/// Adds or replaces the row of a device. The Mixer endpoint is the caller's job.
pub fn putDevice(self: *AAudio, device: Device) error{OutOfMemory}!void {
    for (self.devices.items) |*row| {
        if (row.id == device.id) {
            row.* = device;
            return;
        }
    }
    try self.devices.append(self.gpa, device);
}

pub fn removeDevice(self: *AAudio, id: Mixer.Id) void {
    for (self.devices.items, 0..) |row, i| {
        if (row.id == id) {
            _ = self.devices.orderedRemove(i);
            return;
        }
    }
}

/// The endpoint that stands for the device that the system chooses.
pub fn defaultEndpoint(id: Mixer.Id, device_kind: Mixer.Kind) Mixer.Endpoint {
    return .{
        .id = id,
        .kind = device_kind,
        .name = "default",
        .description = switch (device_kind) {
            .sink => "Default output",
            .source => "Default input",
        },
        .volume = .{},
    };
}

pub fn addDefault(self: *AAudio, device_kind: Mixer.Kind) error{OutOfMemory}!void {
    const id = self.newId();
    try self.devices.append(self.gpa, .{ .id = id, .android_id = aaudio.unspecified, .kind = device_kind });
    try self.mixer.putEndpoint(defaultEndpoint(id, device_kind));
    self.mixer.putDefault(device_kind, id);
}

fn makeWait(self: *AAudio) Backend.ConnectError!void {
    const wake_rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
    if (linux.errno(wake_rc) != .SUCCESS) return error.BackendUnavailable;
    self.wake_fd = @intCast(wake_rc);
    errdefer _ = linux.close(self.wake_fd);
    const timer_rc = linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
    if (linux.errno(timer_rc) != .SUCCESS) return error.BackendUnavailable;
    self.timer_fd = @intCast(timer_rc);
    errdefer _ = linux.close(self.timer_fd);
    const wait_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (linux.errno(wait_rc) != .SUCCESS) return error.BackendUnavailable;
    self.wait_fd = @intCast(wait_rc);
    errdefer _ = linux.close(self.wait_fd);
    for ([_]i32{ self.wake_fd, self.timer_fd }) |watched| {
        var ev: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .fd = watched } };
        if (linux.errno(linux.epoll_ctl(self.wait_fd, linux.EPOLL.CTL_ADD, watched, &ev)) != .SUCCESS) return error.BackendUnavailable;
    }
}

fn closeWait(self: *AAudio) void {
    _ = linux.close(self.wait_fd);
    _ = linux.close(self.timer_fd);
    _ = linux.close(self.wake_fd);
}

/// Makes `fd()` readable. The error callback and the data callback of a draining stream call it.
fn wake(self: *AAudio) void {
    const one: u64 = 1;
    _ = linux.write(self.wake_fd, std.mem.asBytes(&one), 8);
}

fn drainWait(self: *AAudio) void {
    var count: u64 = 0;
    _ = linux.read(self.wake_fd, std.mem.asBytes(&count), 8);
    _ = linux.read(self.timer_fd, std.mem.asBytes(&count), 8);
}

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn timespecOf(ms: u32) linux.timespec {
    return .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
}

fn scanEnabled(self: *const AAudio) bool {
    return self.connected and self.view != null and self.options.poll_ms != 0;
}

fn msUntilScan(self: *const AAudio) u32 {
    const now = nowNs();
    if (now >= self.next_scan_ns) return 1;
    const ms = (self.next_scan_ns - now + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
    return @intCast(@min(ms, std.math.maxInt(u32) - 1));
}

/// Arms the timer for the shortest need: the poll of a stream that AAudio stops after a drain, the
/// retry of a reopen and the next device scan. It disarms the timer when there is no need.
fn updateTimer(self: *AAudio) void {
    var want_ms: u32 = 0;
    if (self.scanEnabled()) want_ms = self.options.poll_ms;
    for (self.entries.items) |entry| {
        if (entry.drain_stage == 0) continue;
        want_ms = if (want_ms == 0) drain_poll_ms else @min(want_ms, drain_poll_ms);
    }
    for (self.entries.items) |entry| {
        if (!entry.retrying) continue;
        const retry_ms = @max(self.options.reopen_retry_ms, 1);
        want_ms = if (want_ms == 0) retry_ms else @min(want_ms, retry_ms);
    }
    if (want_ms == self.timer_ms) return;
    var first_ms = want_ms;
    if (self.scanEnabled()) first_ms = @min(first_ms, self.msUntilScan());
    const spec: linux.itimerspec = .{ .it_interval = timespecOf(want_ms), .it_value = timespecOf(first_ms) };
    // On a failure the old state stays, so the next call tries again.
    if (linux.errno(linux.timerfd_settime(self.timer_fd, .{}, &spec, null)) != .SUCCESS) return;
    self.timer_ms = want_ms;
}

/// The error of the JNI setup, or null. With an error the backend runs without the AudioManager.
pub fn jniSetupError(self: *const AAudio) ?java.Error {
    return self.jni_error;
}

/// Reads the devices from the AudioManager and updates the Mixer. A failed Java call leaves the
/// Mixer as it was.
pub fn scan(self: *AAudio) audio_manager.ScanError!void {
    const view = if (self.view) |*v| v else return;
    try view.scan(self);
}

/// Scans, moves the deadline of the next scan and counts a failed Java call.
fn pollScan(self: *AAudio) error{OutOfMemory}!void {
    self.next_scan_ns = nowNs() + @as(u64, self.options.poll_ms) * std.time.ns_per_ms;
    self.timer_ms = rearm;
    self.scan() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.JavaException, error.NullResult, error.VmFailure, error.NameTooLong => self.scan_errors += 1,
    };
}

fn from(ptr: *anyopaque) *AAudio {
    return @ptrCast(@alignCast(ptr));
}

fn entryOf(stream: *Stream) ?*Entry {
    return @ptrCast(@alignCast(stream.backend_data orelse return null));
}

fn deinitImpl(ptr: *anyopaque) void {
    const self = from(ptr);
    // A late error callback of AAudio can still write to a freed entry or to `wake_fd`. AAudio gives no way to wait for it.
    self.closeAll();
    self.freeRetired();
    if (self.view) |*view| view.deinit();
    self.entries.deinit(self.gpa);
    self.retired.deinit(self.gpa);
    self.devices.deinit(self.gpa);
    self.closeWait();
    self.gpa.destroy(self);
}

fn dispatchImpl(ptr: *anyopaque) Backend.DispatchError!Backend.Event {
    const self = from(ptr);
    self.drainWait();
    if (!self.connected) return .none;
    self.freeRetired();
    var lost = false;
    var disconnected = false;
    var succeeded = false;
    var reopened = false;
    const now = nowNs();
    const count = self.entries.items.len;
    const first = self.rotate;
    const retry_ns = @as(u64, @max(self.options.reopen_retry_ms, 1)) * std.time.ns_per_ms;
    const stable_ns = @as(u64, self.options.reopen_stable_ms) * std.time.ns_per_ms;
    for (self.entries.items) |entry| {
        const stable = entry.opened_ns != 0 and now >= entry.opened_ns + stable_ns;
        if (!entry.retrying and entry.retry_until_ns != 0 and stable) entry.retry_until_ns = 0;
    }
    for (0..count) |step| {
        const index = (first + step) % count;
        const entry = self.entries.items[index];
        const flagged = entry.dirty.load(.acquire) != 0;
        const due = entry.retrying and now >= entry.retry_at_ns;
        if (!flagged and !due) continue;
        if (flagged and entry.error_code.load(.acquire) == aaudio.ResultCode.no_service) {
            _ = entry.dirty.swap(0, .acq_rel);
            _ = entry.error_code.swap(0, .acq_rel);
            disconnected = true;
            lost = true;
            continue;
        }
        // A reopen can block, so the other streams wait for the next dispatch.
        if (reopened) {
            self.wake();
            continue;
        }
        if (entry.dirty.swap(0, .acq_rel) != 0) {
            disconnected = true;
            if (entry.error_code.swap(0, .acq_rel) == aaudio.ResultCode.no_service) {
                lost = true;
                continue;
            }
            const retrying = entry.retrying;
            const had_deadline = entry.retry_until_ns != 0;
            if (entry.retry_until_ns == 0) entry.retry_until_ns = now + @as(u64, self.options.reopen_give_up_ms) * std.time.ns_per_ms;
            if (retrying and now < entry.retry_at_ns) continue;
            // The stream did not live long enough since the first failure, and the time is over.
            if (had_deadline and now >= entry.retry_until_ns) {
                self.failTry(entry);
                continue;
            }
            // A stream that breaks again at once counts as a failed try.
            if (entry.opened_ns != 0 and now < entry.opened_ns + retry_ns) {
                self.failTry(entry);
                continue;
            }
        }
        reopened = true;
        self.rotate = index + 1;
        succeeded = true;
        self.reopen(entry, entry.android_device, .close_first) catch {
            succeeded = false;
            if (self.last_result == aaudio.ResultCode.no_service) {
                lost = true;
                continue;
            }
            self.failTry(entry);
        };
    }
    self.endOutage(&lost, succeeded);
    if (lost) {
        self.connected = false;
        self.closeAll();
        return .disconnected;
    }
    if (self.view != null and (disconnected or (self.scanEnabled() and nowNs() >= self.next_scan_ns))) try self.pollScan();
    self.pollDrain();
    self.updateTimer();
    return .none;
}

/// Counts a failed try to reopen. When the next try would pass the deadline, the stream gives up.
fn failTry(self: *AAudio, entry: *Entry) void {
    const next = nowNs() + @as(u64, @max(self.options.reopen_retry_ms, 1)) * std.time.ns_per_ms;
    if (next >= entry.retry_until_ns) {
        entry.retry_until_ns = 0;
        entry.retrying = false;
        entry.restart = false;
        entry.gave_up = true;
        // The flag belongs to the dead handle.
        entry.dirty.store(0, .release);
        entry.error_code.store(0, .release);
        if (entry.started) self.halt(entry, false);
    } else {
        entry.retrying = true;
        entry.retry_at_ns = next;
    }
}

/// An outage window starts at the first stream that gives up and ends when a reopen works or no
/// stream waits for a try. If every stream gave up inside the window, the service is lost.
fn endOutage(self: *AAudio, lost: *bool, succeeded: bool) void {
    var any = false;
    var pending = false;
    var everyone = true;
    for (self.entries.items) |entry| {
        const waits = entry.retrying or entry.dirty.load(.acquire) != 0;
        any = any or entry.gave_up;
        pending = pending or waits;
        // An idle stream with no error took no part in the outage.
        const took_part = entry.gave_up or entry.stale or waits or entry.started or entry.restart;
        everyone = everyone and (entry.gave_up or !took_part);
    }
    if (!any or (pending and !succeeded)) return;
    if (everyone and !succeeded) {
        lost.* = true;
    } else {
        for (self.entries.items) |entry| {
            if (!entry.gave_up) continue;
            _ = entry.stream.markDisconnected();
            entry.stale = true;
        }
    }
    for (self.entries.items) |entry| entry.gave_up = false;
}

fn freeRetired(self: *AAudio) void {
    for (self.retired.items) |entry| self.gpa.destroy(entry);
    self.retired.clearRetainingCapacity();
}

/// The state of the stream after AAudio has handled its pending commands. `getState` alone does
/// not update the state, so the poll goes through a wait with a zero timeout.
fn currentState(self: *AAudio, handle: *aaudio.AStream) i32 {
    var next: i32 = aaudio.State.unknown;
    _ = self.api.waitForStateChange(handle, aaudio.State.unknown, &next, 0);
    return next;
}

/// Stops the streams that drain and ends the drain when AAudio has stopped them.
fn pollDrain(self: *AAudio) void {
    for (self.entries.items) |entry| {
        const handle = entry.handle orelse continue;
        const stream = entry.stream;
        switch (stream.state()) {
            .draining => switch (entry.drain_stage) {
                0 => {
                    const result = self.api.requestStop(handle);
                    if (result == aaudio.ResultCode.ok) {
                        entry.drain_stage = 1;
                    } else if (result == aaudio.ResultCode.disconnected) {
                        // The next dispatch reopens the stream, and the drain starts again.
                        self.markDead(entry, handle);
                    } else {
                        // The stream may still run, so a later stop or close must call requestStop.
                        endDrain(entry);
                        entry.started = true;
                    }
                },
                else => {
                    const now = self.currentState(handle);
                    if (now == aaudio.State.stopped or now == aaudio.State.disconnected) endDrain(entry);
                },
            },
            .running => {
                if (entry.drain_stage != 0 and self.currentState(handle) == aaudio.State.stopped) {
                    // The app started the stream again while it drained.
                    entry.drain_stage = 0;
                    entry.started = false;
                    self.startHandle(entry) catch {
                        _ = stream.markDisconnected();
                    };
                }
            },
            .idle => {
                entry.drain_stage = 0;
            },
            .stopped => {
                entry.drain_stage = 0;
                // The callback of the user returned `.stop`. The device runs until the stop.
                if (entry.started) self.halt(entry, true);
            },
        }
    }
}

fn endDrain(entry: *Entry) void {
    entry.started = false;
    entry.drain_stage = 0;
    entry.stream.drained();
}

fn reconnectImpl(ptr: *anyopaque) Backend.ConnectError!void {
    const self = from(ptr);
    if (self.connected) return;
    var builder: ?*aaudio.StreamBuilder = null;
    if (self.api.createStreamBuilder(&builder) != aaudio.ResultCode.ok) return error.BackendUnavailable;
    if (builder) |b| _ = self.api.deleteBuilder(b);
    if (self.view != null) try self.pollScan();
    self.connected = true;
    self.updateTimer();
}

fn realtimeImpl(ptr: *anyopaque) Backend.Realtime {
    const value: u8 = @intCast(from(ptr).rt.load(.acquire));
    return @fromBackingInt(@intCast(value));
}

fn timeoutMsImpl(ptr: *anyopaque) ?u32 {
    _ = ptr;
    return null;
}

fn fdImpl(ptr: *anyopaque) ?i32 {
    return from(ptr).wait_fd;
}

fn capabilitiesImpl(ptr: *anyopaque) Mixer.Capabilities {
    return .{
        .move_stream = true,
        .endpoint_volume = from(ptr).view != null,
    };
}

/// The Android device id for the device of the stream.
fn androidDevice(self: *AAudio, options: Stream.Options) Stream.OpenError!i32 {
    const id = options.device orelse return aaudio.unspecified;
    const wanted = kindOf(options.direction);
    for (self.devices.items) |row| {
        if (row.id == id and row.kind == wanted) return row.android_id;
    }
    return error.UnknownDevice;
}

fn kindOf(direction: Stream.Direction) Mixer.Kind {
    return switch (direction) {
        .playback => .sink,
        .capture => .source,
    };
}

/// The channel mask that the open sets, or null when AAudio chooses the order of the channels.
fn channelMask(self: *const AAudio, channels: Format.Channels, playback: bool) ?u32 {
    if (channels.count <= 2 or self.api.setChannelMask == null) return null;
    const mask = map.maskFromChannels(channels) orelse return null;
    return if (playback or mask == input_5_1) mask else null;
}

fn layoutOf(user: Format.Channels, count: u8, mask: ?u32, canonical: bool) Format.Channels {
    if (count <= 2) return if (count == user.count) user else map.canonicalChannels(count);
    if (mask) |m| {
        if (@popCount(m) == count) return map.channelsFromMask(m);
    }
    return if (canonical) map.canonicalChannels(count) else map.auxChannels(count);
}

fn openStreamImpl(ptr: *anyopaque, stream: *Stream) Stream.OpenError!Backend.Negotiated {
    const self = from(ptr);
    if (!self.connected) return error.Disconnected;
    const options = stream.options;
    const device = try self.androidDevice(options);
    if (options.direction == .capture and self.recordDenied()) return error.PermissionDenied;
    try self.retired.ensureTotalCapacity(self.gpa, self.entries.items.len + self.retired.items.len + 1);
    const entry = try self.gpa.create(Entry);
    errdefer self.gpa.destroy(entry);
    entry.* = .{ .backend = self, .stream = stream, .app_id = self.newId(), .android_device = device, .playback = options.direction == .playback };
    const opened = self.openHandle(entry, device) catch |err| {
        // The system gives INTERNAL for a missing permission. Only the permission check tells a denial.
        const internal = self.last_result == aaudio.ResultCode.internal;
        if (err == error.Disconnected and options.direction == .capture and internal and self.recordDenied()) return error.PermissionDenied;
        return err;
    };
    errdefer _ = self.api.close(opened.handle);
    try self.entries.append(self.gpa, entry);
    errdefer _ = self.entries.pop();
    const endpoint = options.device orelse self.mixer.default(kindOf(options.direction));
    try self.mixer.putStream(.{
        .id = entry.app_id,
        .direction = options.direction,
        .app_name = self.app_name,
        .name = self.app_name,
        .endpoint = endpoint,
        .volume = .{},
    });
    entry.handle = opened.handle;
    entry.setNative(opened.negotiated.native);
    stream.backend_data = entry;
    stream.pending_native = null;
    return opened.negotiated;
}

fn recordDenied(self: *AAudio) bool {
    const view = if (self.view) |*v| v else return false;
    return !view.recordAllowed();
}

/// Opens an AAudio stream for the entry. It asks for float samples first and I16 when the system
/// refuses.
fn openHandle(self: *AAudio, entry: *Entry, device: i32) Stream.OpenError!Opened {
    const formats = [_]i32{ aaudio.Format.pcm_float, aaudio.Format.pcm_i16 };
    self.last_result = aaudio.ResultCode.ok;
    var handle: ?*aaudio.AStream = null;
    for (formats, 0..) |sample, attempt| {
        const result = self.tryOpen(entry, device, sample, &handle);
        if (result == aaudio.ResultCode.ok) break;
        self.last_result = result;
        const retry = result == aaudio.ResultCode.invalid_format or result == aaudio.ResultCode.illegal_argument;
        if (retry and attempt + 1 < formats.len) continue;
        if (result == aaudio.ResultCode.unavailable and device == aaudio.unspecified) return error.Disconnected;
        return map.openError(result);
    }
    const stream = handle orelse return error.Disconnected;
    errdefer _ = self.api.close(stream);
    return .{ .handle = stream, .negotiated = try self.readBack(entry, stream) };
}

fn tryOpen(self: *AAudio, entry: *Entry, device: i32, sample: i32, out: *?*aaudio.AStream) aaudio.Result {
    const a = self.api;
    const options = entry.stream.options;
    var builder: ?*aaudio.StreamBuilder = null;
    const created = a.createStreamBuilder(&builder);
    if (created != aaudio.ResultCode.ok) return created;
    const b = builder orelse return aaudio.ResultCode.null_pointer;
    const playback = options.direction == .playback;
    a.setDirection(b, if (playback) aaudio.Direction.output else aaudio.Direction.input);
    a.setSharingMode(b, if (self.options.exclusive) aaudio.SharingMode.exclusive else aaudio.SharingMode.shared);
    a.setPerformanceMode(b, switch (self.options.performance) {
        .low_latency => aaudio.PerformanceMode.low_latency,
        .none => aaudio.PerformanceMode.none,
        .power_saving => aaudio.PerformanceMode.power_saving,
    });
    a.setFormat(b, sample);
    a.setSampleRate(b, aaudio.unspecified);
    const channels = options.format.channels;
    a.setChannelCount(b, channels.count);
    if (a.setChannelMask) |set_mask| {
        if (self.channelMask(channels, playback)) |mask| set_mask(b, mask);
    }
    a.setDeviceId(b, device);
    if (playback) {
        if (a.setUsage) |f| f(b, map.usage(options.role));
        if (a.setContentType) |f| f(b, map.contentType(options.role));
    } else {
        if (a.setInputPreset) |f| f(b, map.inputPreset(options.role));
    }
    a.setDataCallback(b, onData, entry);
    a.setErrorCallback(b, onError, entry);
    const result = a.openStream(b, out);
    _ = a.deleteBuilder(b);
    return result;
}

fn readBack(self: *AAudio, entry: *Entry, handle: *aaudio.AStream) Stream.OpenError!Backend.Negotiated {
    const a = self.api;
    const options = entry.stream.options;
    const playback = options.direction == .playback;
    const rate = a.getSampleRate(handle);
    const count = a.getChannelCount(handle);
    const sample = map.fromAAudioFormat(a.getFormat(handle)) orelse return error.UnsupportedFormat;
    if (rate <= 0 or count <= 0 or count > Format.max_channels) return error.UnsupportedFormat;
    const burst = a.getFramesPerBurst(handle);
    const capacity = a.getBufferCapacityInFrames(handle);
    var size: i64 = @max(2 * @as(i64, burst), options.latency_frames);
    if (capacity > 0) size = @min(size, capacity);
    _ = a.setBufferSizeInFrames(handle, @intCast(@min(size, std.math.maxInt(i32))));
    return .{
        .native = .{
            .sample = sample,
            .rate = @intCast(rate),
            .channels = layoutOf(options.format.channels, @intCast(count), self.channelMask(options.format.channels, playback), playback and self.api.setChannelMask == null),
        },
        .period_frames = @intCast(std.math.clamp(burst, 1, Backend.max_period_frames)),
    };
}

/// Replaces the AAudio stream of the entry. A dead stream closes first. A move opens first, so the
/// old stream stays when the new one does not open. A changed native format goes to
/// `pending_native`, and Context stops and starts the stream after it has swapped the pipeline.
fn reopen(self: *AAudio, entry: *Entry, device: i32, order: Order) Stream.OpenError!void {
    const was_started = entry.started or entry.restart;
    var old: ?*aaudio.AStream = null;
    switch (order) {
        .close_first => {
            self.halt(entry, false);
            if (entry.handle) |handle| _ = self.api.close(handle);
            entry.handle = null;
            entry.restart = was_started;
            entry.dirty.store(0, .release);
            entry.error_code.store(0, .release);
        },
        .open_first => old = entry.handle,
    }
    const next = try self.openHandle(entry, device);
    if (old) |handle| {
        self.halt(entry, false);
        _ = self.api.close(handle);
        // An error of the new stream stays.
        if (entry.error_handle.load(.acquire) == @intFromPtr(handle)) {
            entry.dirty.store(0, .release);
            entry.error_code.store(0, .release);
        }
    }
    entry.handle = next.handle;
    entry.retrying = false;
    entry.restart = false;
    entry.gave_up = false;
    entry.stale = false;
    entry.opened_ns = nowNs();
    entry.android_device = device;
    entry.xruns_seen.store(0, .release);
    entry.drain_stage = 0;
    entry.setNative(next.negotiated.native);
    const stream = entry.stream;
    const previous = stream.negotiated;
    if (!previous.native.eql(next.negotiated.native) or previous.period_frames != next.negotiated.period_frames) {
        stream.pending_native = next.negotiated;
        return;
    }
    stream.pending_native = null;
    if (was_started) {
        self.startHandle(entry) catch {
            if (order == .close_first) {
                // The dispatch counts this as a failed try and the next try starts the stream.
                entry.restart = true;
                entry.opened_ns = 0;
                return error.Disconnected;
            }
            _ = stream.markDisconnected();
        };
    }
}

fn startRaw(self: *AAudio, entry: *Entry) aaudio.Result {
    const handle = entry.handle orelse return aaudio.ResultCode.disconnected;
    entry.wanted_running.store(1, .seq_cst);
    const result = self.api.requestStart(handle);
    if (result == aaudio.ResultCode.ok) {
        entry.started = true;
    } else {
        entry.wanted_running.store(0, .seq_cst);
    }
    return result;
}

fn startHandle(self: *AAudio, entry: *Entry) Stream.StartError!void {
    const result = self.startRaw(entry);
    if (result != aaudio.ResultCode.ok) return map.startError(result);
}

/// Records a disconnect that AAudio gave as the result of a call and not to the error callback.
fn markDead(self: *AAudio, entry: *Entry, handle: *aaudio.AStream) void {
    entry.error_handle.store(@intFromPtr(handle), .release);
    entry.error_code.store(aaudio.ResultCode.disconnected, .release);
    entry.dirty.store(1, .release);
    self.wake();
}

/// Returns after the audio thread has left the data callback of the entry. With `report`, a
/// disconnect that the stop finds goes to the next dispatch.
fn halt(self: *AAudio, entry: *Entry, report: bool) void {
    // This store and the load of `in_callback` need seq_cst, because the data callback stores
    // `in_callback` and then loads `wanted_running`.
    entry.wanted_running.store(0, .seq_cst);
    entry.drain_stage = 0;
    if (entry.handle) |handle| {
        if (entry.started) {
            const result = self.api.requestStop(handle);
            if (result == aaudio.ResultCode.ok) {
                var next: i32 = 0;
                _ = self.api.waitForStateChange(handle, aaudio.State.stopping, &next, stop_wait_ns);
            } else if (result == aaudio.ResultCode.disconnected and report) {
                self.markDead(entry, handle);
            }
        }
    }
    entry.started = false;
    while (entry.in_callback.load(.seq_cst) != 0) std.atomic.spinLoopHint();
}

fn destroyEntry(self: *AAudio, entry: *Entry) void {
    self.halt(entry, false);
    // The entry stays alive until close returns, because close ends the callback threads of AAudio.
    if (entry.handle) |handle| _ = self.api.close(handle);
    self.mixer.removeStream(entry.app_id);
    const i = std.mem.indexOfScalar(*Entry, self.entries.items, entry).?;
    _ = self.entries.swapRemove(i);
    entry.stream.backend_data = null;
    entry.stream.pending_native = null;
    self.retired.appendAssumeCapacity(entry);
}

fn closeAll(self: *AAudio) void {
    while (self.entries.items.len > 0) self.destroyEntry(self.entries.items[self.entries.items.len - 1]);
    self.updateTimer();
}

fn closeStreamImpl(ptr: *anyopaque, stream: *Stream) void {
    const self = from(ptr);
    const entry = entryOf(stream) orelse return;
    self.destroyEntry(entry);
    self.updateTimer();
}

/// Opens a new AAudio stream for a start. A lost service is left to the next dispatch.
fn reviveForStart(self: *AAudio, entry: *Entry) Stream.StartError!void {
    self.reopen(entry, entry.android_device, .close_first) catch {
        if (self.last_result == aaudio.ResultCode.no_service) {
            entry.error_code.store(aaudio.ResultCode.no_service, .release);
            entry.dirty.store(1, .release);
            self.wake();
        }
        return error.Disconnected;
    };
}

fn startStreamImpl(ptr: *anyopaque, stream: *Stream) Stream.StartError!void {
    const self = from(ptr);
    const entry = entryOf(stream) orelse return error.Disconnected;
    entry.stale = false;
    entry.drain_stage = 0;
    entry.restart = false;
    if (entry.handle == null) {
        try self.reviveForStart(entry);
        if (stream.pending_native != null) {
            self.wake();
            return;
        }
    }
    if (entry.started) {
        entry.wanted_running.store(1, .seq_cst);
        return;
    }
    var result = self.startRaw(entry);
    if (result == aaudio.ResultCode.disconnected) {
        // A route change can leave a dead handle that no error callback reported.
        try self.reviveForStart(entry);
        if (stream.pending_native != null) {
            self.wake();
            return;
        }
        result = self.startRaw(entry);
    }
    if (result != aaudio.ResultCode.ok) return map.startError(result);
}

fn stopStreamImpl(ptr: *anyopaque, stream: *Stream) void {
    const self = from(ptr);
    const entry = entryOf(stream) orelse return;
    entry.restart = false;
    // An idle stream needs no new handle. A later start opens one.
    entry.retrying = false;
    self.halt(entry, true);
    self.updateTimer();
}

fn setDefaultImpl(ptr: *anyopaque, k: Mixer.Kind, id: Mixer.Id) Mixer.Error!void {
    _ = ptr;
    _ = k;
    _ = id;
    return error.Unsupported;
}

/// The volume and mute belong to the default sink, because Android has one volume per stream type.
fn defaultSinkView(self: *AAudio, target: Mixer.Target) Mixer.Error!*audio_manager.View {
    const view = if (self.view) |*v| v else return error.Unsupported;
    const id = switch (target) {
        .endpoint => |id| id,
        .stream => return error.Unsupported,
    };
    if (self.mixer.default(.sink) != id) return error.Unsupported;
    return view;
}

fn setVolumeImpl(ptr: *anyopaque, target: Mixer.Target, values: []const f32) Mixer.Error!void {
    const self = from(ptr);
    const view = try self.defaultSinkView(target);
    if (values.len == 0) return error.InvalidVolume;
    try view.setVolume(self, values[0]);
}

fn setMuteImpl(ptr: *anyopaque, target: Mixer.Target, mute: bool) Mixer.Error!void {
    const self = from(ptr);
    const view = try self.defaultSinkView(target);
    try view.setMute(self, mute);
}

fn moveStreamImpl(ptr: *anyopaque, stream_id: Mixer.Id, endpoint_id: Mixer.Id) Mixer.Error!void {
    const self = from(ptr);
    const entry = for (self.entries.items) |e| {
        if (e.app_id == stream_id) break e;
    } else return error.UnknownObject;
    const wanted = kindOf(entry.stream.options.direction);
    const device = for (self.devices.items) |row| {
        if (row.id == endpoint_id and row.kind == wanted) break row;
    } else return error.UnknownObject;
    if (!self.connected) return error.UnknownObject;
    self.reopen(entry, device.android_id, .open_first) catch return error.UnknownObject;
    if (entry.stream.pending_native != null) self.wake();
    var value = (self.mixer.stream(stream_id) orelse return error.UnknownObject).*;
    value.endpoint = endpoint_id;
    try self.mixer.putStream(value);
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

fn probeRealtime(self: *AAudio) void {
    const rc = linux.syscall1(.sched_getscheduler, 0);
    const policy: isize = @bitCast(rc);
    const reset_on_fork = 0x40000000;
    const bare = policy & ~@as(isize, reset_on_fork);
    const realtime = policy >= 0 and (bare == 1 or bare == 2);
    self.rt.store(if (realtime) 1 else 2, .release);
}

fn onData(handle: ?*aaudio.AStream, user: ?*anyopaque, audio: ?*anyopaque, frames: i32) callconv(.c) i32 {
    const entry: *Entry = @ptrCast(@alignCast(user.?));
    entry.in_callback.store(1, .seq_cst);
    defer entry.in_callback.store(0, .release);
    const self = entry.backend;
    if (self.rt.load(.monotonic) == 0) self.probeRealtime();
    const data: [*]u8 = @ptrCast(audio orelse return aaudio.CallbackResult.@"continue");
    const count: usize = if (frames > 0) @intCast(frames) else 0;
    const bytes = data[0 .. count * entry.frame_bytes];
    if (entry.wanted_running.load(.seq_cst) == 0) {
        if (entry.playback) dsp.convert.silence(entry.sample, bytes);
        return aaudio.CallbackResult.@"continue";
    }
    const stream = entry.stream;
    const was_running = stream.state() == .running;
    if (entry.playback) stream.render(bytes) else stream.capture(bytes);
    // The app ends a drain and a stop of the user callback, because AAudio keeps the device running.
    const state = stream.state();
    if (was_running and (state == .draining or state == .stopped)) {
        self.wake();
    }
    if (handle) |h| {
        const total: u32 = @bitCast(self.api.getXRunCount(h));
        const delta = total -% entry.xruns_seen.load(.monotonic);
        if (delta < 1 << 30) {
            stream.noteXruns(delta);
            entry.xruns_seen.store(total, .monotonic);
        }
    }
    return aaudio.CallbackResult.@"continue";
}

fn onError(handle: ?*aaudio.AStream, user: ?*anyopaque, code: i32) callconv(.c) void {
    const entry: *Entry = @ptrCast(@alignCast(user.?));
    entry.error_handle.store(@intFromPtr(handle), .release);
    entry.error_code.store(code, .release);
    entry.dirty.store(1, .release);
    entry.backend.wake();
}

const support = @import("aaudio/backend_test.zig");
const Harness = support.Harness;
const Tone = support.Tone;
const readable = support.readable;
const expectSamples = support.expectSamples;
const wakeCount = support.wakeCount;
const stereo = support.stereo;
const fakes = support.fakes;
const Fake = fakes.Fake;
const testing = std.testing;
const on_linux = support.on_linux;

test {
    _ = support;
}

test "playback opens with the values of the builder and reads back the stream" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback(), .latency_frames = 512 });
    try testing.expect(s.nativeFormat().eql(stereo));
    try testing.expectEqual(@as(u32, 192), s.negotiated.period_frames);
    const last = h.fake.last;
    try testing.expectEqual(aaudio.Direction.output, last.direction);
    try testing.expectEqual(aaudio.Format.pcm_float, last.format);
    try testing.expectEqual(aaudio.unspecified, last.rate);
    try testing.expectEqual(@as(i32, 2), last.channels);
    try testing.expectEqual(@as(u32, 0), last.mask);
    try testing.expectEqual(aaudio.unspecified, last.device);
    try testing.expectEqual(aaudio.Usage.media, last.usage);
    try testing.expectEqual(aaudio.ContentType.music, last.content);
    try testing.expectEqual(aaudio.PerformanceMode.low_latency, last.performance);
    try testing.expectEqual(aaudio.SharingMode.shared, last.sharing);
    try testing.expectEqual(@as(i32, 512), h.fake.live()[0].buffer_size);
    try testing.expectEqual(h.fake.counts.builders, h.fake.counts.deleted);
    const small = try h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback(), .latency_frames = 100 });
    try testing.expectEqual(@as(i32, 384), h.fake.live()[1].buffer_size);
    try testing.expectEqual(@as(u32, 192), small.negotiated.period_frames);
}

test "a capture stream asks for an input preset" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{ .performance = .none, .exclusive = true });
    defer h.deinit();
    var tone: Tone = .{};
    _ = try h.open(.capture, &tone);
    const last = h.fake.last;
    try testing.expectEqual(aaudio.Direction.input, last.direction);
    try testing.expectEqual(aaudio.InputPreset.voice_recognition, last.preset);
    try testing.expectEqual(@as(i32, 0), last.usage);
    try testing.expectEqual(aaudio.PerformanceMode.none, last.performance);
    try testing.expectEqual(aaudio.SharingMode.exclusive, last.sharing);
}

test "the data callback renders the pipeline into the AAudio buffer" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    try testing.expectEqual(@as(u32, 1), h.fake.counts.starts);
    var buf: [96 * 8]u8 = undefined;
    try testing.expectEqual(@as(?i32, aaudio.CallbackResult.@"continue"), h.fake.live()[0].callOnce(&buf));
    try expectSamples(&buf, 0.25);
    try testing.expectEqual(@as(u64, 96), s.stats().frames);
    try testing.expectEqual(@as(u32, 1), tone.calls.load(.monotonic));
}

test "the data callback gives captured audio to the user" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.capture, &tone);
    try s.start();
    var buf: [64 * 8]u8 = undefined;
    for (std.mem.bytesAsSlice(f32, &buf)) |*v| v.* = 0.75;
    _ = h.fake.live()[0].callOnce(&buf);
    try testing.expectEqual(@as(f32, 0.75), tone.seen);
    try testing.expectEqual(@as(u64, 64), s.stats().frames);
}

test "the open falls back to 16 bit samples" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.i16_only = true;
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try testing.expectEqual(@as(u32, 2), h.fake.counts.opens);
    try testing.expectEqual(aaudio.Format.pcm_float, h.fake.tried[0]);
    try testing.expectEqual(aaudio.Format.pcm_i16, h.fake.tried[1]);
    try testing.expectEqual(Format.Sample.s16, s.nativeFormat().sample);
    try s.start();
    var buf: [32 * 4]u8 = undefined;
    _ = h.fake.live()[0].callOnce(&buf);
    for (std.mem.bytesAsSlice(i16, &buf)) |v| try testing.expect(v >= 8191 and v <= 8193);
    try testing.expectEqual(h.fake.counts.builders, h.fake.counts.deleted);
}

test "open results map to stream errors" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const R = aaudio.ResultCode;
    const rows = [_]struct { result: aaudio.Result, expected: Stream.OpenError, opens: u32 }{
        .{ .result = R.invalid_rate, .expected = error.UnsupportedFormat, .opens = 1 },
        .{ .result = R.illegal_argument, .expected = error.UnsupportedFormat, .opens = 2 },
        .{ .result = R.invalid_format, .expected = error.UnsupportedFormat, .opens = 2 },
        .{ .result = R.no_memory, .expected = error.OutOfMemory, .opens = 1 },
        .{ .result = R.no_free_handles, .expected = error.OutOfMemory, .opens = 1 },
        .{ .result = R.unavailable, .expected = error.Disconnected, .opens = 1 },
        .{ .result = R.internal, .expected = error.Disconnected, .opens = 1 },
        .{ .result = R.no_service, .expected = error.Disconnected, .opens = 1 },
    };
    var tone: Tone = .{};
    for (rows) |row| {
        h.fake.failOpens(row.result, std.math.maxInt(u32));
        const before = h.fake.counts.opens;
        try testing.expectError(row.expected, h.open(.playback, &tone));
        try testing.expectEqual(row.opens, h.fake.counts.opens - before);
    }
    try testing.expectEqual(@as(usize, 0), h.fake.live().len);
    try testing.expectEqual(h.fake.counts.builders, h.fake.counts.deleted);
    try testing.expectEqual(@as(usize, 0), h.ctx.mixer().streams().len);
}

test "a stream that names a device opens with its Android id" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const be = h.backend();
    const speaker = be.newId();
    const mic = be.newId();
    try be.putDevice(.{ .id = speaker, .android_id = 42, .kind = .sink });
    try be.putDevice(.{ .id = mic, .android_id = 43, .kind = .source });
    var tone: Tone = .{};
    _ = try h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback(), .device = speaker });
    try testing.expectEqual(@as(i32, 42), h.fake.last.device);
    const opens = h.fake.counts.opens;
    try testing.expectError(error.UnknownDevice, h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback(), .device = mic }));
    try testing.expectError(error.UnknownDevice, h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback(), .device = @fromBackingInt(999) }));
    try testing.expectEqual(opens, h.fake.counts.opens);
    h.fake.failOpens(aaudio.ResultCode.unavailable, 1);
    try testing.expectError(error.UnknownDevice, h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback(), .device = speaker }));
    be.removeDevice(speaker);
    try testing.expectError(error.UnknownDevice, h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback(), .device = speaker }));
}

test "more than two channels use a channel mask when the system has one" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const surround: Format = .{ .sample = .f32, .rate = 48000, .channels = .surround_5_1 };
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = surround, .callback = tone.callback() });
    try testing.expectEqual(@as(i32, 6), h.fake.last.channels);
    try testing.expectEqual(@as(u32, 0x3f), h.fake.last.mask);
    try testing.expect(s.nativeFormat().channels.eql(.surround_5_1));
    h.deinit();
    h.begin();
    h.fake.table.setChannelMask = null;
    h.fake.table.setUsage = null;
    try h.attach(.{});
    _ = try h.ctx.openStream(.{ .direction = .playback, .format = surround, .callback = tone.callback() });
    try testing.expectEqual(@as(i32, 6), h.fake.last.channels);
    try testing.expectEqual(@as(u32, 0), h.fake.last.mask);
    try testing.expectEqual(@as(i32, 0), h.fake.last.usage);
}

test "a different channel count from the system is the native layout" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.channels = 1;
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try testing.expect(s.nativeFormat().channels.eql(.mono));
    try testing.expectEqual(Format.Sample.f32, s.nativeFormat().sample);
    try s.start();
    var buf: [48 * 4]u8 = undefined;
    _ = h.fake.live()[0].callOnce(&buf);
    try expectSamples(&buf, 0.25);
}

test "bad read back values fail the open and close the stream" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    h.fake.format = aaudio.Format.iec61937;
    try testing.expectError(error.UnsupportedFormat, h.open(.playback, &tone));
    h.fake.format = null;
    h.fake.rate = 0;
    try testing.expectError(error.UnsupportedFormat, h.open(.playback, &tone));
    try testing.expectEqual(@as(u32, 2), h.fake.counts.closes);
    try testing.expectEqual(@as(usize, 0), h.fake.live().len);
    h.fake.rate = 48000;
    h.fake.burst = 1 << 20;
    const s = try h.open(.playback, &tone);
    try testing.expectEqual(@as(u32, Backend.max_period_frames), s.negotiated.period_frames);
    h.fake.burst = 0;
    const t = try h.open(.playback, &tone);
    try testing.expectEqual(@as(u32, 1), t.negotiated.period_frames);
}

test "stop returns after the data callback has left" {
    if (!on_linux or builtin.single_threaded) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{ .release = .init(0) };
    const s = try h.open(.playback, &tone);
    try s.start();
    var buf: [64 * 8]u8 = undefined;
    var pump: fakes.Pump = .{};
    try pump.start(h.fake.live()[0], &buf, 1);
    while (tone.entered.load(.acquire) == 0) std.atomic.spinLoopHint();
    const Stopper = struct {
        stream: *Stream,
        tone: *Tone,
        begun: std.atomic.Value(u32) = .init(0),
        calls_at_return: u32 = 0,

        fn run(self: *@This()) void {
            self.begun.store(1, .release);
            self.stream.stop();
            self.calls_at_return = self.tone.calls.load(.acquire);
        }
    };
    var stopper: Stopper = .{ .stream = s, .tone = &tone };
    const thread = try std.Thread.spawn(.{}, Stopper.run, .{&stopper});
    while (stopper.begun.load(.acquire) == 0) std.atomic.spinLoopHint();
    tone.release.store(1, .release);
    pump.join();
    thread.join();
    try testing.expectEqual(@as(u32, 1), stopper.calls_at_return);
    try testing.expectEqual(@as(u32, 1), h.fake.counts.stops);
    try testing.expectEqual(@as(u32, 1), h.fake.counts.waits);
    try testing.expectEqual(@as(u32, 1), tone.calls.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), h.fake.violations);
}

test "a stopped stream gets silence and the user is not called" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    s.stop();
    try testing.expectEqual(@as(?i32, null), h.fake.live()[0].callOnce(&.{}));
    var buf: [32 * 8]u8 = @splat(0x55);
    try testing.expectEqual(aaudio.CallbackResult.@"continue", h.fake.live()[0].callForced(&buf));
    try expectSamples(&buf, 0);
    try testing.expectEqual(@as(u32, 0), tone.calls.load(.monotonic));
    try s.start();
    try testing.expectEqual(@as(u32, 2), h.fake.counts.starts);
    _ = h.fake.live()[0].callOnce(&buf);
    try expectSamples(&buf, 0.25);
}

test "a disconnect reopens the stream on dispatch and starts it again" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    const fd = h.ctx.fd().?;
    try testing.expect(!readable(fd, 0));
    h.fake.live()[0].fireError(aaudio.ResultCode.disconnected);
    const entry = h.backend().entries.items[0];
    try testing.expectEqual(aaudio.ResultCode.disconnected, entry.error_code.load(.acquire));
    try testing.expectEqual(@as(u32, 1), entry.dirty.load(.acquire));
    try testing.expect(readable(fd, 0));
    try testing.expectEqual(Backend.Event.none, try h.ctx.dispatch());
    try testing.expectEqual(@as(u32, 2), h.fake.counts.opens);
    try testing.expectEqual(@as(u32, 1), h.fake.counts.closes);
    try testing.expectEqualSlices(fakes.Call, &.{ .open, .close, .open }, h.fake.calls());
    try testing.expect(!readable(fd, 0));
    try testing.expectEqual(@as(u32, 2), h.fake.counts.starts);
    try testing.expectEqual(@as(?Backend.Negotiated, null), s.pending_native);
    try testing.expectEqual(Stream.State.running, s.state());
    try testing.expectEqual(@as(u32, 0), entry.dirty.load(.acquire));
    var buf: [16 * 8]u8 = undefined;
    _ = h.fake.live()[0].callOnce(&buf);
    try expectSamples(&buf, 0.25);
    try testing.expectEqual(@as(u32, 0), h.fake.violations);
}

test "a reopen at another rate swaps the pipeline through pending_native" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    h.fake.rate = 44100;
    h.fake.live()[0].fireError(aaudio.ResultCode.disconnected);
    try testing.expectEqual(Backend.Event.none, try h.ctx.backend.dispatch());
    const pending = s.pending_native.?;
    try testing.expectEqual(@as(u32, 44100), pending.native.rate);
    try testing.expectEqual(@as(u32, 192), pending.period_frames);
    try testing.expectEqual(aaudio.State.open, h.fake.live()[0].state.load(.acquire));
    try testing.expectEqual(@as(u32, 1), h.fake.counts.starts);
    try testing.expectEqual(Backend.Event.none, try h.ctx.dispatch());
    try testing.expectEqual(@as(u32, 44100), s.nativeFormat().rate);
    try testing.expectEqual(@as(?Backend.Negotiated, null), s.pending_native);
    try testing.expectEqual(Stream.State.running, s.state());
    try testing.expectEqual(aaudio.State.started, h.fake.live()[0].state.load(.acquire));
    try testing.expectEqual(@as(u32, 2), h.fake.counts.starts);
    var buf: [441 * 8]u8 = undefined;
    _ = h.fake.live()[0].callOnce(&buf);
    _ = h.fake.live()[0].callOnce(&buf);
    const tail = std.mem.bytesAsSlice(f32, buf[buf.len - 64 * 4 ..]);
    for (tail) |v| try testing.expectApproxEqAbs(@as(f32, 0.25), v, 0.01);
}

test "an idle stream stays idle after a reopen at another rate" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    h.fake.rate = 44100;
    h.fake.live()[0].fireError(aaudio.ResultCode.disconnected);
    _ = try h.ctx.dispatch();
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 44100), s.nativeFormat().rate);
    try testing.expectEqual(Stream.State.idle, s.state());
    try testing.expectEqual(@as(u32, 0), h.fake.counts.starts);
}

test "a draining stream stops in AAudio and ends when the stream has stopped" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.hold_stopping = true;
    var tone: Tone = .{ .status = .drain };
    const s = try h.open(.playback, &tone);
    try s.start();
    var buf: [64 * 8]u8 = undefined;
    const fd = h.ctx.fd().?;
    try testing.expect(!readable(fd, 0));
    _ = h.fake.live()[0].callOnce(&buf);
    try expectSamples(&buf, 0.25);
    try testing.expectEqual(Stream.State.draining, s.state());
    try testing.expect(readable(fd, 0));
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 1), h.fake.counts.stops);
    try testing.expectEqual(Stream.State.draining, s.state());
    _ = h.fake.live()[0].callForced(&buf);
    try expectSamples(&buf, 0);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 1), h.fake.counts.stops);
    try testing.expectEqual(Stream.State.draining, s.state());
    h.fake.live()[0].completeStop();
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.stopped, s.state());
    try testing.expectEqual(@as(u32, 1), tone.calls.load(.monotonic));
    try s.start();
    try testing.expectEqual(@as(u32, 2), h.fake.counts.starts);
    try testing.expectEqual(Stream.State.running, s.state());
}

test "a stream that starts again during a drain keeps playing" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.hold_stopping = true;
    var tone: Tone = .{ .status = .drain };
    const s = try h.open(.playback, &tone);
    try s.start();
    var buf: [64 * 8]u8 = undefined;
    _ = h.fake.live()[0].callOnce(&buf);
    _ = try h.ctx.dispatch();
    tone.status = .@"continue";
    try s.start();
    try testing.expectEqual(Stream.State.running, s.state());
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 1), h.fake.counts.starts);
    h.fake.live()[0].completeStop();
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 2), h.fake.counts.starts);
    try testing.expectEqual(aaudio.State.started, h.fake.live()[0].state.load(.acquire));
    _ = h.fake.live()[0].callOnce(&buf);
    try expectSamples(&buf, 0.25);
}

test "new xruns reach the stream statistics" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    var buf: [32 * 8]u8 = undefined;
    h.fake.live()[0].xruns.store(3, .monotonic);
    _ = h.fake.live()[0].callOnce(&buf);
    try testing.expectEqual(@as(u64, 3), s.stats().xruns);
    _ = h.fake.live()[0].callOnce(&buf);
    try testing.expectEqual(@as(u64, 3), s.stats().xruns);
    h.fake.live()[0].xruns.store(5, .monotonic);
    _ = h.fake.live()[0].callOnce(&buf);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u64, 5), s.stats().xruns);
    try testing.expectEqual(@as(u64, 96), s.stats().frames);
}

test "NO_SERVICE on reopen disconnects the backend and a reconnect restores the streams" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var play: Tone = .{};
    var record: Tone = .{};
    const out = try h.open(.playback, &play);
    const in = try h.open(.capture, &record);
    try out.start();
    try in.start();
    try testing.expectEqual(@as(usize, 2), h.ctx.mixer().streams().len);
    for (h.fake.live()) |fs| fs.fireError(aaudio.ResultCode.disconnected);
    h.fake.failOpens(aaudio.ResultCode.no_service, std.math.maxInt(u32));
    try testing.expectEqual(Backend.Event.disconnected, try h.ctx.dispatch());
    try testing.expectEqual(@as(usize, 0), h.fake.live().len);
    try testing.expectEqual(Stream.State.stopped, out.state());
    try testing.expectEqual(Stream.State.stopped, in.state());
    try testing.expectEqual(@as(usize, 0), h.ctx.mixer().streams().len);
    try testing.expect(h.ctx.fd() != null);
    try testing.expectEqual(Backend.Event.none, try h.ctx.dispatch());
    try testing.expectError(error.Disconnected, h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = play.callback() }));
    h.fake.open_failures = 0;
    try h.ctx.reconnect();
    try testing.expectEqual(@as(usize, 2), h.fake.live().len);
    try testing.expectEqual(Stream.State.running, out.state());
    try testing.expectEqual(Stream.State.running, in.state());
    try testing.expectEqual(@as(usize, 2), h.ctx.mixer().streams().len);
    try testing.expectEqual(@as(u32, 0), h.fake.violations);
}

test "a reopen that fails for another reason stops only that stream" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(support.no_retry);
    defer h.deinit();
    var a: Tone = .{};
    var b: Tone = .{};
    const first = try h.open(.playback, &a);
    const second = try h.open(.playback, &b);
    try first.start();
    try second.start();
    h.fake.live()[0].fireError(aaudio.ResultCode.disconnected);
    h.fake.failOpens(aaudio.ResultCode.unavailable, std.math.maxInt(u32));
    try testing.expectEqual(Backend.Event.none, try h.ctx.dispatch());
    try testing.expectEqual(Stream.State.stopped, first.state());
    try testing.expectEqual(Stream.State.running, second.state());
    try testing.expectError(error.Disconnected, first.start());
    try testing.expectEqual(@as(usize, 1), h.fake.live().len);
    h.fake.open_failures = 0;
    try first.start();
    try testing.expectEqual(Stream.State.running, first.state());
    try testing.expectEqual(@as(usize, 2), h.fake.live().len);
    var buf: [16 * 8]u8 = undefined;
    _ = h.fake.live()[1].callOnce(&buf);
    try expectSamples(&buf, 0.25);
    h.ctx.closeStream(first);
    try testing.expectEqual(@as(usize, 1), h.fake.live().len);
}

test "a stale NO_SERVICE result does not disconnect the backend" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(support.no_retry);
    defer h.deinit();
    var tone: Tone = .{};
    h.fake.failOpens(aaudio.ResultCode.no_service, 1);
    try testing.expectError(error.Disconnected, h.open(.playback, &tone));
    const other = try h.open(.playback, &tone);
    const s = try h.open(.playback, &tone);
    try other.start();
    try s.start();
    h.fake.format = aaudio.Format.iec61937;
    h.fake.live()[1].fireError(aaudio.ResultCode.disconnected);
    try testing.expectEqual(Backend.Event.none, try h.ctx.dispatch());
    try testing.expect(h.backend().connected);
    try testing.expectEqual(Stream.State.stopped, s.state());
    try testing.expectEqual(Stream.State.running, other.state());
    try testing.expectEqual(@as(usize, 1), h.fake.live().len);
}

test "an error callback with NO_SERVICE disconnects without an open" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    h.fake.live()[0].fireError(aaudio.ResultCode.no_service);
    try testing.expectEqual(Backend.Event.disconnected, try h.ctx.dispatch());
    try testing.expectEqual(@as(u32, 1), h.fake.counts.opens);
    try testing.expectEqual(@as(usize, 0), h.fake.live().len);
}

test "an error that arrives during a reopen is kept" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{ .reopen_retry_ms = 1 });
    defer h.deinit();
    var tone: Tone = .{};
    _ = try h.open(.playback, &tone);
    h.fake.live()[0].fireError(aaudio.ResultCode.disconnected);
    h.fake.fire_on_open = aaudio.ResultCode.disconnected;
    _ = try h.ctx.dispatch();
    const entry = h.backend().entries.items[0];
    try testing.expectEqual(@as(u32, 1), entry.dirty.load(.acquire));
    try testing.expectEqual(aaudio.ResultCode.disconnected, entry.error_code.load(.acquire));
    h.fake.fire_on_open = null;
    const deadline = nowMs() + 5000;
    while (h.fake.counts.opens < 3 and nowMs() < deadline) {
        _ = readable(h.ctx.fd().?, 20);
        _ = try h.ctx.dispatch();
    }
    try testing.expectEqual(@as(u32, 3), h.fake.counts.opens);
    try testing.expectEqual(@as(u32, 0), entry.dirty.load(.acquire));
}

test "a failed stop ends the drain" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{ .status = .drain };
    const s = try h.open(.playback, &tone);
    try s.start();
    var buf: [64 * 8]u8 = undefined;
    _ = h.fake.live()[0].callOnce(&buf);
    h.fake.stop_result = aaudio.ResultCode.invalid_state;
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.stopped, s.state());
    h.fake.stop_result = aaudio.ResultCode.ok;
    tone.status = .@"continue";
    try s.start();
    try testing.expectEqual(Stream.State.running, s.state());
    h.ctx.closeStream(s);
    try testing.expectEqual(@as(u32, 2), h.fake.counts.stops);
}

test "the data callback wakes the app once when the stream drains" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.hold_stopping = true;
    var tone: Tone = .{ .status = .drain };
    const s = try h.open(.playback, &tone);
    try s.start();
    const be = h.backend();
    var buf: [64 * 8]u8 = undefined;
    try testing.expectEqual(@as(u64, 0), wakeCount(be));
    _ = h.fake.live()[0].callOnce(&buf);
    _ = h.fake.live()[0].callForced(&buf);
    _ = h.fake.live()[0].callForced(&buf);
    try testing.expectEqual(@as(u64, 1), wakeCount(be));
    _ = try h.ctx.dispatch();
    h.fake.live()[0].completeStop();
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.stopped, s.state());
    tone.status = .drain;
    try s.start();
    _ = h.fake.live()[0].callOnce(&buf);
    try testing.expectEqual(@as(u64, 1), wakeCount(be));
}

test "a drain polls AAudio without blocking and a timer wakes the app" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.hold_stopping = true;
    var tone: Tone = .{ .status = .drain };
    const s = try h.open(.playback, &tone);
    try s.start();
    const fd = h.ctx.fd().?;
    var buf: [64 * 8]u8 = undefined;
    _ = h.fake.live()[0].callOnce(&buf);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 1), h.fake.counts.stops);
    try testing.expect(readable(fd, 5000));
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.draining, s.state());
    try testing.expect(readable(fd, 5000));
    h.fake.live()[0].completeStop();
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.stopped, s.state());
    try testing.expect(h.fake.counts.polls > 0);
    try testing.expectEqual(h.fake.counts.polls, h.fake.counts.waits);
    try testing.expectEqual(@as(u32, 0), h.backend().timer_ms);
}

test "a capture stream takes a channel mask only when AAudio has an input mask" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const six: Format = .{ .sample = .f32, .rate = 48000, .channels = .surround_5_1 };
    const eight: Format = .{ .sample = .f32, .rate = 48000, .channels = .surround_7_1 };
    _ = try h.ctx.openStream(.{ .direction = .capture, .format = six, .callback = tone.callback() });
    try testing.expectEqual(@as(i32, 6), h.fake.last.channels);
    try testing.expectEqual(@as(u32, 0x3f), h.fake.last.mask);
    _ = try h.ctx.openStream(.{ .direction = .capture, .format = eight, .callback = tone.callback() });
    try testing.expectEqual(@as(i32, 8), h.fake.last.channels);
    try testing.expectEqual(@as(u32, 0), h.fake.last.mask);
}

test "a huge latency request does not overflow the buffer size" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.capacity = 0;
    var tone: Tone = .{};
    _ = try h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback(), .latency_frames = std.math.maxInt(u32) });
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), h.fake.live()[0].buffer_size);
}

test "xruns from AAudio are added in one step" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    var buf: [32 * 8]u8 = undefined;
    h.fake.live()[0].xruns.store(1 << 29, .monotonic);
    _ = h.fake.live()[0].callOnce(&buf);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u64, 1 << 29), s.stats().xruns);
}

test "a move that changes the native format wakes the app" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const be = h.backend();
    const speaker = be.newId();
    try be.putDevice(.{ .id = speaker, .android_id = 7, .kind = .sink });
    const mixer = h.ctx.mixer();
    try mixer.putEndpoint(.{ .id = speaker, .kind = .sink, .name = "speaker", .description = "Speaker", .volume = .{} });
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    const fd = h.ctx.fd().?;
    try testing.expect(!readable(fd, 0));
    h.fake.rate = 44100;
    try mixer.moveStream(mixer.streams()[0].id, speaker);
    try testing.expect(s.pending_native != null);
    try testing.expect(readable(fd, 0));
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 44100), s.nativeFormat().rate);
    try testing.expectEqual(Stream.State.running, s.state());
}

test "the realtime state is pending until the first data callback" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try testing.expectEqual(Backend.Realtime.pending, h.ctx.info().realtime);
    try s.start();
    var buf: [32 * 8]u8 = undefined;
    _ = h.fake.live()[0].callOnce(&buf);
    const state = h.ctx.info().realtime;
    try testing.expect(state == .yes or state == .no);
    try testing.expectEqual(Backend.Kind.aaudio, h.ctx.info().backend);
}

test "the backend reports its capabilities and refuses system changes" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var caps = h.ctx.backend.capabilities();
    try testing.expect(caps.move_stream);
    try testing.expect(!caps.endpoint_volume and !caps.set_default and !caps.stream_volume);
    try testing.expect(!caps.app_streams and !caps.profiles and !caps.ports);
    const sink = h.ctx.mixer().default(.sink).?;
    try testing.expectEqual(@as(usize, 2), h.ctx.mixer().endpoints().len);
    try testing.expect(h.ctx.mixer().default(.source) != null);
    try testing.expectError(error.Unsupported, h.ctx.backend.setDefault(.sink, sink));
    try testing.expectError(error.Unsupported, h.ctx.backend.setVolume(.{ .endpoint = sink }, &.{1}));
    try testing.expectError(error.Unsupported, h.ctx.backend.setMute(.{ .endpoint = sink }, true));
    try testing.expectError(error.Unsupported, h.ctx.backend.setProfile(sink, 0));
    try testing.expectError(error.Unsupported, h.ctx.backend.setPort(sink, 0));
    h.deinit();
    h.begin();
    try h.attach(h.jni(.{}));
    caps = h.ctx.backend.capabilities();
    try testing.expect(caps.endpoint_volume and caps.move_stream);
}

test "moveStream reopens the stream on the new device" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const be = h.backend();
    const speaker = be.newId();
    const mic = be.newId();
    try be.putDevice(.{ .id = speaker, .android_id = 7, .kind = .sink });
    try be.putDevice(.{ .id = mic, .android_id = 8, .kind = .source });
    const mixer = h.ctx.mixer();
    try mixer.putEndpoint(.{ .id = speaker, .kind = .sink, .name = "speaker", .description = "Speaker", .volume = .{} });
    try mixer.putEndpoint(.{ .id = mic, .kind = .source, .name = "mic", .description = "Mic", .volume = .{} });
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    const app = mixer.streams()[0].id;
    try testing.expectEqual(@as(?Mixer.Id, mixer.default(.sink)), mixer.streams()[0].endpoint);
    try mixer.moveStream(app, speaker);
    try testing.expectEqual(@as(i32, 7), h.fake.last.device);
    try testing.expectEqual(@as(?Mixer.Id, speaker), mixer.stream(app).?.endpoint);
    try testing.expectEqual(@as(u32, 2), h.fake.counts.opens);
    try testing.expectEqual(@as(u32, 1), h.fake.counts.closes);
    try testing.expectEqualSlices(fakes.Call, &.{ .open, .open, .close }, h.fake.calls());
    try testing.expectEqual(@as(u32, 2), h.fake.counts.starts);
    try testing.expectEqual(Stream.State.running, s.state());
    try testing.expectError(error.UnknownObject, mixer.moveStream(app, mic));
    h.fake.failOpens(aaudio.ResultCode.unavailable, 1);
    try testing.expectError(error.UnknownObject, h.ctx.backend.moveStream(app, mic));
    try testing.expectEqual(@as(usize, 1), h.fake.live().len);
    var buf: [16 * 8]u8 = undefined;
    _ = h.fake.live()[0].callOnce(&buf);
    try expectSamples(&buf, 0.25);
}

test "closing a stream that has no entry does nothing" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var s: Stream = undefined;
    s.backend_data = null;
    h.ctx.backend.closeStream(&s);
    h.ctx.backend.stopStream(&s);
    try testing.expectError(error.Disconnected, h.ctx.backend.startStream(&s));
    try testing.expectEqual(@as(u32, 0), h.fake.counts.closes);
}

test "the backend needs a table of functions off Android" {
    if (!on_linux or Backend.aaudio_enabled) return error.SkipZigTest;
    var mixer: Mixer = .init(testing.allocator);
    defer mixer.deinit();
    try testing.expectError(error.BackendUnavailable, create(.{
        .gpa = testing.allocator,
        .io = testing.io,
        .mixer = &mixer,
        .app_name = "test",
    }, .{}));
}

test "a failed create leaves no endpoint in the Mixer" {
    if (!on_linux) return error.SkipZigTest;
    var fake: Fake = undefined;
    fake.init(testing.allocator);
    defer fake.deinit();
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var mixer: Mixer = .init(failing.allocator());
        defer mixer.deinit();
        const created = create(.{
            .gpa = testing.allocator,
            .io = testing.io,
            .mixer = &mixer,
            .app_name = "test",
        }, .{ .api = &fake.table });
        if (created) |backend| {
            backend.deinit();
            try testing.expectEqual(@as(usize, 2), mixer.endpoints().len);
            break;
        } else |_| {
            try testing.expectEqual(@as(usize, 0), mixer.endpoints().len);
            try testing.expectEqual(@as(?Mixer.Id, null), mixer.default(.sink));
        }
    }
    try testing.expect(fail_index >= 3);
}

test "a failed move keeps the error of the old stream" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const be = h.backend();
    const speaker = be.newId();
    try be.putDevice(.{ .id = speaker, .android_id = 7, .kind = .sink });
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    const app = h.ctx.mixer().streams()[0].id;
    h.fake.live()[0].fireError(aaudio.ResultCode.disconnected);
    h.fake.failOpens(aaudio.ResultCode.unavailable, 1);
    try testing.expectError(error.UnknownObject, h.ctx.backend.moveStream(app, speaker));
    try testing.expectEqual(@as(u32, 1), be.entries.items[0].dirty.load(.acquire));
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 0), be.entries.items[0].dirty.load(.acquire));
    try testing.expectEqual(Stream.State.running, s.state());
    try testing.expectEqual(aaudio.State.started, h.fake.live()[0].state.load(.acquire));
}

test "NO_SERVICE on a reopen from start disconnects on the next dispatch" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(support.no_retry);
    defer h.deinit();
    var tone: Tone = .{};
    const other = try h.open(.playback, &tone);
    const s = try h.open(.playback, &tone);
    try other.start();
    try s.start();
    h.fake.live()[1].fireError(aaudio.ResultCode.disconnected);
    h.fake.failOpens(aaudio.ResultCode.unavailable, std.math.maxInt(u32));
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.stopped, s.state());
    h.fake.failOpens(aaudio.ResultCode.no_service, std.math.maxInt(u32));
    try testing.expectError(error.Disconnected, s.start());
    try testing.expect(readable(h.ctx.fd().?, 0));
    try testing.expectEqual(Backend.Event.disconnected, try h.ctx.dispatch());
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

test "a stop that finds a dead stream marks it, and a resume reopens it" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    const fd = h.ctx.fd().?;
    try testing.expect(!readable(fd, 0));
    h.fake.disconnect_on_stop = true;
    s.stop();
    h.fake.disconnect_on_stop = false;
    const entry = h.backend().entries.items[0];
    try testing.expectEqual(@as(u32, 1), entry.dirty.load(.acquire));
    try testing.expect(readable(fd, 0));
    try s.start();
    try testing.expectEqual(@as(u32, 2), h.fake.counts.opens);
    try testing.expectEqual(@as(usize, 1), h.fake.live().len);
    try testing.expectEqual(Stream.State.running, s.state());
    try testing.expectEqual(aaudio.State.started, h.fake.live()[0].state.load(.acquire));
    var buf: [16 * 8]u8 = undefined;
    _ = h.fake.live()[0].callOnce(&buf);
    try expectSamples(&buf, 0.25);
}

test "a dispatch after the stop reopens the stream and leaves it stopped" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    h.fake.disconnect_on_stop = true;
    s.stop();
    h.fake.disconnect_on_stop = false;
    try testing.expectEqual(Backend.Event.none, try h.ctx.dispatch());
    try testing.expectEqual(@as(u32, 2), h.fake.counts.opens);
    try testing.expectEqual(aaudio.State.open, h.fake.live()[0].state.load(.acquire));
    try testing.expectEqual(Stream.State.stopped, s.state());
    try s.start();
    try testing.expectEqual(@as(u32, 2), h.fake.counts.opens);
    try testing.expectEqual(aaudio.State.started, h.fake.live()[0].state.load(.acquire));
}

test "a start that finds a dead handle reopens once and starts" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    s.stop();
    h.fake.live()[0].state.store(aaudio.State.disconnected, .release);
    try s.start();
    try testing.expectEqual(@as(u32, 2), h.fake.counts.opens);
    try testing.expectEqual(@as(u32, 1), h.fake.counts.closes);
    try testing.expectEqual(aaudio.State.started, h.fake.live()[0].state.load(.acquire));
    h.fake.live()[0].state.store(aaudio.State.disconnected, .release);
    h.fake.failOpens(aaudio.ResultCode.unavailable, 1);
    s.stop();
    try testing.expectError(error.Disconnected, s.start());
}

test "a drain whose stop finds a dead stream reopens and drains again" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.hold_stopping = true;
    var tone: Tone = .{ .status = .drain };
    const s = try h.open(.playback, &tone);
    try s.start();
    var buf: [64 * 8]u8 = undefined;
    _ = h.fake.live()[0].callOnce(&buf);
    h.fake.disconnect_on_stop = true;
    _ = try h.ctx.dispatch();
    h.fake.disconnect_on_stop = false;
    const entry = h.backend().entries.items[0];
    try testing.expectEqual(@as(u32, 1), entry.dirty.load(.acquire));
    try testing.expectEqual(Stream.State.draining, s.state());
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 2), h.fake.counts.opens);
    try testing.expectEqual(aaudio.State.stopping, h.fake.live()[0].state.load(.acquire));
    h.fake.live()[0].completeStop();
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.stopped, s.state());
}

test "a reopen that fails is tried again on the timer and the stream starts when it works" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{ .reopen_retry_ms = 1, .reopen_give_up_ms = 5000 });
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    h.fake.live()[0].fireError(aaudio.ResultCode.disconnected);
    h.fake.failOpens(aaudio.ResultCode.unavailable, 3);
    const be = h.backend();
    try testing.expectEqual(Backend.Event.none, try h.ctx.dispatch());
    try testing.expectEqual(Stream.State.running, s.state());
    try testing.expectEqual(@as(usize, 0), h.fake.live().len);
    try testing.expect(be.entries.items[0].retrying);
    try testing.expectEqual(@as(u32, 1), be.timer_ms);
    const deadline = nowMs() + 5000;
    while (h.fake.live().len == 0 and nowMs() < deadline) {
        _ = readable(h.ctx.fd().?, 100);
        _ = try h.ctx.dispatch();
    }
    try testing.expectEqual(@as(usize, 1), h.fake.live().len);
    try testing.expectEqual(@as(u32, 5), h.fake.counts.opens);
    try testing.expectEqual(Stream.State.running, s.state());
    try testing.expectEqual(aaudio.State.started, h.fake.live()[0].state.load(.acquire));
    try testing.expect(!be.entries.items[0].retrying);
    try testing.expectEqual(@as(u32, 0), be.timer_ms);
}

test "a stop during the retries ends them and a later start opens the stream" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{ .reopen_retry_ms = 1, .reopen_give_up_ms = 5000 });
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    h.fake.live()[0].fireError(aaudio.ResultCode.disconnected);
    h.fake.failOpens(aaudio.ResultCode.unavailable, 1);
    _ = try h.ctx.dispatch();
    s.stop();
    const opens = h.fake.counts.opens;
    const deadline = nowMs() + 30;
    while (nowMs() < deadline) {
        _ = readable(h.ctx.fd().?, 5);
        _ = try h.ctx.dispatch();
    }
    try testing.expectEqual(opens, h.fake.counts.opens);
    try testing.expectEqual(@as(usize, 0), h.fake.live().len);
    try testing.expectEqual(@as(u32, 0), h.backend().timer_ms);
    h.fake.open_failures = 0;
    try s.start();
    try testing.expectEqual(@as(usize, 1), h.fake.live().len);
    try testing.expectEqual(aaudio.State.started, h.fake.live()[0].state.load(.acquire));
}

test "one dispatch reopens one stream and leaves the others for the next one" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const first = try h.open(.playback, &tone);
    const second = try h.open(.playback, &tone);
    try first.start();
    try second.start();
    for (h.fake.live()) |fs| fs.fireError(aaudio.ResultCode.disconnected);
    const before = h.fake.counts.opens;
    _ = try h.ctx.dispatch();
    try testing.expectEqual(before + 1, h.fake.counts.opens);
    try testing.expect(readable(h.ctx.fd().?, 0));
    _ = try h.ctx.dispatch();
    try testing.expectEqual(before + 2, h.fake.counts.opens);
    try testing.expectEqual(Stream.State.running, first.state());
    try testing.expectEqual(Stream.State.running, second.state());
}

test "a stream that gave up earlier does not make a later failure a lost service" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(support.no_retry);
    defer h.deinit();
    var tone: Tone = .{};
    const first = try h.open(.playback, &tone);
    const second = try h.open(.playback, &tone);
    try first.start();
    try second.start();
    h.fake.live()[0].fireError(aaudio.ResultCode.disconnected);
    h.fake.failOpens(aaudio.ResultCode.unavailable, std.math.maxInt(u32));
    try testing.expectEqual(Backend.Event.none, try h.ctx.dispatch());
    try testing.expectEqual(Stream.State.stopped, first.state());
    h.fake.live()[0].fireError(aaudio.ResultCode.disconnected);
    try testing.expectEqual(Backend.Event.none, try h.ctx.dispatch());
    try testing.expectEqual(Stream.State.stopped, second.state());
    try testing.expect(h.backend().connected);
}

fn expectLayout(h: *Harness, user: Format.Channels, mask: u32, native: Format.Channels, direction: Stream.Direction) !void {
    var tone: Tone = .{};
    const s = try h.ctx.openStream(.{ .direction = direction, .format = .{ .sample = .f32, .rate = 48000, .channels = user }, .callback = tone.callback() });
    try testing.expectEqual(mask, h.fake.last.mask);
    try testing.expect(s.nativeFormat().channels.eql(native));
}

test "with a channel mask the native layout follows the bit order" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const P = Format.Position;
    try expectLayout(&h, .init(&.{ .front_center, .front_left, .front_right }), 0x7, .init(&.{ .front_left, .front_right, .front_center }), .playback);
    try expectLayout(&h, .init(&.{ .front_left, .front_right, .rear_left, .rear_right, .front_center, .lfe }), 0x3f, .surround_5_1, .playback);
    try expectLayout(&h, .init(&.{ .front_left, .front_right, .side_left, .side_right, .rear_left, .rear_right, .front_center, .lfe }), 0x63f, .surround_7_1, .playback);
    const odd: Format.Channels = .init(&.{ .front_left, .front_right, P.aux(0) });
    try expectLayout(&h, odd, 0, map.auxChannels(3), .playback);
    try expectLayout(&h, .init(&.{ .front_left, .front_right, .rear_left, .rear_right, .front_center, .lfe }), 0x3f, .surround_5_1, .capture);
    try expectLayout(&h, .surround_7_1, 0, map.auxChannels(8), .capture);
}

test "without a channel mask output has the fixed layout of its count" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.table.setChannelMask = null;
    try h.attach(.{});
    defer h.deinit();
    try expectLayout(&h, .init(&.{ .front_center, .front_left, .front_right }), 0, .init(&.{ .front_left, .front_right, .front_center }), .playback);
    try expectLayout(&h, .init(&.{ .front_left, .front_right, .rear_left, .rear_right, .front_center, .lfe }), 0, .surround_5_1, .playback);
    try expectLayout(&h, .init(&.{ .front_left, .front_right, .side_left, .side_right, .rear_left, .rear_right, .front_center, .lfe }), 0, .surround_7_1, .playback);
    try expectLayout(&h, .surround_5_1, 0, map.auxChannels(6), .capture);
}

test "when every try fails the backend reports a disconnect and a reconnect restores the stream" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{ .reopen_retry_ms = 1, .reopen_give_up_ms = 5 });
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    h.fake.live()[0].fireError(aaudio.ResultCode.disconnected);
    h.fake.failOpens(aaudio.ResultCode.unavailable, std.math.maxInt(u32));
    const deadline = nowMs() + 5000;
    var event = try h.ctx.dispatch();
    while (event != .disconnected and nowMs() < deadline) {
        _ = readable(h.ctx.fd().?, 100);
        event = try h.ctx.dispatch();
    }
    try testing.expectEqual(Backend.Event.disconnected, event);
    try testing.expect(h.fake.counts.opens >= 2);
    try testing.expectEqual(@as(usize, 0), h.fake.live().len);
    try testing.expectEqual(Stream.State.stopped, s.state());
    h.fake.open_failures = 0;
    try h.ctx.reconnect();
    try testing.expectEqual(Stream.State.running, s.state());
    try testing.expectEqual(@as(usize, 1), h.fake.live().len);
}

test "an error of the new stream survives a move" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{ .reopen_retry_ms = 1 });
    defer h.deinit();
    const be = h.backend();
    const speaker = be.newId();
    try be.putDevice(.{ .id = speaker, .android_id = 7, .kind = .sink });
    const mixer = h.ctx.mixer();
    try mixer.putEndpoint(.{ .id = speaker, .kind = .sink, .name = "speaker", .description = "Speaker", .volume = .{} });
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    h.fake.fire_on_open = aaudio.ResultCode.disconnected;
    try mixer.moveStream(mixer.streams()[0].id, speaker);
    h.fake.fire_on_open = null;
    const entry = be.entries.items[0];
    try testing.expectEqual(@as(u32, 1), entry.dirty.load(.acquire));
    try testing.expectEqual(aaudio.ResultCode.disconnected, entry.error_code.load(.acquire));
    const deadline = nowMs() + 5000;
    while (h.fake.counts.opens < 3 and nowMs() < deadline) {
        _ = readable(h.ctx.fd().?, 20);
        _ = try h.ctx.dispatch();
    }
    try testing.expectEqual(@as(u32, 3), h.fake.counts.opens);
    try testing.expectEqual(@as(u32, 0), entry.dirty.load(.acquire));
}

test "a callback that returns stop ends the AAudio stream on the next dispatch" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{ .status = .stop };
    const s = try h.open(.playback, &tone);
    try s.start();
    const be = h.backend();
    var buf: [64 * 8]u8 = undefined;
    _ = h.fake.live()[0].callOnce(&buf);
    _ = h.fake.live()[0].callForced(&buf);
    try testing.expectEqual(Stream.State.stopped, s.state());
    try testing.expectEqual(@as(u64, 1), wakeCount(be));
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 1), h.fake.counts.stops);
    try testing.expectEqual(aaudio.State.stopped, h.fake.live()[0].state.load(.acquire));
    try testing.expect(!be.entries.items[0].started);
    tone.status = .@"continue";
    try s.start();
    try testing.expectEqual(Stream.State.running, s.state());
    try testing.expectEqual(aaudio.State.started, h.fake.live()[0].state.load(.acquire));
}

test "a layout that AAudio chooses is the native layout" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.table.setChannelMask = null;
    try h.attach(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const side: Format.Channels = .init(&.{ .front_left, .front_right, .side_left, .side_right });
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = .{ .sample = .f32, .rate = 48000, .channels = side }, .callback = tone.callback() });
    try testing.expect(s.nativeFormat().channels.eql(map.canonicalChannels(4)));
    h.deinit();
    h.begin();
    try h.attach(.{});
    const t = try h.ctx.openStream(.{ .direction = .playback, .format = .{ .sample = .f32, .rate = 48000, .channels = side }, .callback = tone.callback() });
    try testing.expect(t.nativeFormat().channels.eql(side));
    h.fake.channels = 8;
    const u = try h.ctx.openStream(.{ .direction = .playback, .format = .{ .sample = .f32, .rate = 48000, .channels = .surround_5_1 }, .callback = tone.callback() });
    try testing.expect(u.nativeFormat().channels.eql(map.auxChannels(8)));
}

test "two streams that lose the service together give one disconnect" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(support.no_retry);
    defer h.deinit();
    var tone: Tone = .{};
    const first = try h.open(.playback, &tone);
    const second = try h.open(.playback, &tone);
    try first.start();
    try second.start();
    for (h.fake.live()) |fs| fs.fireError(aaudio.ResultCode.disconnected);
    h.fake.failOpens(aaudio.ResultCode.unavailable, std.math.maxInt(u32));
    try testing.expectEqual(Backend.Event.none, try h.ctx.dispatch());
    try testing.expectEqual(Backend.Event.disconnected, try h.ctx.dispatch());
    try testing.expectEqual(@as(usize, 0), h.fake.live().len);
    try testing.expectEqual(Stream.State.stopped, first.state());
    try testing.expectEqual(Stream.State.stopped, second.state());
    try testing.expectEqual(Backend.Event.none, try h.ctx.dispatch());
    h.fake.open_failures = 0;
    try h.ctx.reconnect();
    try testing.expectEqual(Stream.State.running, first.state());
    try testing.expectEqual(Stream.State.running, second.state());
}

test "a stream that breaks again after each reopen gives up and reports one disconnect" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{ .reopen_retry_ms = 1, .reopen_give_up_ms = 50 });
    defer h.deinit();
    var tone_a: Tone = .{};
    var tone_b: Tone = .{};
    const a = try h.open(.playback, &tone_a);
    const b = try h.open(.playback, &tone_b);
    try a.start();
    try b.start();
    h.fake.fire_on_open = aaudio.ResultCode.disconnected;
    for (h.fake.live()) |fs| fs.fireError(aaudio.ResultCode.disconnected);
    var events: u32 = 0;
    const deadline = nowMs() + 5000;
    while (events == 0 and nowMs() < deadline) {
        if ((try h.ctx.dispatch()) == .disconnected) events += 1;
        _ = readable(h.ctx.fd().?, 1);
    }
    h.fake.fire_on_open = null;
    try testing.expectEqual(@as(u32, 1), events);
    try testing.expectEqual(Backend.Event.none, try h.ctx.dispatch());
    try testing.expect(h.fake.counts.opens <= 2 + 2 * 50 + 10);
    try testing.expectEqual(@as(usize, 0), h.fake.live().len);
    try testing.expectEqual(Stream.State.stopped, a.state());
    try testing.expectEqual(Stream.State.stopped, b.state());
}

test "an idle stream does not stop a lost service from being reported" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(support.no_retry);
    defer h.deinit();
    var tone: Tone = .{};
    const running = try h.open(.playback, &tone);
    _ = try h.open(.playback, &tone);
    try running.start();
    h.fake.live()[0].fireError(aaudio.ResultCode.disconnected);
    h.fake.failOpens(aaudio.ResultCode.unavailable, std.math.maxInt(u32));
    try testing.expectEqual(Backend.Event.disconnected, try h.ctx.dispatch());
}

test "the reopen of each waiting stream gets a turn" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const first = try h.open(.playback, &tone);
    const second = try h.open(.playback, &tone);
    try first.start();
    try second.start();
    h.fake.live()[0].fireError(aaudio.ResultCode.disconnected);
    h.fake.live()[1].fireError(aaudio.ResultCode.disconnected);
    _ = try h.ctx.dispatch();
    const be = h.backend();
    try testing.expect(be.entries.items[0].opened_ns != 0);
    try testing.expectEqual(@as(u64, 0), be.entries.items[1].opened_ns);
    be.entries.items[0].opened_ns = 0;
    h.fake.live()[1].fireError(aaudio.ResultCode.disconnected);
    h.fake.live()[0].fireError(aaudio.ResultCode.disconnected);
    _ = try h.ctx.dispatch();
    try testing.expect(be.entries.items[1].opened_ns != 0);
}

test "a stream that is disconnected again soon after a reopen is reopened at a bounded rate" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{ .reopen_retry_ms = 50, .reopen_give_up_ms = 300 });
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    const until = nowMs() + 400;
    while (nowMs() < until) {
        if (h.fake.live().len != 0) h.fake.live()[0].fireError(aaudio.ResultCode.disconnected);
        _ = try h.ctx.dispatch();
        _ = readable(h.ctx.fd().?, 5);
    }
    // Without the rule, each dispatch would reopen the stream.
    try testing.expect(h.fake.counts.opens >= 2 and h.fake.counts.opens <= 14);
}

test "a stream that dies soon after each reopen gives up and reports one disconnect" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{ .reopen_retry_ms = 10, .reopen_give_up_ms = 300, .reopen_stable_ms = 200 });
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    var seen_opens = h.fake.counts.opens;
    var opened_at = nowMs();
    var events: u32 = 0;
    const deadline = nowMs() + 10000;
    while (events == 0 and nowMs() < deadline) {
        if (h.fake.counts.opens != seen_opens) {
            seen_opens = h.fake.counts.opens;
            opened_at = nowMs();
        }
        if (h.fake.live().len != 0 and nowMs() >= opened_at + 60) {
            h.fake.live()[0].fireError(aaudio.ResultCode.disconnected);
            opened_at = nowMs();
        }
        if ((try h.ctx.dispatch()) == .disconnected) events += 1;
        _ = readable(h.ctx.fd().?, 5);
    }
    try testing.expectEqual(@as(u32, 1), events);
    try testing.expectEqual(Stream.State.stopped, s.state());
    try testing.expect(h.fake.counts.opens >= 3 and h.fake.counts.opens <= 14);
}
