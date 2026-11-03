//! A fake CoreAudio for tests. It keeps devices, audio units and listeners, records the calls that
//! have an effect, and lets a test fire the listeners and run the render callbacks from any thread.
//! The functions of the table reach the state through the `self` pointer of the `Binding`.
const std = @import("std");
const api = @import("api.zig");
const Fake = @This();

/// True on a thread that runs a property listener. The HAL calls must not happen there.
threadlocal var in_listener: bool = false;
/// True on a thread that runs a render or input callback.
threadlocal var in_io: bool = false;

pub const Call = enum {
    component_new,
    set_device,
    set_format,
    set_callback,
    initialize,
    start,
    stop,
    uninitialize,
    dispose,
    add_unit_listener,
    remove_unit_listener,
    add_object_listener,
    remove_object_listener,
};

pub const Logged = struct { call: Call, unit: u32 };

pub const Device = struct {
    id: api.AudioObjectID,
    /// False when `dev#` does not list the device.
    listed: bool = true,
    alive: bool = true,
    rate: f64 = 48000,
    out_channels: u32 = 2,
    in_channels: u32 = 0,
    fsiz: u32 = 512,
    fsiz_min: u32 = 15,
    fsiz_max: u32 = 4096,
    latency: u32 = 0,
    safety: u32 = 0,
    stream_latency: u32 = 0,
    hidden: bool = false,
    /// Null makes the property missing.
    name: ?[]const u8 = "Fake Device",
    uid: ?[]const u8 = "fake-device",

    fn channelsOf(self: Device, scope: u32) u32 {
        return if (scope == api.Scope.output) self.out_channels else self.in_channels;
    }
};

/// A volume, mute or data source control of a device. The strings of a test live in static data.
pub const Control = struct {
    object: api.AudioObjectID,
    scope: u32,
    element: u32,
    /// The value of `vold`. Null means the control has no decibel value.
    db: ?f32 = null,
    db_min: f32 = -63.5,
    db_max: f32 = 0,
    /// The value of `vmvc`.
    scalar: ?f32 = null,
    mute: ?bool = null,
    settable: bool = true,
};

pub const Source = struct { id: u32, name: ?[]const u8 = null };

pub const SourceSet = struct {
    object: api.AudioObjectID,
    scope: u32,
    items: []const Source,
    current: u32,
    settable: bool = true,
};

pub const SetRecord = struct { object: api.AudioObjectID, selector: u32, scope: u32, element: u32, value: u32 };

const Str = struct { bytes: []const u8 };

/// The id of the one stream of a device is the device id plus this.
pub const stream_base: api.AudioObjectID = 1000;

const UnitListener = struct { unit: *Unit, id: api.AudioUnitPropertyID, proc: api.AudioUnitPropertyListenerProc, user: ?*anyopaque };
const ObjectListener = struct {
    object: api.AudioObjectID,
    selector: u32,
    scope: u32 = api.Scope.global,
    element: u32 = api.element_main,
    proc: api.AudioObjectPropertyListenerProc,
    client: ?*anyopaque,
};

pub const Unit = struct {
    fake: *Fake,
    id: u32,
    device: api.AudioObjectID,
    enable_in: u32 = 0,
    enable_out: u32 = 1,
    client_out: ?api.AudioStreamBasicDescription = null,
    client_in: ?api.AudioStreamBasicDescription = null,
    render: api.AURenderCallbackStruct = .{ .inputProc = null, .inputProcRefCon = null },
    input: api.AURenderCallbackStruct = .{ .inputProc = null, .inputProcRefCon = null },
    mfps: u32 = 512,
    initialized: bool = false,
    running: bool = false,
    /// The action flags that the last callback left.
    flags: api.AudioUnitRenderActionFlags = 0,

    /// Runs the render callback once with all of `buf` on the calling thread.
    pub fn callRender(self: *Unit, buf: []u8) api.OSStatus {
        const callback = self.render.inputProc.?;
        const format = self.client_out.?;
        const frames: u32 = @intCast(buf.len / format.mBytesPerFrame);
        var list: api.AudioBufferList = .{
            .mNumberBuffers = 1,
            .mBuffers = .{.{ .mNumberChannels = format.mChannelsPerFrame, .mDataByteSize = @intCast(buf.len), .mData = buf.ptr }},
        };
        return self.runIo(callback, self.render.inputProcRefCon, &self.flags, frames, &list);
    }

    /// Runs the input callback once with `frames` frames on the calling thread.
    pub fn callInput(self: *Unit, frames: u32) api.OSStatus {
        const callback = self.input.inputProc.?;
        return self.runIo(callback, self.input.inputProcRefCon, &self.flags, frames, null);
    }

    fn runIo(
        self: *Unit,
        callback: api.AURenderCallback,
        ref: ?*anyopaque,
        flags: *api.AudioUnitRenderActionFlags,
        frames: u32,
        list: ?*api.AudioBufferList,
    ) api.OSStatus {
        const stamp = std.mem.zeroes(api.AudioTimeStamp);
        flags.* = 0;
        const was = in_io;
        in_io = true;
        defer in_io = was;
        self.fake.callbacks_started.store(self.fake.callbacks_started.load(.monotonic) +% 1, .release);
        return callback(ref, flags, &stamp, if (list == null) 1 else 0, frames, list);
    }

    pub fn silent(self: *const Unit) bool {
        return self.flags & api.render_action_output_is_silence != 0;
    }
};

pub const Render = struct { frames: u32 = 0, bus: u32 = 0, bytes: u32 = 0, channels: u32 = 0, buffers: u32 = 0 };

gpa: std.mem.Allocator,
lock: std.atomic.Mutex = .unlocked,
devices: std.ArrayList(Device) = .empty,
units: std.ArrayList(*Unit) = .empty,
unit_listeners: std.ArrayList(UnitListener) = .empty,
object_listeners: std.ArrayList(ObjectListener) = .empty,
controls: std.ArrayList(Control) = .empty,
source_sets: std.ArrayList(SourceSet) = .empty,
sets: std.ArrayList(SetRecord) = .empty,
log: std.ArrayList(Logged) = .empty,
default_out: api.AudioObjectID = 0,
default_in: api.AudioObjectID = 0,
next_unit: u32 = 1,
/// Object listener calls that run. The removal of an object listener waits for them.
active_calls: std.atomic.Value(u32) = .init(0),
/// 1 holds the next unit listener call before it reaches the backend, as the HAL does when it does not wait for a removal.
unit_gate: std.atomic.Value(u32) = .init(0),
unit_gate_entered: std.atomic.Value(u32) = .init(0),
callbacks_started: std.atomic.Value(u32) = .init(0),

