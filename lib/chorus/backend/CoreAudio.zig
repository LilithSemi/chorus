//! The macOS backend. It plays and records through HALOutput audio units.
//! Listeners of the HAL only set dirty bits and write the wake pipe. `dispatch` reads the properties.
const std = @import("std");
const builtin = @import("builtin");
const Format = @import("../Format.zig");
const Mixer = @import("../Mixer.zig");
const Stream = @import("../Stream.zig");
const dsp = @import("../dsp.zig");
const Backend = @import("Backend.zig");
const ca = @import("coreaudio/api.zig");
const map = @import("coreaudio/map.zig");
const devices = @import("coreaudio/devices.zig");
const permission = @import("coreaudio/permission.zig");
const Props = @import("coreaudio/props.zig");
const Wake = @import("coreaudio/wake.zig");
const CoreAudio = @This();

const log = std.log.scoped(.chorus);

pub const kind: Backend.Kind = .coreaudio;

pub const Options = struct {
    /// The frameworks. Null means the system frameworks, where the target has them.
    api: ?ca.Binding = null,
    /// The microphone permission. Null means AVFoundation, read through the dynamic loader.
    permission: ?permission.Source = null,
    /// Milliseconds between the tries to open a stream again on the default device.
    reopen_retry_ms: u32 = 100,
    /// How many tries follow a failed reopen. After them the stream stays stopped. A start after the next default change opens it again.
    reopen_tries: u32 = 5,
};

const Entry = struct {
    backend: *CoreAudio,
    stream: *Stream,
    app_id: Mixer.Id,
    playback: bool,
    /// True when the stream has no device and follows the default.
    follows_default: bool,
    channels: u32,
    frame_bytes: usize,
    unit: ?ca.AudioUnit = null,
    device: ca.AudioObjectID = 0,
    rate: u32 = 0,
    /// The input buffer of a capture stream. The app thread changes it only while no callback runs.
    capture: []u8 = &.{},
    /// 1 while a callback runs.
    in_callback: std.atomic.Value(u32) = .init(0),
    /// 0 makes the callbacks give silence and skip the stream.
    wanted_running: std.atomic.Value(u32) = .init(0),
    dirty: std.atomic.Value(u32) = .init(0),
    /// Counts the overload events of the device. `dispatch` turns them into xruns.
    overloads: std.atomic.Value(u32) = .init(0),
    /// Counts the times the audio thread saw the stream leave `.running` for `.draining` or `.stopped`.
    drain_seq: std.atomic.Value(u32) = .init(0),
    /// Frames between the render call and the sound: device latency, safety offset and stream latency.
    latency_frames: u32 = 0,
    /// The listeners that are on, as `listen_*` bits.
    listening: u8 = 0,
    /// App thread only. True between a start and the stop.
    started: bool = false,
    /// App thread only. True when the stream ran before a reopen that has not started it again.
    restart: bool = false,
    /// App thread only. True when the device of the stream is gone for good.
    gone: bool = false,
    /// App thread only. Monotonic milliseconds at which a drain ends. 0 means none.
    drain_until_ms: u64 = 0,
    /// App thread only. The value of `drain_seq` that `pollDrain` has handled.
    drain_seen: u32 = 0,
    retrying: bool = false,
    retry_at_ms: u64 = 0,
    tries_left: u32 = 0,

    /// Audio thread. Wakes the app once when the stream left `.running` during the callback.
    fn wakeAtEnd(self: *Entry, was_running: bool) void {
        if (!was_running) return;
        const state = self.stream.state();
        if (state != .draining and state != .stopped) return;
        _ = self.drain_seq.fetchAdd(1, .release);
        self.backend.wake.signal();
    }
};

const Opened = struct {
    unit: ca.AudioUnit,
    device: ca.AudioObjectID,
    negotiated: Backend.Negotiated,
    capture: []u8,
    latency_frames: u32,
};

/// An endpoint of the Mixer and the device side behind it.
const Row = struct {
    id: Mixer.Id,
    device: ca.AudioObjectID,
    is_source: bool,
    side: devices.Side,
};

/// A control of a device that has a listener.
const Watch = struct { device: ca.AudioObjectID, address: devices.Address };

const sys_devices: u32 = 1 << 0;
const sys_default_out: u32 = 1 << 1;
const sys_default_in: u32 = 1 << 2;
const sys_restarted: u32 = 1 << 3;

const sys_units: u32 = 1 << 4;
const sys_controls: u32 = 1 << 5;

const dirty_alive: u32 = 1 << 1;
const dirty_rate: u32 = 1 << 2;

const listen_unit_device: u8 = 1 << 0;
const listen_unit_running: u8 = 1 << 1;
const listen_alive: u8 = 1 << 2;
const listen_rate: u8 = 1 << 3;
const listen_over: u8 = 1 << 4;

const system_selectors = [_]u32{
    ca.Selector.devices,
    ca.Selector.default_output_device,
    ca.Selector.default_input_device,
    ca.Selector.service_restarted,
};

/// Milliseconds until `dispatch` looks at a stream that drains, before it knows the end of the drain.
const drain_poll_ms = 10;
/// A drain lasts at least this many periods after the callback that ended the data.
const drain_periods = 3;
/// The top bit of the ids of streams. `map.endpointId` refuses devices that would set it.
const stream_id_bit: u32 = 1 << 31;
const max_slice_frames = 1 << 20;

gpa: std.mem.Allocator,
io: std.Io,
mixer: *Mixer,
app_name: []const u8,
options: Options,
binding: ca.Binding,
props: Props,
loader: permission.Loader,
entries: std.ArrayList(*Entry) = .empty,
/// The endpoints that the last scan put into the Mixer.
rows: std.ArrayList(Row) = .empty,
watches: std.ArrayList(Watch) = .empty,
wake: Wake,
/// The system listeners set these bits.
sys_dirty: std.atomic.Value(u32) = .init(0),
last_id: u32 = 0,
connected: bool = true,
/// True while the system listeners are on.
listening: bool = false,
/// 0 pending, 1 yes, 2 no.
rt: std.atomic.Value(u32) = .init(0),
/// Counts the unit listener calls that run. `deinit` waits for 0, because the HAL does not wait for them on a removal.
unit_calls: std.atomic.Value(u32) = .init(0),

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

fn systemBinding() ?ca.Binding {
    if (comptime builtin.os.tag == .macos) return .{ .self = @ptrCast(@constCast(&ca.native)), .table = &ca.native };
    return null;
}

pub fn create(ictx: Backend.InitContext, options: Options) Backend.ConnectError!Backend {
    const binding = options.api orelse systemBinding() orelse return error.BackendUnavailable;
    const wake = Wake.open() catch return error.BackendUnavailable;
    const self = ictx.gpa.create(CoreAudio) catch |err| {
        var unused = wake;
        unused.close();
        return err;
    };
    self.* = .{
        .gpa = ictx.gpa,
        .io = ictx.io,
        .mixer = ictx.mixer,
        .app_name = ictx.app_name,
        .options = options,
        .binding = binding,
        .props = .{ .binding = binding },
        .loader = permission.Loader.fromBinding(binding),
        .wake = wake,
    };
    errdefer {
        self.wake.close();
        ictx.gpa.destroy(self);
    }
    const desc = outputDescription();
    if (self.hal().componentFindNext(binding.self, &desc) == null) return error.BackendUnavailable;
    try self.addSystemListeners();
    errdefer self.rows.deinit(self.gpa);
    errdefer self.watches.deinit(self.gpa);
    errdefer self.removeSystemListeners(system_selectors.len);
    errdefer self.clearMixer();
    try self.rescan();
    return .{ .ptr = self, .vtable = &vtable, .kind = kind };
}

fn outputDescription() ca.AudioComponentDescription {
    return .{
        .componentType = ca.unit_type_output,
        .componentSubType = ca.unit_subtype_hal_output,
        .componentManufacturer = ca.unit_manufacturer_apple,
    };
}

fn hal(self: *const CoreAudio) *const ca.Api {
    return self.binding.table;
}

fn from(ptr: *anyopaque) *CoreAudio {
    return @ptrCast(@alignCast(ptr));
}

fn entryOf(stream: *Stream) ?*Entry {
    return @ptrCast(@alignCast(stream.backend_data orelse return null));
}

fn nowMs(self: *const CoreAudio) u64 {
    const stamp = std.Io.Timestamp.now(self.io, .awake);
    return @intCast(@max(stamp.toMilliseconds(), 0));
}

/// Gives ids with the top bit set. Endpoint ids never have it.
pub fn newId(self: *CoreAudio) Mixer.Id {
    self.last_id += 1;
    return @fromBackingInt(stream_id_bit | self.last_id);
}

// System listeners.

fn addSystemListeners(self: *CoreAudio) Backend.ConnectError!void {
    // Newer systems send the notifications without this. Older ones need it, and a refusal does no harm.
    const none: ?*anyopaque = null;
    const run_loop = ca.address(ca.Selector.run_loop, ca.Scope.global, ca.element_main);
    _ = self.hal().objectSetPropertyData(self.binding.self, ca.object_system, &run_loop, 0, null, @sizeOf(?*anyopaque), @ptrCast(&none));
    self.sys_dirty.store(0, .release);
    var added: usize = 0;
    errdefer self.removeSystemListeners(added);
    for (system_selectors) |selector| {
        const addr = ca.address(selector, ca.Scope.global, ca.element_main);
        const status = self.hal().objectAddPropertyListener(self.binding.self, ca.object_system, &addr, onSystem, self);
        if (status != ca.Status.ok) return error.BackendUnavailable;
        added += 1;
    }
    self.listening = true;
}

fn removeSystemListeners(self: *CoreAudio, upto: usize) void {
    for (system_selectors[0..upto]) |selector| {
        const addr = ca.address(selector, ca.Scope.global, ca.element_main);
        _ = self.hal().objectRemovePropertyListener(self.binding.self, ca.object_system, &addr, onSystem, self);
    }
    self.listening = false;
}

fn systemBit(selector: u32) u32 {
    return switch (selector) {
        ca.Selector.devices => sys_devices,
        ca.Selector.default_output_device => sys_default_out,
        ca.Selector.default_input_device => sys_default_in,
        ca.Selector.service_restarted => sys_restarted,
        else => 0,
    };
}

fn onSystem(
    object: ca.AudioObjectID,
    count: u32,
    addresses: [*]const ca.AudioObjectPropertyAddress,
    client: ?*anyopaque,
) callconv(.c) ca.OSStatus {
    _ = object;
    const self: *CoreAudio = @ptrCast(@alignCast(client.?));
    var bits: u32 = 0;
    for (addresses[0..count]) |addr| bits |= systemBit(addr.mSelector);
    if (bits == 0) return ca.Status.ok;
    _ = self.sys_dirty.fetchOr(bits, .release);
    self.wake.signal();
    return ca.Status.ok;
}

fn onDevice(
    object: ca.AudioObjectID,
    count: u32,
    addresses: [*]const ca.AudioObjectPropertyAddress,
    client: ?*anyopaque,
) callconv(.c) ca.OSStatus {
    _ = object;
    const entry: *Entry = @ptrCast(@alignCast(client.?));
    var bits: u32 = 0;
    for (addresses[0..count]) |addr| {
        bits |= switch (addr.mSelector) {
            ca.Selector.is_alive => dirty_alive,
            ca.Selector.nominal_sample_rate => dirty_rate,
            else => 0,
        };
        if (addr.mSelector == ca.Selector.processor_overload) _ = entry.overloads.fetchAdd(1, .monotonic);
    }
    if (bits == 0) return ca.Status.ok;
    _ = entry.dirty.fetchOr(bits, .release);
    entry.backend.wake.signal();
    return ca.Status.ok;
}

fn onControl(
    object: ca.AudioObjectID,
    count: u32,
    addresses: [*]const ca.AudioObjectPropertyAddress,
    client: ?*anyopaque,
) callconv(.c) ca.OSStatus {
    _ = object;
    _ = count;
    _ = addresses;
    const self: *CoreAudio = @ptrCast(@alignCast(client.?));
    _ = self.sys_dirty.fetchOr(sys_controls, .release);
    self.wake.signal();
    return ca.Status.ok;
}

fn onUnit(
    client: ?*anyopaque,
    unit: ca.AudioUnit,
    id: ca.AudioUnitPropertyID,
    scope: ca.AudioUnitScope,
    element: ca.AudioUnitElement,
) callconv(.c) void {
    _ = unit;
    _ = id;
    _ = scope;
    _ = element;
    // The HAL does not wait for this call when the unit listener is removed. The client data is the
    // backend and not the entry, and `deinit` waits for `unit_calls`. A call that has not yet counted
    // itself when `deinit` looks stays possible.
    const self: *CoreAudio = @ptrCast(@alignCast(client.?));
    _ = self.unit_calls.fetchAdd(1, .acq_rel);
    defer _ = self.unit_calls.fetchSub(1, .acq_rel);
    _ = self.sys_dirty.fetchOr(sys_units, .release);
    self.wake.signal();
}