/// Settings that a test changes at any time.
no_component: bool = false,
fail_new: ?api.OSStatus = null,
fail_initialize: ?api.OSStatus = null,
/// How many initialize calls fail before they work.
fail_initialize_times: u32 = 0,
fail_start: ?api.OSStatus = null,
/// The maximum frames per slice that an initialized unit has, whatever the test or the backend sets.
mfps_override: ?u32 = null,
/// The device buffer size after every set of the buffer size.
fsiz_forced: ?u32 = null,
/// True gives the threads a time constraint policy.
realtime_policy: bool = true,
/// True makes `removeDevice` move the units of the device to the default, as the HAL does.
follow_on_removal: bool = true,
capture_value: f32 = 0.5,
/// A status that every set of an object property gives instead of working.
fail_set: ?api.OSStatus = null,
/// True makes the read of the current device of a unit fail.
fail_current_device: bool = false,
/// How many reads of the size of the device list fail before they work.
fail_devices_reads: u32 = 0,

/// Records.
last_render: Render = .{},
/// Strings that a read gave and nobody released.
strings_live: i32 = 0,
/// Calls of the HAL from a listener or from an IO callback, except the ones that are allowed there.
violations: std.atomic.Value(u32) = .init(0),
/// Misuse of a unit, such as a dispose while a listener is still registered.
bad_uses: u32 = 0,
run_loop_sets: u32 = 0,
thread_policy_calls: u32 = 0,

pub fn init(gpa: std.mem.Allocator) Fake {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Fake) void {
    for (self.units.items) |made| self.gpa.destroy(made);
    self.units.deinit(self.gpa);
    self.devices.deinit(self.gpa);
    self.unit_listeners.deinit(self.gpa);
    self.object_listeners.deinit(self.gpa);
    self.controls.deinit(self.gpa);
    self.source_sets.deinit(self.gpa);
    self.sets.deinit(self.gpa);
    self.log.deinit(self.gpa);
}

pub fn binding(self: *Fake) api.Binding {
    return .{ .self = self, .table = &table };
}

fn lockState(self: *Fake) void {
    while (!self.lock.tryLock()) std.atomic.spinLoopHint();
}

fn unlockState(self: *Fake) void {
    self.lock.unlock();
}

fn record(self: *Fake, call: Call, which: u32) void {
    self.log.append(self.gpa, .{ .call = call, .unit = which }) catch @panic("the fake ran out of memory");
}

fn check(self: *Fake) void {
    if (in_listener or in_io) _ = self.violations.fetchAdd(1, .monotonic);
}

/// Adds a device. The first device with output channels becomes the default output, and the first
/// with input channels the default input.
pub fn addDevice(self: *Fake, added: Device) void {
    self.lockState();
    defer self.unlockState();
    self.devices.append(self.gpa, added) catch @panic("the fake ran out of memory");
    if (self.default_out == 0 and added.out_channels > 0) self.default_out = added.id;
    if (self.default_in == 0 and added.in_channels > 0) self.default_in = added.id;
}

pub fn addControl(self: *Fake, added: Control) void {
    self.lockState();
    defer self.unlockState();
    self.controls.append(self.gpa, added) catch @panic("the fake ran out of memory");
}

pub fn addSources(self: *Fake, added: SourceSet) void {
    self.lockState();
    defer self.unlockState();
    self.source_sets.append(self.gpa, added) catch @panic("the fake ran out of memory");
}

fn controlOf(self: *Fake, object: api.AudioObjectID, scope: u32, element: u32) ?*Control {
    for (self.controls.items) |*c| {
        if (c.object == object and c.scope == scope and c.element == element) return c;
    }
    return null;
}

pub fn controlAt(self: *Fake, object: api.AudioObjectID, scope: u32, element: u32) *Control {
    return self.controlOf(object, scope, element).?;
}

fn sourcesOf(self: *Fake, object: api.AudioObjectID, scope: u32) ?*SourceSet {
    for (self.source_sets.items) |*s| {
        if (s.object == object and s.scope == scope) return s;
    }
    return null;
}

/// Another program changes the decibel value of a control. The listeners of the volume get a call.
pub fn changeDb(self: *Fake, object: api.AudioObjectID, scope: u32, element: u32, db: f32) void {
    self.controlOf(object, scope, element).?.db = db;
    self.fireVolume(object, scope, element);
}

pub fn changeScalar(self: *Fake, object: api.AudioObjectID, scope: u32, element: u32, value: f32) void {
    self.controlOf(object, scope, element).?.scalar = value;
    self.fireVolume(object, scope, element);
}

pub fn changeMute(self: *Fake, object: api.AudioObjectID, scope: u32, element: u32, mute: bool) void {
    self.controlOf(object, scope, element).?.mute = mute;
    self.fireAt(object, api.Selector.mute, scope, element);
}

pub fn changeSource(self: *Fake, object: api.AudioObjectID, scope: u32, id: u32) void {
    self.sourcesOf(object, scope).?.current = id;
    self.fireAt(object, api.Selector.data_source, scope, api.element_main);
}

fn fireVolume(self: *Fake, object: api.AudioObjectID, scope: u32, element: u32) void {
    self.fireAt(object, api.Selector.volume_decibels, scope, element);
    self.fireAt(object, api.Selector.volume_scalar, scope, element);
    self.fireAt(object, api.Selector.virtual_main_volume, scope, element);
}

fn newString(self: *Fake, bytes: []const u8) ?api.CFStringRef {
    const made = self.gpa.create(Str) catch return null;
    made.* = .{ .bytes = bytes };
    self.strings_live += 1;
    return @ptrCast(made);
}

fn find(self: *Fake, id: api.AudioObjectID) ?*Device {
    for (self.devices.items) |*d| {
        if (d.id == id) return d;
    }
    return null;
}

pub fn device(self: *Fake, id: api.AudioObjectID) *Device {
    return self.find(id).?;
}

pub fn unitCount(self: *Fake) usize {
    return self.units.items.len;
}

pub fn unit(self: *Fake, index: usize) *Unit {
    return self.units.items[index];
}

pub fn count(self: *const Fake, call: Call) u32 {
    var n: u32 = 0;
    for (self.log.items) |entry| {
        if (entry.call == call) n += 1;
    }
    return n;
}