// Mixer. Every function runs on the app thread.

fn kindOfSide(is_source: bool) Mixer.Kind {
    return if (is_source) .source else .sink;
}

fn rowOf(self: *const CoreAudio, id: Mixer.Id) ?Row {
    for (self.rows.items) |row| {
        if (row.id == id) return row;
    }
    return null;
}

fn unwatchAll(self: *CoreAudio) void {
    for (self.watches.items) |watch| {
        const addr = ca.address(watch.address.selector, watch.address.scope, watch.address.element);
        _ = self.hal().objectRemovePropertyListener(self.binding.self, watch.device, &addr, onControl, self);
    }
    self.watches.clearRetainingCapacity();
}

/// Listens to the controls of every row. A listener that the HAL refuses stays off.
fn watchAll(self: *CoreAudio) error{OutOfMemory}!void {
    var found: std.ArrayList(devices.Address) = .empty;
    defer found.deinit(self.gpa);
    for (self.rows.items) |row| {
        found.clearRetainingCapacity();
        try devices.watched(self.props, self.gpa, row.device, row.side, &found);
        for (found.items) |address| {
            const addr = ca.address(address.selector, address.scope, address.element);
            try self.watches.ensureUnusedCapacity(self.gpa, 1);
            if (self.hal().objectAddPropertyListener(self.binding.self, row.device, &addr, onControl, self) != ca.Status.ok) continue;
            self.watches.appendAssumeCapacity(.{ .device = row.device, .address = address });
        }
    }
}

/// Removes the endpoints of the Mixer and the listeners of their controls.
fn clearMixer(self: *CoreAudio) void {
    self.unwatchAll();
    for (self.rows.items) |row| self.mixer.removeEndpoint(row.id);
    self.rows.clearRetainingCapacity();
}

fn hasRow(rows: []const Row, id: Mixer.Id) bool {
    for (rows) |row| {
        if (row.id == id) return true;
    }
    return false;
}

fn putIfChanged(self: *CoreAudio, value: Mixer.Endpoint) error{OutOfMemory}!void {
    if (self.mixer.endpoint(value.id)) |old| {
        if (devices.sameEndpoint(old.*, value)) return;
    }
    try self.mixer.putEndpoint(value);
}

/// Reads the device list and the controls again and brings the Mixer in line. A device that does
/// not answer is left out. The device listeners follow the new rows.
fn rescan(self: *CoreAudio) error{OutOfMemory}!void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const scratch = arena.allocator();
    const listed = self.listDevices() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return self.scanAgain(),
    };
    defer self.gpa.free(listed);
    self.unwatchAll();
    // After the swap this list holds the old rows. Both cases free it here.
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(self.gpa);
    var found: std.ArrayList(Mixer.Endpoint) = .empty;
    defer found.deinit(self.gpa);
    for (listed) |device| {
        const info = try devices.scanDevice(self.props, scratch, device) orelse continue;
        for ([_]bool{ false, true }) |is_source| {
            const side = (if (is_source) info.source else info.sink) orelse continue;
            const id = map.endpointId(device, is_source) orelse continue;
            const controls = try devices.readControls(self.props, scratch, device, side);
            try rows.append(self.gpa, .{ .id = id, .device = device, .is_source = is_source, .side = side });
            try found.append(self.gpa, devices.endpoint(info, id, is_source, controls));
        }
    }
    std.mem.swap(std.ArrayList(Row), &self.rows, &rows);
    for (rows.items) |old| {
        if (!hasRow(self.rows.items, old.id)) self.mixer.removeEndpoint(old.id);
    }
    for (found.items) |value| try self.putIfChanged(value);
    try self.watchAll();
    self.updateDefaults();
}

/// Reads the volume, mute and data sources of every endpoint again.
fn refreshControls(self: *CoreAudio) error{OutOfMemory}!void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    for (self.rows.items) |row| {
        const old = self.mixer.endpoint(row.id) orelse continue;
        const controls = try devices.readControls(self.props, arena.allocator(), row.device, row.side);
        var value = old.*;
        value.volume = controls.volume;
        value.mute = controls.mute;
        value.ports = controls.ports;
        value.active_port = controls.active_port;
        try self.putIfChanged(value);
    }
}

fn updateDefaults(self: *CoreAudio) void {
    for ([_]bool{ false, true }) |is_source| {
        const selector = if (is_source) ca.Selector.default_input_device else ca.Selector.default_output_device;
        const device = self.props.objectValue(u32, ca.object_system, selector, ca.Scope.global) catch 0;
        const id = map.endpointId(device, is_source);
        const known = if (device != 0 and id != null and self.mixer.endpoint(id.?) != null) id else null;
        self.mixer.putDefault(kindOfSide(is_source), known);
    }
}

/// A control refresh that failed on memory runs again at the next dispatch.
fn refreshAgain(self: *CoreAudio) void {
    _ = self.sys_dirty.fetchOr(sys_controls, .release);
    self.wake.signal();
}

/// A scan that failed on memory runs again at the next dispatch.
fn scanAgain(self: *CoreAudio) void {
    _ = self.sys_dirty.fetchOr(sys_devices, .release);
    self.wake.signal();
}

// Callbacks of the IO thread. They use atomics and the stream only.

fn probeRealtime(self: *CoreAudio) void {
    var info: [ca.thread_time_constraint_count]u32 = @splat(0);
    var count: u32 = info.len;
    var is_default: u32 = 0;
    const kr = self.hal().threadPolicyGet(self.binding.self, ca.thread_time_constraint_policy, &info, &count, &is_default);
    self.rt.store(if (kr == 0 and is_default == 0) 1 else 2, .release);
}

fn onRender(
    ref: ?*anyopaque,
    flags: *ca.AudioUnitRenderActionFlags,
    time_stamp: *const ca.AudioTimeStamp,
    bus: u32,
    frames: u32,
    data: ?*ca.AudioBufferList,
) callconv(.c) ca.OSStatus {
    _ = time_stamp;
    _ = bus;
    const entry: *Entry = @ptrCast(@alignCast(ref.?));
    entry.in_callback.store(1, .seq_cst);
    defer entry.in_callback.store(0, .release);
    const self = entry.backend;
    if (self.rt.load(.monotonic) == 0) self.probeRealtime();
    const list = data orelse return ca.Status.ok;
    if (list.mNumberBuffers == 0) return ca.Status.ok;
    const buffer = &list.mBuffers[0];
    const dst: [*]u8 = @ptrCast(buffer.mData orelse return ca.Status.ok);
    const wanted = @min(@as(usize, frames) * entry.frame_bytes, buffer.mDataByteSize);
    const bytes = dst[0 .. wanted - wanted % entry.frame_bytes];
    if (entry.wanted_running.load(.seq_cst) == 0) {
        dsp.convert.silence(.f32, bytes);
        flags.* |= ca.render_action_output_is_silence;
        return ca.Status.ok;
    }
    const was_running = entry.stream.state() == .running;
    entry.stream.render(bytes);
    entry.wakeAtEnd(was_running);
    return ca.Status.ok;
}

fn onInput(
    ref: ?*anyopaque,
    flags: *ca.AudioUnitRenderActionFlags,
    time_stamp: *const ca.AudioTimeStamp,
    bus: u32,
    frames: u32,
    data: ?*ca.AudioBufferList,
) callconv(.c) ca.OSStatus {
    _ = data;
    const entry: *Entry = @ptrCast(@alignCast(ref.?));
    entry.in_callback.store(1, .seq_cst);
    defer entry.in_callback.store(0, .release);
    const self = entry.backend;
    if (self.rt.load(.monotonic) == 0) self.probeRealtime();
    const unit = entry.unit orelse return ca.Status.ok;
    const size = @as(usize, frames) * entry.frame_bytes;
    if (size > entry.capture.len) return ca.Status.unit_too_many_frames;
    var list: ca.AudioBufferList = .{
        .mNumberBuffers = 1,
        .mBuffers = .{.{ .mNumberChannels = entry.channels, .mDataByteSize = @intCast(size), .mData = entry.capture.ptr }},
    };
    const status = self.hal().unitRender(self.binding.self, unit, flags, time_stamp, bus, frames, &list);
    if (status != ca.Status.ok) return status;
    if (entry.wanted_running.load(.seq_cst) == 0) return ca.Status.ok;
    const was_running = entry.stream.state() == .running;
    entry.stream.capture(entry.capture[0..size]);
    entry.wakeAtEnd(was_running);
    return ca.Status.ok;
}

// Devices. `resolveDevice` and `deviceUsable` read the HAL. A table of the devices can replace them.

fn failure(err: map.Failure) Stream.OpenError {
    switch (err) {
        error.Unsupported, error.BadCall, error.Unexpected => if (comptime !builtin.cpu.arch.isWasm() and !builtin.is_test) {
            log.warn("the CoreAudio open failed with {s}", .{@errorName(err)});
        },
        else => {},
    }
    return openError(err);
}

fn openError(err: map.Failure) Stream.OpenError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedFormat, error.TooManyFrames, error.RateMismatch => error.UnsupportedFormat,
        error.UnknownDevice, error.UnknownObject => error.UnknownDevice,
        error.PermissionDenied => error.PermissionDenied,
        error.Disconnected => error.Disconnected,
        error.Unsupported, error.BadCall, error.Unexpected => error.Disconnected,
    };
}

fn openCheck(status: ca.OSStatus) Stream.OpenError!void {
    map.check(status) catch |err| {
        if (comptime !builtin.cpu.arch.isWasm() and !builtin.is_test) {
            if (map.statusText(status)) |text| {
                log.warn("the CoreAudio open got the status '{s}'", .{&text});
            } else {
                log.warn("the CoreAudio open got the status {d}", .{status});
            }
        }
        return openError(err);
    };
}

fn defaultDevice(self: *CoreAudio, direction: Stream.Direction) ca.AudioObjectID {
    const selector = switch (direction) {
        .playback => ca.Selector.default_output_device,
        .capture => ca.Selector.default_input_device,
    };
    return self.props.objectValue(u32, ca.object_system, selector, ca.Scope.global) catch 0;
}

/// The device that a stream names, or null when the stream follows the default.
fn resolveDevice(self: *CoreAudio, options: Stream.Options) Stream.OpenError!?ca.AudioObjectID {
    const id = options.device orelse return null;
    const parts = map.endpointParts(id);
    if (parts.is_source != (options.direction == .capture)) return error.UnknownDevice;
    const listed = self.listDevices() catch |err| return failure(err);
    defer self.gpa.free(listed);
    if (std.mem.indexOfScalar(ca.AudioObjectID, listed, parts.device) == null) return error.UnknownDevice;
    return parts.device;
}

/// The ids in `dev#`. The caller frees the slice.
fn listDevices(self: *CoreAudio) map.Failure![]ca.AudioObjectID {
    return self.props.objectList(self.gpa, ca.AudioObjectID, ca.object_system, ca.Selector.devices, ca.Scope.global);
}

/// False when the device is dead or no longer in `dev#`.
fn deviceUsable(self: *CoreAudio, device: ca.AudioObjectID) error{OutOfMemory}!bool {
    const alive = self.props.objectValue(u32, device, ca.Selector.is_alive, ca.Scope.global) catch return false;
    if (alive == 0) return false;
    const listed = self.listDevices() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return true,
    };
    defer self.gpa.free(listed);
    return std.mem.indexOfScalar(ca.AudioObjectID, listed, device) != null;
}

fn permissionSource(self: *CoreAudio) permission.Source {
    return self.options.permission orelse self.loader.source();
}

// Open and close.

fn bufferRequest(self: *CoreAudio, device: ca.AudioObjectID, playback: bool, latency: u32) u32 {
    const scope = if (playback) ca.Scope.output else ca.Scope.input;
    const range = self.props.objectValue(ca.AudioValueRange, device, ca.Selector.buffer_frame_size_range, scope) catch return latency;
    const limit: f64 = Backend.max_period_frames;
    const low: u32 = @intFromFloat(@ceil(std.math.clamp(range.mMinimum, 1, limit)));
    const high: u32 = @intFromFloat(@floor(std.math.clamp(range.mMaximum, 1, limit)));
    if (high < low) return latency;
    return std.math.clamp(latency, low, high);
}