/// The position in the log of the `nth` entry (from 0) of a call, or null.
pub fn position(self: *const Fake, call: Call, nth: u32) ?usize {
    var seen: u32 = 0;
    for (self.log.items, 0..) |entry, i| {
        if (entry.call != call) continue;
        if (seen == nth) return i;
        seen += 1;
    }
    return null;
}

pub fn listenerCount(self: *const Fake) usize {
    return self.object_listeners.items.len + self.unit_listeners.items.len;
}

pub fn objectListenerCount(self: *const Fake) usize {
    return self.object_listeners.items.len;
}

pub fn unitListenerCount(self: *const Fake) usize {
    return self.unit_listeners.items.len;
}

// Events that a test makes happen.

fn fireObject(self: *Fake, object: api.AudioObjectID, selector: u32) void {
    self.fireAt(object, selector, api.Scope.global, api.element_main);
}

fn fireAt(self: *Fake, object: api.AudioObjectID, selector: u32, scope: u32, element: u32) void {
    var targets: [16]ObjectListener = undefined;
    var n: usize = 0;
    self.lockState();
    for (self.object_listeners.items) |l| {
        if (l.object != object or l.selector != selector or l.scope != scope or l.element != element) continue;
        if (n == targets.len) continue;
        targets[n] = l;
        n += 1;
    }
    _ = self.active_calls.fetchAdd(1, .acq_rel);
    self.unlockState();
    defer _ = self.active_calls.fetchSub(1, .acq_rel);
    const was = in_listener;
    in_listener = true;
    defer in_listener = was;
    const addr = api.address(selector, scope, element);
    for (targets[0..n]) |t| _ = t.proc(object, 1, @ptrCast(&addr), t.client);
}

fn fireUnit(self: *Fake, target: *Unit, id: api.AudioUnitPropertyID) void {
    var targets: [8]UnitListener = undefined;
    var n: usize = 0;
    self.lockState();
    for (self.unit_listeners.items) |l| {
        if (l.unit != target or l.id != id or n == targets.len) continue;
        targets[n] = l;
        n += 1;
    }
    self.unlockState();
    // Only the first call after the test sets the gate waits.
    if (n != 0 and self.unit_gate.cmpxchgStrong(1, 2, .acq_rel, .acquire) == null) {
        _ = self.unit_gate_entered.fetchAdd(1, .acq_rel);
        while (self.unit_gate.load(.acquire) == 2) std.atomic.spinLoopHint();
    }
    const was = in_listener;
    in_listener = true;
    defer in_listener = was;
    for (targets[0..n]) |t| t.proc(t.user, @ptrCast(target), id, api.UnitScope.global, 0);
}

pub fn setDefaultOut(self: *Fake, id: api.AudioObjectID) void {
    self.default_out = id;
    self.fireObject(api.object_system, api.Selector.default_output_device);
}

pub fn setDefaultIn(self: *Fake, id: api.AudioObjectID) void {
    self.default_in = id;
    self.fireObject(api.object_system, api.Selector.default_input_device);
}

pub fn setAlive(self: *Fake, id: api.AudioObjectID, alive: bool) void {
    self.device(id).alive = alive;
    self.fireObject(id, api.Selector.is_alive);
}

/// Fires the overload listeners of the device.
pub fn setOverload(self: *Fake, id: api.AudioObjectID) void {
    self.fireObject(id, api.Selector.processor_overload);
}

pub fn setRate(self: *Fake, id: api.AudioObjectID, rate: f64) void {
    self.device(id).rate = rate;
    self.fireObject(id, api.Selector.nominal_sample_rate);
}

/// Changes what `dev#` lists and fires its listeners.
pub fn setListed(self: *Fake, id: api.AudioObjectID, listed: bool) void {
    self.device(id).listed = listed;
    self.fireObject(api.object_system, api.Selector.devices);
}

pub fn restartService(self: *Fake) void {
    self.fireObject(api.object_system, api.Selector.service_restarted);
}

/// Moves a unit to another device and fires the events of the HAL: IsRunning off and on, then
/// CurrentDevice.
pub fn moveUnit(self: *Fake, moved: *Unit, to: api.AudioObjectID) void {
    moved.device = to;
    self.fireUnit(moved, api.UnitProperty.is_running);
    self.fireUnit(moved, api.UnitProperty.current_device);
}

/// Removes a device. With `follow_on_removal` the units on it move to the default first, and the
/// events come in the order that the Mac showed: unit events, `dev#`, then the default.
pub fn removeDevice(self: *Fake, id: api.AudioObjectID) void {
    var new_out = self.default_out;
    var new_in = self.default_in;
    if (new_out == id) new_out = self.firstWith(id, true);
    if (new_in == id) new_in = self.firstWith(id, false);
    if (self.follow_on_removal) {
        for (self.units.items) |u| {
            if (u.device != id) continue;
            self.moveUnit(u, if (u.enable_in == 1 and u.enable_out == 0) new_in else new_out);
        }
    }
    self.lockState();
    for (self.devices.items, 0..) |d, i| {
        if (d.id == id) {
            _ = self.devices.orderedRemove(i);
            break;
        }
    }
    self.unlockState();
    self.fireObject(api.object_system, api.Selector.devices);
    if (new_out != self.default_out) self.setDefaultOut(new_out);
    if (new_in != self.default_in) self.setDefaultIn(new_in);
}

fn firstWith(self: *Fake, except: api.AudioObjectID, output: bool) api.AudioObjectID {
    for (self.devices.items) |d| {
        if (d.id == except) continue;
        if ((if (output) d.out_channels else d.in_channels) > 0) return d.id;
    }
    return 0;
}

// The table.

const table: api.Api = .{
    .componentFindNext = componentFindNext,
    .componentInstanceNew = componentInstanceNew,
    .componentInstanceDispose = componentInstanceDispose,
    .unitInitialize = unitInitialize,
    .unitUninitialize = unitUninitialize,
    .unitGetPropertyInfo = unitGetPropertyInfo,
    .unitGetProperty = unitGetProperty,
    .unitSetProperty = unitSetProperty,
    .unitAddPropertyListener = unitAddPropertyListener,
    .unitRemovePropertyListener = unitRemovePropertyListener,
    .unitRender = unitRender,
    .outputUnitStart = outputUnitStart,
    .outputUnitStop = outputUnitStop,
    .objectHasProperty = objectHasProperty,
    .objectIsPropertySettable = objectIsPropertySettable,
    .objectGetPropertyDataSize = objectGetPropertyDataSize,
    .objectGetPropertyData = objectGetPropertyData,
    .objectSetPropertyData = objectSetPropertyData,
    .objectAddPropertyListener = objectAddPropertyListener,
    .objectRemovePropertyListener = objectRemovePropertyListener,
    .cfRelease = cfRelease,
    .cfStringGetLength = cfStringGetLength,
    .cfStringGetMaximumSizeForEncoding = cfStringGetMaximumSizeForEncoding,
    .cfStringGetBytes = cfStringGetBytes,
    .dlopen = dlopen,
    .dlsym = dlsym,
    .threadPolicyGet = threadPolicyGet,
};