fn nominalRate(self: *CoreAudio, device: ca.AudioObjectID, side: ca.AudioStreamBasicDescription) Stream.OpenError!u32 {
    const rate = self.props.objectValue(f64, device, ca.Selector.nominal_sample_rate, ca.Scope.global) catch side.mSampleRate;
    return rateOf(rate) orelse error.UnsupportedFormat;
}

fn rateOf(rate: f64) ?u32 {
    if (!(rate >= Format.min_rate and rate <= Format.max_rate)) return null;
    return @intFromFloat(@round(rate));
}

/// Frames between the render call and the sound: device latency, safety offset and the latency of
/// the first stream. A value that cannot be read counts as 0.
fn deviceLatency(self: *CoreAudio, device: ca.AudioObjectID, playback: bool) u32 {
    const scope = if (playback) ca.Scope.output else ca.Scope.input;
    const props = self.props;
    var total: u32 = 0;
    total +|= props.objectValue(u32, device, ca.Selector.latency, scope) catch 0;
    total +|= props.objectValue(u32, device, ca.Selector.safety_offset, scope) catch 0;
    const streams = props.objectList(self.gpa, ca.AudioObjectID, device, ca.Selector.streams, scope) catch return total;
    defer self.gpa.free(streams);
    if (streams.len == 0) return total;
    total +|= props.objectValue(u32, streams[0], ca.Selector.latency, ca.Scope.global) catch 0;
    return total;
}

/// Makes a unit for the entry on the device. The listeners are not on and the unit does not run.
fn openUnit(self: *CoreAudio, entry: *Entry, device: ca.AudioObjectID) Stream.OpenError!Opened {
    const h = self.hal();
    const s = self.binding.self;
    const props = self.props;
    const options = entry.stream.options;
    const playback = entry.playback;
    const desc = outputDescription();
    const component = h.componentFindNext(s, &desc) orelse return error.Disconnected;
    var made: ?ca.AudioUnit = null;
    try openCheck(h.componentInstanceNew(s, component, &made));
    const unit = made orelse return error.Disconnected;
    errdefer _ = h.componentInstanceDispose(s, unit);
    const U = ca.UnitProperty;
    if (!playback) {
        props.setUnitValue(u32, unit, U.enable_io, ca.UnitScope.input, 1, 1) catch |err| return failure(err);
        props.setUnitValue(u32, unit, U.enable_io, ca.UnitScope.output, 0, 0) catch |err| return failure(err);
    }
    props.setUnitValue(u32, unit, U.current_device, ca.UnitScope.global, 0, device) catch |err| return failure(err);
    const bus: u32 = if (playback) 0 else 1;
    const side_scope = if (playback) ca.UnitScope.output else ca.UnitScope.input;
    const client_scope = if (playback) ca.UnitScope.input else ca.UnitScope.output;
    const side = props.unitValue(ca.AudioStreamBasicDescription, unit, U.stream_format, side_scope, bus) catch |err| return failure(err);
    if (side.mChannelsPerFrame == 0) return error.UnknownDevice;
    const rate = try self.nominalRate(device, side);
    const client = map.f32Interleaved(@floatFromInt(rate), entry.channels);
    props.setUnitValue(ca.AudioStreamBasicDescription, unit, U.stream_format, client_scope, bus, client) catch |err| return failure(err);
    // A refusal keeps the buffer size that the device has. The read back below tells the size. The
    // size belongs to the device, so a later stream on it with another latency changes this one too.
    const request = self.bufferRequest(device, playback, options.latency_frames);
    _ = props.unitSet(u32, unit, ca.Selector.buffer_frame_size, ca.UnitScope.global, 0, request);
    const callback: ca.AURenderCallbackStruct = .{ .inputProc = if (playback) &onRender else &onInput, .inputProcRefCon = entry };
    const callback_id = if (playback) U.set_render_callback else U.set_input_callback;
    const callback_scope = if (playback) ca.UnitScope.input else ca.UnitScope.global;
    props.setUnitValue(ca.AURenderCallbackStruct, unit, callback_id, callback_scope, 0, callback) catch |err| return failure(err);
    try openCheck(h.unitInitialize(s, unit));
    errdefer _ = h.unitUninitialize(s, unit);
    const global = ca.UnitScope.global;
    const fsiz = props.unitValue(u32, unit, ca.Selector.buffer_frame_size, global, 0) catch |err| return failure(err);
    const period = std.math.clamp(fsiz, 1, Backend.max_period_frames);
    var slice = props.unitValue(u32, unit, U.maximum_frames_per_slice, global, 0) catch |err| return failure(err);
    if (slice < period) {
        _ = props.unitSet(u32, unit, U.maximum_frames_per_slice, global, 0, period);
        slice = props.unitValue(u32, unit, U.maximum_frames_per_slice, global, 0) catch |err| return failure(err);
    }
    if (slice < period or slice > max_slice_frames) return error.UnsupportedFormat;
    var capture: []u8 = &.{};
    if (!playback) capture = try self.gpa.alloc(u8, @as(usize, slice) * entry.frame_bytes);
    return .{
        .unit = unit,
        .device = device,
        .capture = capture,
        .latency_frames = self.deviceLatency(device, playback),
        .negotiated = .{
            .native = .{ .sample = .f32, .rate = rate, .channels = options.format.channels },
            .period_frames = period,
        },
    };
}

/// Puts an opened unit into the entry and turns the listeners on.
fn install(self: *CoreAudio, entry: *Entry, opened: Opened) Stream.OpenError!void {
    entry.unit = opened.unit;
    entry.device = opened.device;
    entry.rate = opened.negotiated.native.rate;
    entry.capture = opened.capture;
    entry.latency_frames = opened.latency_frames;
    self.attach(entry) catch |err| {
        self.destroyUnit(entry);
        return err;
    };
}

fn attach(self: *CoreAudio, entry: *Entry) error{Disconnected}!void {
    const h = self.hal();
    const s = self.binding.self;
    const unit = entry.unit.?;
    errdefer self.detach(entry);
    const unit_ids = [_]struct { id: u32, bit: u8 }{
        .{ .id = ca.UnitProperty.current_device, .bit = listen_unit_device },
        .{ .id = ca.UnitProperty.is_running, .bit = listen_unit_running },
    };
    for (unit_ids) |item| {
        if (h.unitAddPropertyListener(s, unit, item.id, onUnit, self) != ca.Status.ok) return error.Disconnected;
        entry.listening |= item.bit;
    }
    const device_ids = [_]struct { selector: u32, bit: u8 }{
        .{ .selector = ca.Selector.is_alive, .bit = listen_alive },
        .{ .selector = ca.Selector.nominal_sample_rate, .bit = listen_rate },
        .{ .selector = ca.Selector.processor_overload, .bit = listen_over },
    };
    for (device_ids) |item| {
        const addr = ca.address(item.selector, ca.Scope.global, ca.element_main);
        if (h.objectAddPropertyListener(s, entry.device, &addr, onDevice, entry) != ca.Status.ok) return error.Disconnected;
        entry.listening |= item.bit;
    }
}

/// Removes the listeners of the entry. The HAL waits for a running device listener call and does not wait for a unit listener call.
fn detach(self: *CoreAudio, entry: *Entry) void {
    const h = self.hal();
    const s = self.binding.self;
    if (entry.unit) |unit| {
        const unit_ids = [_]struct { id: u32, bit: u8 }{
            .{ .id = ca.UnitProperty.current_device, .bit = listen_unit_device },
            .{ .id = ca.UnitProperty.is_running, .bit = listen_unit_running },
        };
        for (unit_ids) |item| {
            if (entry.listening & item.bit != 0) _ = h.unitRemovePropertyListener(s, unit, item.id, onUnit, self);
        }
    }
    const device_ids = [_]struct { selector: u32, bit: u8 }{
        .{ .selector = ca.Selector.is_alive, .bit = listen_alive },
        .{ .selector = ca.Selector.nominal_sample_rate, .bit = listen_rate },
        .{ .selector = ca.Selector.processor_overload, .bit = listen_over },
    };
    for (device_ids) |item| {
        if (entry.listening & item.bit == 0) continue;
        const addr = ca.address(item.selector, ca.Scope.global, ca.element_main);
        _ = h.objectRemovePropertyListener(s, entry.device, &addr, onDevice, entry);
    }
    entry.listening = 0;
}

/// Frees the unit. The unit must not run and must have no listeners.
fn destroyUnit(self: *CoreAudio, entry: *Entry) void {
    const unit = entry.unit orelse return;
    _ = self.hal().unitUninitialize(self.binding.self, unit);
    _ = self.hal().componentInstanceDispose(self.binding.self, unit);
    entry.unit = null;
    self.gpa.free(entry.capture);
    entry.capture = &.{};
}

/// Stops the unit, removes the listeners and frees the unit.
fn release(self: *CoreAudio, entry: *Entry) void {
    self.halt(entry);
    self.detach(entry);
    self.destroyUnit(entry);
}

/// Returns after the audio thread has left the callback of the entry.
fn halt(self: *CoreAudio, entry: *Entry) void {
    // This store and the load of `in_callback` need seq_cst, because a callback stores
    // `in_callback` and then loads `wanted_running`.
    entry.wanted_running.store(0, .seq_cst);
    entry.drain_until_ms = 0;
    if (entry.started) {
        if (entry.unit) |unit| _ = self.hal().outputUnitStop(self.binding.self, unit);
    }
    entry.started = false;
    while (entry.in_callback.load(.seq_cst) != 0) std.atomic.spinLoopHint();
}

fn startUnit(self: *CoreAudio, entry: *Entry) Stream.StartError!void {
    const unit = entry.unit orelse return error.Disconnected;
    entry.wanted_running.store(1, .seq_cst);
    if (self.hal().outputUnitStart(self.binding.self, unit) != ca.Status.ok) {
        entry.wanted_running.store(0, .seq_cst);
        return error.Disconnected;
    }
    entry.started = true;
}

fn destroyEntry(self: *CoreAudio, entry: *Entry) void {
    self.release(entry);
    self.mixer.removeStream(entry.app_id);
    const i = std.mem.indexOfScalar(*Entry, self.entries.items, entry).?;
    _ = self.entries.swapRemove(i);
    entry.stream.backend_data = null;
    entry.stream.pending_native = null;
    self.gpa.destroy(entry);
}

fn closeAll(self: *CoreAudio) void {
    while (self.entries.items.len > 0) self.destroyEntry(self.entries.items[self.entries.items.len - 1]);
}

fn directionKind(direction: Stream.Direction) Mixer.Kind {
    return switch (direction) {
        .playback => .sink,
        .capture => .source,
    };
}

fn openStreamImpl(ptr: *anyopaque, stream: *Stream) Stream.OpenError!Backend.Negotiated {
    const self = from(ptr);
    if (!self.connected) return error.Disconnected;
    const options = stream.options;
    const playback = options.direction == .playback;
    const explicit = try self.resolveDevice(options);
    const device = explicit orelse self.defaultDevice(options.direction);
    if (device == 0) return error.UnknownDevice;
    if (!playback and self.permissionSource().status().blocksCapture()) return error.PermissionDenied;
    try self.entries.ensureUnusedCapacity(self.gpa, 1);
    const entry = try self.gpa.create(Entry);
    errdefer self.gpa.destroy(entry);
    const channels = options.format.channels.count;
    entry.* = .{
        .backend = self,
        .stream = stream,
        .app_id = self.newId(),
        .playback = playback,
        .follows_default = explicit == null,
        .channels = channels,
        .frame_bytes = 4 * @as(usize, channels),
    };
    const opened = try self.openUnit(entry, device);
    try self.install(entry, opened);
    errdefer self.release(entry);
    try self.mixer.putStream(.{
        .id = entry.app_id,
        .direction = options.direction,
        .app_name = self.app_name,
        .name = self.app_name,
        .endpoint = options.device orelse self.mixer.default(directionKind(options.direction)),
        .volume = .{},
    });
    self.entries.appendAssumeCapacity(entry);
    stream.backend_data = entry;
    stream.pending_native = null;
    return opened.negotiated;
}

fn closeStreamImpl(ptr: *anyopaque, stream: *Stream) void {
    const self = from(ptr);
    const entry = entryOf(stream) orelse return;
    self.destroyEntry(entry);
}

/// Opens the unit again for a start. The default device may have changed since the last open.
fn reviveForStart(self: *CoreAudio, entry: *Entry) Stream.StartError!void {
    const device = if (entry.follows_default) self.defaultDevice(entry.stream.options.direction) else entry.device;
    if (device == 0) return error.Disconnected;
    self.reopen(entry, device) catch return error.Disconnected;
    entry.retrying = false;
}