fn from(ptr: *anyopaque) *Fake {
    return @ptrCast(@alignCast(ptr));
}

fn unitOf(handle: api.AudioUnit) *Unit {
    return @ptrCast(@alignCast(handle));
}

fn put(comptime T: type, data: *anyopaque, size: *u32, value: T) api.OSStatus {
    if (size.* < @sizeOf(T)) return api.Status.bad_property_size;
    const out: *T = @ptrCast(@alignCast(data));
    out.* = value;
    size.* = @sizeOf(T);
    return api.Status.ok;
}

fn take(comptime T: type, data: ?*const anyopaque, size: u32) ?T {
    if (size != @sizeOf(T)) return null;
    const in: *const T = @ptrCast(@alignCast(data orelse return null));
    return in.*;
}

fn componentFindNext(ptr: *anyopaque, desc: *const api.AudioComponentDescription) ?api.AudioComponent {
    const self = from(ptr);
    if (self.no_component) return null;
    if (desc.componentType != api.unit_type_output or desc.componentSubType != api.unit_subtype_hal_output) return null;
    if (desc.componentManufacturer != api.unit_manufacturer_apple) return null;
    return @ptrFromInt(0x10);
}

fn componentInstanceNew(ptr: *anyopaque, component: api.AudioComponent, out: *?api.AudioUnit) api.OSStatus {
    _ = component;
    const self = from(ptr);
    self.check();
    if (self.fail_new) |status| return status;
    self.lockState();
    defer self.unlockState();
    const made = self.gpa.create(Unit) catch return api.Status.mem_full;
    made.* = .{ .fake = self, .id = self.next_unit, .device = self.default_out };
    self.next_unit += 1;
    self.units.append(self.gpa, made) catch {
        self.gpa.destroy(made);
        return api.Status.mem_full;
    };
    self.record(.component_new, made.id);
    out.* = @ptrCast(made);
    return api.Status.ok;
}

fn componentInstanceDispose(ptr: *anyopaque, handle: api.AudioUnit) api.OSStatus {
    const self = from(ptr);
    self.check();
    const gone = unitOf(handle);
    self.lockState();
    defer self.unlockState();
    for (self.unit_listeners.items) |l| {
        if (l.unit == gone) {
            self.bad_uses += 1;
            break;
        }
    }
    if (gone.running or gone.initialized) self.bad_uses += 1;
    self.record(.dispose, gone.id);
    for (self.units.items, 0..) |u, i| {
        if (u != gone) continue;
        _ = self.units.orderedRemove(i);
        self.gpa.destroy(gone);
        return api.Status.ok;
    }
    self.bad_uses += 1;
    return api.Status.bad_object;
}

fn unitInitialize(ptr: *anyopaque, handle: api.AudioUnit) api.OSStatus {
    const self = from(ptr);
    self.check();
    const u = unitOf(handle);
    if (self.fail_initialize_times > 0) {
        self.fail_initialize_times -= 1;
        return self.fail_initialize orelse api.Status.unit_failed_initialization;
    }
    if (self.find(u.device) == null) return api.Status.unit_failed_initialization;
    u.initialized = true;
    u.mfps = self.mfps_override orelse self.find(u.device).?.fsiz;
    self.lockState();
    self.record(.initialize, u.id);
    self.unlockState();
    return api.Status.ok;
}

fn unitUninitialize(ptr: *anyopaque, handle: api.AudioUnit) api.OSStatus {
    const self = from(ptr);
    self.check();
    const u = unitOf(handle);
    if (u.running) self.bad_uses += 1;
    u.initialized = false;
    self.lockState();
    self.record(.uninitialize, u.id);
    self.unlockState();
    return api.Status.ok;
}

fn unitGetPropertyInfo(
    ptr: *anyopaque,
    handle: api.AudioUnit,
    id: api.AudioUnitPropertyID,
    scope: api.AudioUnitScope,
    element: api.AudioUnitElement,
    size: ?*u32,
    writable: ?*api.Boolean,
) api.OSStatus {
    _ = handle;
    _ = scope;
    _ = element;
    from(ptr).check();
    if (size) |s| s.* = if (id == api.UnitProperty.stream_format) @sizeOf(api.AudioStreamBasicDescription) else 4;
    if (writable) |w| w.* = 1;
    return api.Status.ok;
}

fn defaultClient() api.AudioStreamBasicDescription {
    return .{
        .mSampleRate = 44100,
        .mFormatID = api.format_linear_pcm,
        .mFormatFlags = 0x29,
        .mBytesPerPacket = 4,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 4,
        .mChannelsPerFrame = 2,
        .mBitsPerChannel = 32,
    };
}

fn deviceSide(d: *const Device, channels: u32) api.AudioStreamBasicDescription {
    return .{
        .mSampleRate = if (channels == 0) 0 else d.rate,
        .mFormatID = api.format_linear_pcm,
        .mFormatFlags = if (channels == 0) 0x29 else 0x9,
        .mBytesPerPacket = 4 * channels,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 4 * channels,
        .mChannelsPerFrame = channels,
        .mBitsPerChannel = 32,
    };
}