fn startStreamImpl(ptr: *anyopaque, stream: *Stream) Stream.StartError!void {
    const self = from(ptr);
    const entry = entryOf(stream) orelse return error.Disconnected;
    if (entry.gone or !self.connected) return error.Disconnected;
    entry.restart = false;
    entry.drain_until_ms = 0;
    if (entry.unit == null) {
        try self.reviveForStart(entry);
        if (stream.pending_native != null) {
            self.wake.signal();
            return;
        }
    }
    if (entry.started) {
        entry.wanted_running.store(1, .seq_cst);
        return;
    }
    try self.startUnit(entry);
}

fn stopStreamImpl(ptr: *anyopaque, stream: *Stream) void {
    const self = from(ptr);
    const entry = entryOf(stream) orelse return;
    entry.restart = false;
    entry.retrying = false;
    self.halt(entry);
}

// Dispatch.

/// Stops the stream for good. The device of an explicit stream is gone.
fn markGone(self: *CoreAudio, entry: *Entry) void {
    entry.restart = false;
    entry.retrying = false;
    entry.gone = true;
    self.release(entry);
    _ = entry.stream.markDisconnected();
}

/// Replaces the unit of the entry. The new native format goes to `pending_native` when it differs,
/// and Context stops and starts the stream after it has swapped the pipeline.
fn reopen(self: *CoreAudio, entry: *Entry, device: ca.AudioObjectID) Stream.OpenError!void {
    entry.restart = entry.restart or entry.started;
    self.release(entry);
    entry.dirty.store(0, .release);
    const opened = try self.openUnit(entry, device);
    try self.install(entry, opened);
    const was_started = entry.restart;
    entry.restart = false;
    const stream = entry.stream;
    const next = opened.negotiated;
    if (!stream.negotiated.native.eql(next.native) or stream.negotiated.period_frames != next.period_frames) {
        stream.pending_native = next;
        return;
    }
    stream.pending_native = null;
    if (was_started) {
        self.startUnit(entry) catch {
            // A dead unit would make the stream look alive. The retry opens a new one.
            self.release(entry);
            entry.restart = true;
            return error.Disconnected;
        };
    }
}

fn retryOrGiveUp(self: *CoreAudio, entry: *Entry, now_ms: u64) void {
    if (!entry.retrying) {
        entry.retrying = true;
        entry.tries_left = self.options.reopen_tries;
    }
    if (entry.tries_left > 0) {
        entry.tries_left -= 1;
        entry.retry_at_ms = now_ms + @max(self.options.reopen_retry_ms, 1);
        return;
    }
    entry.retrying = false;
    entry.restart = false;
    _ = entry.stream.markDisconnected();
}

/// Points the Mixer stream at the endpoint of the device that the stream follows now.
fn followEndpoint(self: *CoreAudio, entry: *Entry, device: ca.AudioObjectID) void {
    const endpoint = map.endpointId(device, !entry.playback) orelse return;
    var value = (self.mixer.stream(entry.app_id) orelse return).*;
    if (value.endpoint == endpoint) return;
    value.endpoint = endpoint;
    // A stale endpoint stays until the next change of the stream.
    self.mixer.putStream(value) catch return;
}

fn reopenDefault(self: *CoreAudio, entry: *Entry, now_ms: u64) void {
    const target = self.defaultDevice(entry.stream.options.direction);
    if (target == 0) {
        entry.restart = entry.restart or entry.started;
        self.release(entry);
        self.retryOrGiveUp(entry, now_ms);
        return;
    }
    self.reopen(entry, target) catch {
        self.retryOrGiveUp(entry, now_ms);
        return;
    };
    entry.retrying = false;
    self.followEndpoint(entry, target);
}

fn serviceExplicit(self: *CoreAudio, entry: *Entry, sys: u32, flags: u32) error{OutOfMemory}!void {
    const unit = entry.unit orelse return;
    var lost = false;
    if (sys & sys_units != 0) {
        const current = self.props.unitValue(u32, unit, ca.UnitProperty.current_device, ca.UnitScope.global, 0) catch entry.device;
        lost = current != entry.device;
    }
    if (!lost and (flags & dirty_alive != 0 or sys & sys_devices != 0)) lost = !(try self.deviceUsable(entry.device));
    if (lost) return self.markGone(entry);
    if (flags & dirty_rate == 0) return;
    const nsrt = ca.Selector.nominal_sample_rate;
    const rate = self.props.objectValue(f64, entry.device, nsrt, ca.Scope.global) catch return self.markGone(entry);
    if (rateOf(rate) == entry.rate) return;
    self.reopen(entry, entry.device) catch self.markGone(entry);
}

fn serviceDefault(self: *CoreAudio, entry: *Entry, sys: u32, flags: u32, now_ms: u64) void {
    const direction = entry.stream.options.direction;
    const default_bit = if (entry.playback) sys_default_out else sys_default_in;
    const moved = sys & sys_units != 0;
    var need = entry.retrying and now_ms >= entry.retry_at_ms;
    // A due retry runs whether or not a unit exists.
    if (!need and entry.unit == null) {
        need = sys & default_bit != 0;
    } else if (!need) {
        if (sys & default_bit != 0 or moved) {
            need = self.defaultDevice(direction) != entry.device;
            if (!need and moved) {
                const unit = entry.unit.?;
                const current = self.props.unitValue(u32, unit, ca.UnitProperty.current_device, ca.UnitScope.global, 0) catch entry.device;
                need = current != entry.device;
            }
        }
        if (!need and flags & dirty_rate != 0) {
            const rate = self.props.objectValue(f64, entry.device, ca.Selector.nominal_sample_rate, ca.Scope.global) catch 0;
            need = rateOf(rate) != entry.rate;
        }
    }
    if (need) self.reopenDefault(entry, now_ms);
}

fn service(self: *CoreAudio, entry: *Entry, sys: u32, now_ms: u64) error{OutOfMemory}!void {
    const flags = entry.dirty.swap(0, .acq_rel);
    if (entry.gone) return;
    if (entry.follows_default) return self.serviceDefault(entry, sys, flags, now_ms);
    return self.serviceExplicit(entry, sys, flags);
}

/// The drain lasts a period, the latency to the sound and one more period, and at least `drain_periods`.
fn drainMs(entry: *const Entry) u64 {
    const period: u64 = entry.stream.negotiated.period_frames;
    const rate: u64 = @max(entry.rate, 1);
    const frames = @max(drain_periods * period, 2 * period + entry.latency_frames);
    return @max(1, (frames * 1000 + rate - 1) / rate);
}

/// Ends the drain of the streams whose queued audio has played, and stops the units whose user
/// callback ended the stream.
fn pollDrain(self: *CoreAudio, now_ms: u64) void {
    for (self.entries.items) |entry| {
        const stream = entry.stream;
        const seq = entry.drain_seq.load(.acquire);
        if (seq != entry.drain_seen) {
            entry.drain_seen = seq;
            entry.drain_until_ms = 0;
        }
        switch (stream.state()) {
            .draining => {
                if (!entry.started) continue;
                if (entry.drain_until_ms == 0) {
                    entry.drain_until_ms = now_ms + drainMs(entry);
                } else if (now_ms >= entry.drain_until_ms) {
                    self.halt(entry);
                    stream.drained();
                }
            },
            .running, .idle => {
                entry.drain_until_ms = 0;
            },
            .stopped => {
                entry.drain_until_ms = 0;
                if (entry.started) self.halt(entry);
            },
        }
    }
}

fn dispatchImpl(ptr: *anyopaque) Backend.DispatchError!Backend.Event {
    const self = from(ptr);
    self.wake.drain();
    if (!self.connected) return .none;
    const sys = self.sys_dirty.swap(0, .acq_rel);
    if (sys & sys_restarted != 0) {
        self.closeAll();
        self.clearMixer();
        self.removeSystemListeners(system_selectors.len);
        self.connected = false;
        return .disconnected;
    }
    const now = self.nowMs();
    var failed: ?error{OutOfMemory} = null;
    const default_bits = sys_default_out | sys_default_in;
    if (sys & sys_devices != 0) {
        self.rescan() catch |err| {
            self.scanAgain();
            failed = err;
        };
    } else {
        if (sys & sys_controls != 0) {
            self.refreshControls() catch |err| {
                self.refreshAgain();
                failed = err;
            };
        }
        if (sys & default_bits != 0) self.updateDefaults();
    }
    for (self.entries.items) |entry| {
        const overloads = entry.overloads.swap(0, .acq_rel);
        if (overloads != 0) entry.stream.noteXruns(overloads);
        self.service(entry, sys, now) catch |err| {
            failed = failed orelse err;
        };
    }
    self.pollDrain(now);
    if (failed) |err| return err;
    return .none;
}

fn reconnectImpl(ptr: *anyopaque) Backend.ConnectError!void {
    const self = from(ptr);
    if (self.connected) return;
    const probe = ca.Selector.default_output_device;
    _ = self.props.objectValue(u32, ca.object_system, probe, ca.Scope.global) catch return error.BackendUnavailable;
    try self.addSystemListeners();
    self.rescan() catch |err| {
        self.clearMixer();
        self.removeSystemListeners(system_selectors.len);
        return err;
    };
    self.connected = true;
}

fn deinitImpl(ptr: *anyopaque) void {
    const self = from(ptr);
    self.closeAll();
    self.unwatchAll();
    if (self.listening) self.removeSystemListeners(system_selectors.len);
    self.entries.deinit(self.gpa);
    self.rows.deinit(self.gpa);
    self.watches.deinit(self.gpa);
    while (self.unit_calls.load(.acquire) != 0) std.atomic.spinLoopHint();
    self.wake.close();
    self.gpa.destroy(self);
}

fn realtimeImpl(ptr: *anyopaque) Backend.Realtime {
    const value: u8 = @intCast(from(ptr).rt.load(.acquire));
    return @fromBackingInt(@intCast(value));
}

fn fdImpl(ptr: *anyopaque) ?i32 {
    return from(ptr).wake.read_fd;
}

fn timeoutMsImpl(ptr: *anyopaque) ?u32 {
    const self = from(ptr);
    if (!self.connected) return null;
    var best: ?u32 = null;
    const now = self.nowMs();
    for (self.entries.items) |entry| {
        var ms: ?u32 = null;
        if (entry.retrying) ms = @intCast(@min(entry.retry_at_ms -| now, std.math.maxInt(u32)));
        if (entry.started and entry.stream.state() == .draining) {
            const left: u32 = @intCast(@min(entry.drain_until_ms -| now, std.math.maxInt(u32)));
            const wait: u32 = if (entry.drain_until_ms == 0) drain_poll_ms else left;
            ms = if (ms) |m| @min(m, wait) else wait;
        }
        const value = ms orelse continue;
        best = if (best) |b| @min(b, value) else value;
    }
    return best;
}

fn capabilitiesImpl(ptr: *anyopaque) Mixer.Capabilities {
    _ = ptr;
    return .{ .set_default = true, .endpoint_volume = true, .ports = true };
}

/// Changes the default device of the whole system. Every app and coreaudiod keep the change,
/// also after this process ends.
fn setDefaultImpl(ptr: *anyopaque, k: Mixer.Kind, id: Mixer.Id) Mixer.Error!void {
    const self = from(ptr);
    const row = self.rowOf(id) orelse return error.UnknownObject;
    if (kindOfSide(row.is_source) != k) return error.UnknownObject;
    const selector = switch (k) {
        .sink => ca.Selector.default_output_device,
        .source => ca.Selector.default_input_device,
    };
    self.props.setObjectValue(u32, ca.object_system, selector, ca.Scope.global, row.device) catch |err| {
        return devices.mixerError(err);
    };
}

fn setVolumeImpl(ptr: *anyopaque, target: Mixer.Target, values: []const f32) Mixer.Error!void {
    const self = from(ptr);
    const id = switch (target) {
        .endpoint => |endpoint| endpoint,
        .stream => return error.Unsupported,
    };
    const row = self.rowOf(id) orelse return error.UnknownObject;
    try devices.setVolume(self.props, row.device, row.side, values);
}

fn setMuteImpl(ptr: *anyopaque, target: Mixer.Target, mute: bool) Mixer.Error!void {
    const self = from(ptr);
    const id = switch (target) {
        .endpoint => |endpoint| endpoint,
        .stream => return error.Unsupported,
    };
    const row = self.rowOf(id) orelse return error.UnknownObject;
    try devices.setMute(self.props, row.device, row.side, mute);
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
    const self = from(ptr);
    const row = self.rowOf(endpoint_id) orelse return error.UnknownObject;
    try devices.setPort(self.props, row.device, row.side, index);
}

test {
    _ = @import("coreaudio/backend_test.zig");
    _ = @import("coreaudio/devices_test.zig");
    _ = devices;
    _ = Wake;
    _ = @import("coreaudio/fake.zig");
}