fn unitGetProperty(
    ptr: *anyopaque,
    handle: api.AudioUnit,
    id: api.AudioUnitPropertyID,
    scope: api.AudioUnitScope,
    element: api.AudioUnitElement,
    data: *anyopaque,
    size: *u32,
) api.OSStatus {
    const self = from(ptr);
    self.check();
    const u = unitOf(handle);
    const P = api.UnitProperty;
    const S = api.UnitScope;
    if (id == P.current_device) {
        if (self.fail_current_device) return api.Status.bad_device;
        return put(u32, data, size, u.device);
    }
    if (id == P.is_running) return put(u32, data, size, @intFromBool(u.running));
    if (id == P.maximum_frames_per_slice) return put(u32, data, size, u.mfps);
    if (id == P.last_render_error) return put(u32, data, size, 0);
    if (id == api.Selector.buffer_frame_size) {
        const d = self.find(u.device) orelse return api.Status.bad_device;
        return put(u32, data, size, d.fsiz);
    }
    if (id == P.enable_io) {
        if (scope == S.input and element == 1) return put(u32, data, size, u.enable_in);
        if (scope == S.output and element == 0) return put(u32, data, size, u.enable_out);
        return api.Status.unit_invalid_element;
    }
    if (id == P.stream_format) {
        const d = self.find(u.device) orelse return api.Status.bad_device;
        if (scope == S.output and element == 0) return put(api.AudioStreamBasicDescription, data, size, deviceSide(d, d.out_channels));
        if (scope == S.input and element == 1) return put(api.AudioStreamBasicDescription, data, size, deviceSide(d, d.in_channels));
        if (scope == S.input and element == 0) return put(api.AudioStreamBasicDescription, data, size, u.client_out orelse defaultClient());
        if (scope == S.output and element == 1) return put(api.AudioStreamBasicDescription, data, size, u.client_in orelse defaultClient());
        return api.Status.unit_invalid_scope;
    }
    return api.Status.unit_invalid_property;
}

fn unitSetProperty(
    ptr: *anyopaque,
    handle: api.AudioUnit,
    id: api.AudioUnitPropertyID,
    scope: api.AudioUnitScope,
    element: api.AudioUnitElement,
    data: ?*const anyopaque,
    size: u32,
) api.OSStatus {
    const self = from(ptr);
    self.check();
    const u = unitOf(handle);
    const P = api.UnitProperty;
    const S = api.UnitScope;
    self.lockState();
    defer self.unlockState();
    if (id == P.current_device) {
        const wanted = take(u32, data, size) orelse return api.Status.bad_property_size;
        if (self.find(wanted) == null) return api.Status.bad_device;
        u.device = wanted;
        self.record(.set_device, u.id);
        return api.Status.ok;
    }
    if (id == P.enable_io) {
        const value = take(u32, data, size) orelse return api.Status.bad_property_size;
        if (scope == S.input and element == 1) {
            u.enable_in = value;
        } else if (scope == S.output and element == 0) {
            u.enable_out = value;
        } else {
            return api.Status.unit_invalid_element;
        }
        return api.Status.ok;
    }
    if (id == P.stream_format) {
        const value = take(api.AudioStreamBasicDescription, data, size) orelse return api.Status.bad_property_size;
        if (scope == S.input and element == 0) {
            u.client_out = value;
        } else if (scope == S.output and element == 1) {
            u.client_in = value;
        } else {
            return api.Status.unit_property_not_writable;
        }
        self.record(.set_format, u.id);
        return api.Status.ok;
    }
    if (id == P.set_render_callback) {
        u.render = take(api.AURenderCallbackStruct, data, size) orelse return api.Status.bad_property_size;
        self.record(.set_callback, u.id);
        return api.Status.ok;
    }
    if (id == P.set_input_callback) {
        u.input = take(api.AURenderCallbackStruct, data, size) orelse return api.Status.bad_property_size;
        self.record(.set_callback, u.id);
        return api.Status.ok;
    }
    if (id == P.maximum_frames_per_slice) {
        const value = take(u32, data, size) orelse return api.Status.bad_property_size;
        if (self.mfps_override == null) u.mfps = value;
        return api.Status.ok;
    }
    if (id == api.Selector.buffer_frame_size) {
        const value = take(u32, data, size) orelse return api.Status.bad_property_size;
        const d = self.find(u.device) orelse return api.Status.bad_device;
        if (value < d.fsiz_min or value > d.fsiz_max) return api.Status.unit_invalid_property_value;
        d.fsiz = self.fsiz_forced orelse value;
        return api.Status.ok;
    }
    return api.Status.unit_invalid_property;
}

fn unitAddPropertyListener(
    ptr: *anyopaque,
    handle: api.AudioUnit,
    id: api.AudioUnitPropertyID,
    proc: api.AudioUnitPropertyListenerProc,
    user: ?*anyopaque,
) api.OSStatus {
    const self = from(ptr);
    self.check();
    self.lockState();
    defer self.unlockState();
    const added: UnitListener = .{ .unit = unitOf(handle), .id = id, .proc = proc, .user = user };
    self.unit_listeners.append(self.gpa, added) catch return api.Status.mem_full;
    self.record(.add_unit_listener, unitOf(handle).id);
    return api.Status.ok;
}

fn unitRemovePropertyListener(
    ptr: *anyopaque,
    handle: api.AudioUnit,
    id: api.AudioUnitPropertyID,
    proc: api.AudioUnitPropertyListenerProc,
    user: ?*anyopaque,
) api.OSStatus {
    const self = from(ptr);
    self.check();
    self.lockState();
    var found = false;
    for (self.unit_listeners.items, 0..) |l, i| {
        if (l.unit == unitOf(handle) and l.id == id and l.proc == proc and l.user == user) {
            _ = self.unit_listeners.orderedRemove(i);
            found = true;
            break;
        }
    }
    if (found) self.record(.remove_unit_listener, unitOf(handle).id) else self.bad_uses += 1;
    self.unlockState();
    // The HAL does not wait for a unit listener call that runs.
    return if (found) api.Status.ok else api.Status.unit_invalid_property;
}

fn unitRender(
    ptr: *anyopaque,
    handle: api.AudioUnit,
    flags: ?*api.AudioUnitRenderActionFlags,
    time_stamp: *const api.AudioTimeStamp,
    bus: u32,
    frames: u32,
    data: *api.AudioBufferList,
) api.OSStatus {
    _ = handle;
    _ = flags;
    _ = time_stamp;
    const self = from(ptr);
    if (data.mNumberBuffers != 1) return api.Status.param;
    const buffer = &data.mBuffers[0];
    self.last_render = .{
        .frames = frames,
        .bus = bus,
        .bytes = buffer.mDataByteSize,
        .channels = buffer.mNumberChannels,
        .buffers = data.mNumberBuffers,
    };
    const samples: [*]f32 = @ptrCast(@alignCast(buffer.mData orelse return api.Status.param));
    @memset(samples[0 .. buffer.mDataByteSize / 4], self.capture_value);
    return api.Status.ok;
}

fn outputUnitStart(ptr: *anyopaque, handle: api.AudioUnit) api.OSStatus {
    const self = from(ptr);
    self.check();
    const u = unitOf(handle);
    if (self.fail_start) |status| return status;
    if (!u.initialized) return api.Status.unit_uninitialized;
    u.running = true;
    self.lockState();
    self.record(.start, u.id);
    self.unlockState();
    // The HAL runs the IsRunning listeners on the thread that starts the unit.
    self.fireUnit(u, api.UnitProperty.is_running);
    return api.Status.ok;
}

fn outputUnitStop(ptr: *anyopaque, handle: api.AudioUnit) api.OSStatus {
    const self = from(ptr);
    self.check();
    const u = unitOf(handle);
    u.running = false;
    self.lockState();
    self.record(.stop, u.id);
    self.unlockState();
    self.fireUnit(u, api.UnitProperty.is_running);
    return api.Status.ok;
}

fn known(self: *Fake, object: api.AudioObjectID, addr: *const api.AudioObjectPropertyAddress) bool {
    const A = api.Selector;
    const selector = addr.mSelector;
    if (object == api.object_system) {
        return selector == A.default_output_device or selector == A.default_input_device or selector == A.devices or
            selector == A.run_loop or selector == A.service_restarted;
    }
    if (self.streamDevice(object) != null) return selector == A.latency;
    const d = self.find(object) orelse return false;
    switch (selector) {
        A.nominal_sample_rate, A.is_alive, A.buffer_frame_size, A.buffer_frame_size_range => return true,
        A.latency, A.safety_offset, A.streams, A.is_hidden => return true,
        A.device_uid => return d.uid != null,
        A.name => return d.name != null,
        A.stream_configuration => return addr.mScope == api.Scope.output or addr.mScope == api.Scope.input,
        A.volume_decibels, A.volume_range_decibels, A.volume_scalar => {
            const c = self.controlOf(object, addr.mScope, addr.mElement) orelse return false;
            return c.db != null;
        },
        A.virtual_main_volume => {
            const c = self.controlOf(object, addr.mScope, addr.mElement) orelse return false;
            return c.scalar != null;
        },
        A.mute => {
            const c = self.controlOf(object, addr.mScope, addr.mElement) orelse return false;
            return c.mute != null;
        },
        A.data_sources, A.data_source, A.data_source_name => {
            return addr.mElement == 0 and self.sourcesOf(object, addr.mScope) != null;
        },
        else => return false,
    }
}

fn streamDevice(self: *Fake, object: api.AudioObjectID) ?*Device {
    if (object < stream_base) return null;
    return self.find(object - stream_base);
}

fn objectHasProperty(ptr: *anyopaque, object: api.AudioObjectID, addr: *const api.AudioObjectPropertyAddress) bool {
    const self = from(ptr);
    self.check();
    return self.known(object, addr);
}

fn objectIsPropertySettable(
    ptr: *anyopaque,
    object: api.AudioObjectID,
    addr: *const api.AudioObjectPropertyAddress,
    settable: *api.Boolean,
) api.OSStatus {
    const self = from(ptr);
    self.check();
    if (!self.known(object, addr)) return api.Status.unknown_property;
    const A = api.Selector;
    const yes = switch (addr.mSelector) {
        A.run_loop, A.default_output_device, A.default_input_device => true,
        A.volume_decibels, A.virtual_main_volume, A.mute => self.controlOf(object, addr.mScope, addr.mElement).?.settable,
        A.data_source => self.sourcesOf(object, addr.mScope).?.settable,
        else => false,
    };
    settable.* = @intFromBool(yes);
    return api.Status.ok;
}

const layout_head = @offsetOf(api.AudioBufferList, "mBuffers");

fn layoutSize(channels: u32) u32 {
    const buffers: u32 = if (channels > 0) @sizeOf(api.AudioBuffer) else 0;
    return layout_head + buffers;
}

fn objectGetPropertyDataSize(
    ptr: *anyopaque,
    object: api.AudioObjectID,
    addr: *const api.AudioObjectPropertyAddress,
    qualifier_size: u32,
    qualifier: ?*const anyopaque,
    size: *u32,
) api.OSStatus {
    _ = qualifier_size;
    _ = qualifier;
    const self = from(ptr);
    self.check();
    if (object != api.object_system and self.find(object) == null and self.streamDevice(object) == null) return api.Status.bad_object;
    if (!self.known(object, addr)) return api.Status.unknown_property;
    if (object == api.object_system and addr.mSelector == api.Selector.devices and self.fail_devices_reads > 0) {
        self.fail_devices_reads -= 1;
        return api.Status.bad_device;
    }
    self.lockState();
    defer self.unlockState();
    const A = api.Selector;
    size.* = switch (addr.mSelector) {
        A.devices => blk: {
            var n: u32 = 0;
            for (self.devices.items) |d| n += @intFromBool(d.listed);
            break :blk 4 * n;
        },
        A.nominal_sample_rate => 8,
        A.buffer_frame_size_range, A.volume_range_decibels => @sizeOf(api.AudioValueRange),
        A.run_loop, A.device_uid, A.name => @sizeOf(?*anyopaque),
        A.stream_configuration => layoutSize(self.find(object).?.channelsOf(addr.mScope)),
        A.data_sources => @intCast(4 * self.sourcesOf(object, addr.mScope).?.items.len),
        A.data_source_name => @sizeOf(api.AudioValueTranslation),
        else => 4,
    };
    return api.Status.ok;
}

fn putString(self: *Fake, data: *anyopaque, size: *u32, bytes: []const u8) api.OSStatus {
    if (size.* < @sizeOf(?api.CFStringRef)) return api.Status.bad_property_size;
    const out: *?api.CFStringRef = @ptrCast(@alignCast(data));
    out.* = self.newString(bytes) orelse return api.Status.mem_full;
    size.* = @sizeOf(?api.CFStringRef);
    return api.Status.ok;
}

fn putLayout(data: *anyopaque, size: *u32, channels: u32) api.OSStatus {
    const need = layoutSize(channels);
    if (size.* < need) return api.Status.bad_property_size;
    const bytes: [*]u8 = @ptrCast(data);
    @memset(bytes[0..need], 0);
    const endian = @import("builtin").cpu.arch.endian();
    std.mem.writeInt(u32, bytes[0..4], if (channels > 0) 1 else 0, endian);
    if (channels > 0) std.mem.writeInt(u32, bytes[layout_head..][0..4], channels, endian);
    size.* = need;
    return api.Status.ok;
}

fn putIds(data: *anyopaque, size: *u32, items: []const Source) api.OSStatus {
    if (size.* < 4 * items.len) return api.Status.bad_property_size;
    const out: [*]u32 = @ptrCast(@alignCast(data));
    for (items, 0..) |item, i| out[i] = item.id;
    size.* = @intCast(4 * items.len);
    return api.Status.ok;
}

fn putSourceName(self: *Fake, set: *const SourceSet, data: *anyopaque, size: *u32) api.OSStatus {
    if (size.* < @sizeOf(api.AudioValueTranslation)) return api.Status.bad_property_size;
    const translation: *api.AudioValueTranslation = @ptrCast(@alignCast(data));
    if (translation.mInputDataSize != 4 or translation.mOutputDataSize != @sizeOf(?api.CFStringRef)) return api.Status.bad_property_size;
    const item: *const u32 = @ptrCast(@alignCast(translation.mInputData));
    const out: *?api.CFStringRef = @ptrCast(@alignCast(translation.mOutputData));
    for (set.items) |source| {
        if (source.id != item.*) continue;
        const name = source.name orelse return api.Status.illegal_operation;
        out.* = self.newString(name) orelse return api.Status.mem_full;
        return api.Status.ok;
    }
    return api.Status.illegal_operation;
}

fn objectGetPropertyData(
    ptr: *anyopaque,
    object: api.AudioObjectID,
    addr: *const api.AudioObjectPropertyAddress,
    qualifier_size: u32,
    qualifier: ?*const anyopaque,
    size: *u32,
    data: *anyopaque,
) api.OSStatus {
    _ = qualifier_size;
    _ = qualifier;
    const self = from(ptr);
    self.check();
    if (object != api.object_system and self.find(object) == null and self.streamDevice(object) == null) return api.Status.bad_object;
    if (!self.known(object, addr)) return api.Status.unknown_property;
    const A = api.Selector;
    if (self.streamDevice(object)) |owner| return put(u32, data, size, owner.stream_latency);
    if (object == api.object_system) {
        switch (addr.mSelector) {
            A.default_output_device => return put(u32, data, size, self.default_out),
            A.default_input_device => return put(u32, data, size, self.default_in),
            A.run_loop => return put(?*anyopaque, data, size, null),
            A.devices => {
                self.lockState();
                defer self.unlockState();
                const out: [*]u32 = @ptrCast(@alignCast(data));
                var n: u32 = 0;
                for (self.devices.items) |d| {
                    if (!d.listed or (n + 1) * 4 > size.*) continue;
                    out[n] = d.id;
                    n += 1;
                }
                size.* = 4 * n;
                return api.Status.ok;
            },
            else => return api.Status.unknown_property,
        }
    }
    const d = self.find(object).?;
    const scope = addr.mScope;
    const element = addr.mElement;
    return switch (addr.mSelector) {
        A.nominal_sample_rate => put(f64, data, size, d.rate),
        A.is_alive => put(u32, data, size, @intFromBool(d.alive)),
        A.latency => put(u32, data, size, d.latency),
        A.safety_offset => put(u32, data, size, d.safety),
        A.streams => put(u32, data, size, stream_base + d.id),
        A.buffer_frame_size => put(u32, data, size, d.fsiz),
        A.buffer_frame_size_range => put(api.AudioValueRange, data, size, .{
            .mMinimum = @floatFromInt(d.fsiz_min),
            .mMaximum = @floatFromInt(d.fsiz_max),
        }),
        A.is_hidden => put(u32, data, size, @intFromBool(d.hidden)),
        A.device_uid => self.putString(data, size, d.uid.?),
        A.name => self.putString(data, size, d.name.?),
        A.stream_configuration => putLayout(data, size, d.channelsOf(scope)),
        A.volume_decibels => put(f32, data, size, self.controlOf(object, scope, element).?.db.?),
        A.volume_scalar => blk: {
            const c = self.controlOf(object, scope, element).?;
            break :blk put(f32, data, size, (c.db.? - c.db_min) / (c.db_max - c.db_min));
        },
        A.volume_range_decibels => blk: {
            const c = self.controlOf(object, scope, element).?;
            break :blk put(api.AudioValueRange, data, size, .{ .mMinimum = c.db_min, .mMaximum = c.db_max });
        },
        A.virtual_main_volume => put(f32, data, size, self.controlOf(object, scope, element).?.scalar.?),
        A.mute => put(u32, data, size, @intFromBool(self.controlOf(object, scope, element).?.mute.?)),
        A.data_sources => putIds(data, size, self.sourcesOf(object, scope).?.items),
        A.data_source => put(u32, data, size, self.sourcesOf(object, scope).?.current),
        A.data_source_name => self.putSourceName(self.sourcesOf(object, scope).?, data, size),
        else => api.Status.unknown_property,
    };
}

fn recordSet(self: *Fake, object: api.AudioObjectID, addr: *const api.AudioObjectPropertyAddress, value: u32) void {
    const entry: SetRecord = .{
        .object = object,
        .selector = addr.mSelector,
        .scope = addr.mScope,
        .element = addr.mElement,
        .value = value,
    };
    self.sets.append(self.gpa, entry) catch @panic("the fake ran out of memory");
}

fn objectSetPropertyData(
    ptr: *anyopaque,
    object: api.AudioObjectID,
    addr: *const api.AudioObjectPropertyAddress,
    qualifier_size: u32,
    qualifier: ?*const anyopaque,
    size: u32,
    data: *const anyopaque,
) api.OSStatus {
    _ = qualifier_size;
    _ = qualifier;
    const self = from(ptr);
    self.check();
    const A = api.Selector;
    const selector = addr.mSelector;
    if (object == api.object_system and selector == A.run_loop) {
        self.run_loop_sets += 1;
        return api.Status.ok;
    }
    if (self.fail_set) |status| return status;
    if (object == api.object_system and (selector == A.default_output_device or selector == A.default_input_device)) {
        const wanted = take(u32, data, size) orelse return api.Status.bad_property_size;
        if (self.find(wanted) == null) return api.Status.bad_device;
        self.recordSet(object, addr, wanted);
        if (selector == A.default_output_device) self.setDefaultOut(wanted) else self.setDefaultIn(wanted);
        return api.Status.ok;
    }
    if (!self.known(object, addr)) return api.Status.illegal_operation;
    switch (selector) {
        A.volume_decibels => {
            const c = self.controlOf(object, addr.mScope, addr.mElement).?;
            if (!c.settable) return api.Status.illegal_operation;
            const value = take(f32, data, size) orelse return api.Status.bad_property_size;
            self.recordSet(object, addr, @bitCast(value));
            c.db = std.math.clamp(value, c.db_min, c.db_max);
            self.fireVolume(object, addr.mScope, addr.mElement);
        },
        A.virtual_main_volume => {
            const c = self.controlOf(object, addr.mScope, addr.mElement).?;
            if (!c.settable) return api.Status.illegal_operation;
            const value = take(f32, data, size) orelse return api.Status.bad_property_size;
            self.recordSet(object, addr, @bitCast(value));
            c.scalar = std.math.clamp(value, 0, 1);
            self.fireVolume(object, addr.mScope, addr.mElement);
        },
        A.mute => {
            const c = self.controlOf(object, addr.mScope, addr.mElement).?;
            if (!c.settable) return api.Status.illegal_operation;
            const value = take(u32, data, size) orelse return api.Status.bad_property_size;
            self.recordSet(object, addr, value);
            c.mute = value != 0;
            self.fireAt(object, A.mute, addr.mScope, addr.mElement);
        },
        A.data_source => {
            const set = self.sourcesOf(object, addr.mScope).?;
            if (!set.settable) return api.Status.illegal_operation;
            const value = take(u32, data, size) orelse return api.Status.bad_property_size;
            for (set.items) |item| {
                if (item.id != value) continue;
                self.recordSet(object, addr, value);
                set.current = value;
                self.fireAt(object, A.data_source, addr.mScope, addr.mElement);
                return api.Status.ok;
            }
            return api.Status.illegal_operation;
        },
        else => return api.Status.illegal_operation,
    }
    return api.Status.ok;
}

fn objectAddPropertyListener(
    ptr: *anyopaque,
    object: api.AudioObjectID,
    addr: *const api.AudioObjectPropertyAddress,
    proc: api.AudioObjectPropertyListenerProc,
    client: ?*anyopaque,
) api.OSStatus {
    const self = from(ptr);
    self.check();
    self.lockState();
    defer self.unlockState();
    const added: ObjectListener = .{
        .object = object,
        .selector = addr.mSelector,
        .scope = addr.mScope,
        .element = addr.mElement,
        .proc = proc,
        .client = client,
    };
    self.object_listeners.append(self.gpa, added) catch return api.Status.mem_full;
    self.record(.add_object_listener, 0);
    return api.Status.ok;
}

fn objectRemovePropertyListener(
    ptr: *anyopaque,
    object: api.AudioObjectID,
    addr: *const api.AudioObjectPropertyAddress,
    proc: api.AudioObjectPropertyListenerProc,
    client: ?*anyopaque,
) api.OSStatus {
    const self = from(ptr);
    self.check();
    self.lockState();
    var found = false;
    for (self.object_listeners.items, 0..) |l, i| {
        if (l.object == object and l.selector == addr.mSelector and l.scope == addr.mScope and l.element == addr.mElement and
            l.proc == proc and l.client == client)
        {
            _ = self.object_listeners.orderedRemove(i);
            found = true;
            break;
        }
    }
    if (found) self.record(.remove_object_listener, 0) else self.bad_uses += 1;
    self.unlockState();
    while (self.active_calls.load(.acquire) != 0) std.atomic.spinLoopHint();
    return if (found) api.Status.ok else api.Status.unknown_property;
}

fn stringOf(string: api.CFStringRef) *const Str {
    return @ptrCast(@alignCast(string));
}

fn cfRelease(ptr: *anyopaque, cf: api.CFTypeRef) void {
    const self = from(ptr);
    const made: *Str = @ptrCast(@alignCast(@constCast(cf)));
    self.gpa.destroy(made);
    self.strings_live -= 1;
}

fn cfStringGetLength(ptr: *anyopaque, string: api.CFStringRef) api.CFIndex {
    _ = ptr;
    return @intCast(stringOf(string).bytes.len);
}

fn cfStringGetMaximumSizeForEncoding(ptr: *anyopaque, length: api.CFIndex, encoding: api.CFStringEncoding) api.CFIndex {
    _ = ptr;
    _ = encoding;
    return length;
}

fn cfStringGetBytes(
    ptr: *anyopaque,
    string: api.CFStringRef,
    range: api.CFRange,
    encoding: api.CFStringEncoding,
    loss_byte: u8,
    is_external: api.Boolean,
    buffer: ?[*]u8,
    max_len: api.CFIndex,
    used: ?*api.CFIndex,
) api.CFIndex {
    _ = ptr;
    _ = encoding;
    _ = loss_byte;
    _ = is_external;
    const bytes = stringOf(string).bytes;
    const start: usize = @intCast(range.location);
    const n: usize = @intCast(@min(range.length, max_len));
    if (buffer) |out| @memcpy(out[0..n], bytes[start..][0..n]);
    if (used) |u| u.* = @intCast(n);
    return @intCast(n);
}

fn dlopen(ptr: *anyopaque, path: [*:0]const u8, mode: c_int) ?*anyopaque {
    _ = ptr;
    _ = path;
    _ = mode;
    return null;
}

fn dlsym(ptr: *anyopaque, handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque {
    _ = ptr;
    _ = handle;
    _ = symbol;
    return null;
}

fn threadPolicyGet(ptr: *anyopaque, flavor: u32, info: [*]u32, n: *u32, get_default: *u32) i32 {
    const self = from(ptr);
    if (!in_io) _ = self.violations.fetchAdd(1, .monotonic);
    self.thread_policy_calls += 1;
    if (flavor != api.thread_time_constraint_policy) return 4;
    if (n.* < api.thread_time_constraint_count) return 5;
    info[0] = 0;
    n.* = api.thread_time_constraint_count;
    // As the real call, an input of 1 asks for the default policy and leaves 1.
    if (get_default.* != 0) return 0;
    get_default.* = @intFromBool(!self.realtime_policy);
    return 0;
}

test "the fake keeps devices, units and listeners" {
    const t = std.testing;
    var fake: Fake = .init(t.allocator);
    defer fake.deinit();
    fake.addDevice(.{ .id = 71 });
    const b = fake.binding();
    const desc: api.AudioComponentDescription = .{
        .componentType = api.unit_type_output,
        .componentSubType = api.unit_subtype_hal_output,
        .componentManufacturer = api.unit_manufacturer_apple,
    };
    const component = b.table.componentFindNext(b.self, &desc).?;
    var made: ?api.AudioUnit = null;
    try t.expectEqual(api.Status.ok, b.table.componentInstanceNew(b.self, component, &made));
    try t.expectEqual(@as(usize, 1), fake.unitCount());
    try t.expectEqual(@as(api.AudioObjectID, 71), fake.unit(0).device);
    try t.expectEqual(api.Status.ok, b.table.componentInstanceDispose(b.self, made.?));
    try t.expectEqual(@as(usize, 0), fake.unitCount());
    try t.expectEqual(@as(u32, 0), fake.bad_uses);
}
