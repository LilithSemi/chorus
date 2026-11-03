//! A fake JNIEnv and JavaVM for tests. They serve a small Java world with an AudioManager. The
//! table positions are written as numbers here and are not taken from jni.zig, so a wrong position
//! in jni.zig shows up as a crash or a wrong result.
const std = @import("std");
const jni = @import("jni.zig");

pub const Device = struct {
    id: i32,
    type: i32,
    name: []const u8,
    sink: bool = false,
    source: bool = false,
    /// A hidden device is not in the getDevices list but a route can name it.
    hidden: bool = false,
};

const Class = enum { context, audio_manager, device_info, char_sequence, list, attributes_builder };

pub const Method = enum {
    get_system_service,
    check_self_permission,
    get_devices,
    get_audio_devices_for_attributes,
    get_stream_volume,
    get_stream_max_volume,
    set_stream_volume,
    is_stream_mute,
    adjust_stream_volume,
    is_volume_fixed,
    device_id,
    device_type,
    is_sink,
    is_source,
    product_name,
    to_string,
    list_size,
    list_get,
    builder_init,
    builder_set_usage,
    builder_build,
};

const MethodRow = struct { class: Class, name: []const u8, signature: []const u8, method: Method };

const method_rows = [_]MethodRow{
    .{ .class = .context, .name = "getSystemService", .signature = "(Ljava/lang/String;)Ljava/lang/Object;", .method = .get_system_service },
    .{ .class = .context, .name = "checkSelfPermission", .signature = "(Ljava/lang/String;)I", .method = .check_self_permission },
    .{ .class = .audio_manager, .name = "getDevices", .signature = "(I)[Landroid/media/AudioDeviceInfo;", .method = .get_devices },
    .{ .class = .audio_manager, .name = "getAudioDevicesForAttributes", .signature = "(Landroid/media/AudioAttributes;)Ljava/util/List;", .method = .get_audio_devices_for_attributes },
    .{ .class = .audio_manager, .name = "getStreamVolume", .signature = "(I)I", .method = .get_stream_volume },
    .{ .class = .audio_manager, .name = "getStreamMaxVolume", .signature = "(I)I", .method = .get_stream_max_volume },
    .{ .class = .audio_manager, .name = "setStreamVolume", .signature = "(III)V", .method = .set_stream_volume },
    .{ .class = .audio_manager, .name = "isStreamMute", .signature = "(I)Z", .method = .is_stream_mute },
    .{ .class = .audio_manager, .name = "adjustStreamVolume", .signature = "(III)V", .method = .adjust_stream_volume },
    .{ .class = .audio_manager, .name = "isVolumeFixed", .signature = "()Z", .method = .is_volume_fixed },
    .{ .class = .device_info, .name = "getId", .signature = "()I", .method = .device_id },
    .{ .class = .device_info, .name = "getType", .signature = "()I", .method = .device_type },
    .{ .class = .device_info, .name = "isSink", .signature = "()Z", .method = .is_sink },
    .{ .class = .device_info, .name = "isSource", .signature = "()Z", .method = .is_source },
    .{ .class = .device_info, .name = "getProductName", .signature = "()Ljava/lang/CharSequence;", .method = .product_name },
    .{ .class = .char_sequence, .name = "toString", .signature = "()Ljava/lang/String;", .method = .to_string },
    .{ .class = .list, .name = "size", .signature = "()I", .method = .list_size },
    .{ .class = .list, .name = "get", .signature = "(I)Ljava/lang/Object;", .method = .list_get },
    .{ .class = .attributes_builder, .name = "<init>", .signature = "()V", .method = .builder_init },
    .{ .class = .attributes_builder, .name = "setUsage", .signature = "(I)Landroid/media/AudioAttributes$Builder;", .method = .builder_set_usage },
    .{ .class = .attributes_builder, .name = "build", .signature = "()Landroid/media/AudioAttributes;", .method = .builder_build },
};

const class_names = [_]struct { name: []const u8, class: Class }{
    .{ .name = "android/media/AudioManager", .class = .audio_manager },
    .{ .name = "android/media/AudioDeviceInfo", .class = .device_info },
    .{ .name = "java/lang/CharSequence", .class = .char_sequence },
    .{ .name = "java/util/List", .class = .list },
    .{ .name = "android/media/AudioAttributes$Builder", .class = .attributes_builder },
};

const Target = union(enum) {
    context,
    manager,
    builder,
    attributes,
    route_list,
    class: Class,
    string: []const u8,
    sequence: []const u8,
    /// An AudioDeviceInfo array with the flags of the getDevices call.
    devices: i32,
    /// An AudioDeviceInfo, as an index into `Fake.devices`.
    device: usize,
};

const Ref = struct { target: Target, state: enum { local, global, dead } };

const permission_name = "android.permission.RECORD_AUDIO";
const slot_count = 233;
const vm_slot_count = 8;

pub const Fake = struct {
    gpa: std.mem.Allocator,

    // The Java world that a test sets.
    devices: std.ArrayList(Device),
    volume: i32,
    max_volume: i32,
    muted: bool,
    fixed: bool,
    /// The answers of checkSelfPermission in order. The last answer repeats.
    permission: []const i32,
    /// The device that getAudioDevicesForAttributes puts first. Null gives an empty list.
    route: ?i32,
    /// False makes the lookup of getAudioDevicesForAttributes throw NoSuchMethodError, as before API 33.
    has_route_api: bool,
    /// A call of this method throws a Java exception.
    throw_on: ?Method,
    /// False makes GetEnv answer JNI_EDETACHED.
    attached: bool,
    attach_fails: bool,

    // What a test reads back.
    attach_calls: u32,
    detach_calls: u32,
    throws: u32,
    /// Calls that a JNI user must not make: a call with an exception pending, a reference used
    /// after it was freed, a wrong stream type and unknown method lookups.
    violations: u32,
    pending: bool,
    get_devices_calls: u32,
    permission_calls: u32,
    last_volume_index: i32,
    last_volume_flags: i32,
    last_adjust: i32,
    set_volume_calls: u32,
    adjust_calls: u32,

    refs: std.ArrayList(Ref),
    marks: std.ArrayList(usize),
    strings: std.ArrayList([]u8),
    env_iface: jni.Slots,
    vm_iface: jni.Slots,
    env_slots: [slot_count]?*const anyopaque,
    vm_slots: [vm_slot_count]?*const anyopaque,

    pub fn init(self: *Fake, gpa: std.mem.Allocator) void {
        self.* = .{
            .gpa = gpa,
            .devices = .empty,
            .volume = 7,
            .max_volume = 14,
            .muted = false,
            .fixed = false,
            .permission = &.{0},
            .route = null,
            .has_route_api = false,
            .throw_on = null,
            .attached = true,
            .attach_fails = false,
            .attach_calls = 0,
            .detach_calls = 0,
            .throws = 0,
            .violations = 0,
            .pending = false,
            .get_devices_calls = 0,
            .permission_calls = 0,
            .last_volume_index = -1,
            .last_volume_flags = -1,
            .last_adjust = 0,
            .set_volume_calls = 0,
            .adjust_calls = 0,
            .refs = .empty,
            .marks = .empty,
            .strings = .empty,
            .env_iface = undefined,
            .vm_iface = undefined,
            .env_slots = @splat(null),
            .vm_slots = @splat(null),
        };
        self.env_iface = &self.env_slots;
        self.vm_iface = &self.vm_slots;
        self.env_slots[6] = @ptrCast(&findClass);
        self.env_slots[17] = @ptrCast(&exceptionClear);
        self.env_slots[19] = @ptrCast(&pushLocalFrame);
        self.env_slots[20] = @ptrCast(&popLocalFrame);
        self.env_slots[21] = @ptrCast(&newGlobalRef);
        self.env_slots[22] = @ptrCast(&deleteGlobalRef);
        self.env_slots[23] = @ptrCast(&deleteLocalRef);
        self.env_slots[30] = @ptrCast(&newObjectA);
        self.env_slots[31] = @ptrCast(&getObjectClass);
        self.env_slots[33] = @ptrCast(&getMethodId);
        self.env_slots[36] = @ptrCast(&callObjectMethodA);
        self.env_slots[39] = @ptrCast(&callBooleanMethodA);
        self.env_slots[51] = @ptrCast(&callIntMethodA);
        self.env_slots[63] = @ptrCast(&callVoidMethodA);
        self.env_slots[164] = @ptrCast(&getStringLength);
        self.env_slots[167] = @ptrCast(&newStringUtf);
        self.env_slots[168] = @ptrCast(&getStringUtfLength);
        self.env_slots[171] = @ptrCast(&getArrayLength);
        self.env_slots[173] = @ptrCast(&getObjectArrayElement);
        self.env_slots[221] = @ptrCast(&getStringUtfRegion);
        self.env_slots[228] = @ptrCast(&exceptionCheck);
        self.vm_slots[4] = @ptrCast(&attachCurrentThread);
        self.vm_slots[5] = @ptrCast(&detachCurrentThread);
        self.vm_slots[6] = @ptrCast(&getEnv);
        // The first two references belong to the app and are never freed.
        self.refs.append(gpa, .{ .target = .context, .state = .global }) catch @panic("out of memory");
        self.refs.append(gpa, .{ .target = .manager, .state = .global }) catch @panic("out of memory");
    }

    pub fn deinit(self: *Fake) void {
        for (self.strings.items) |s| self.gpa.free(s);
        self.strings.deinit(self.gpa);
        self.devices.deinit(self.gpa);
        self.refs.deinit(self.gpa);
        self.marks.deinit(self.gpa);
    }

    pub fn vm(self: *Fake) *anyopaque {
        return @ptrCast(&self.vm_iface);
    }

    pub fn env(self: *Fake) jni.Env {
        return .{ .ptr = &self.env_iface };
    }

    /// The global reference that an app gives as its Context.
    pub fn contextObject(self: *Fake) *jni.Object {
        _ = self;
        return handle(0);
    }

    pub fn managerObject(self: *Fake) *jni.Object {
        _ = self;
        return handle(1);
    }

    pub fn addDevice(self: *Fake, device: Device) void {
        self.devices.append(self.gpa, device) catch @panic("out of memory");
    }

    pub fn removeDevice(self: *Fake, id: i32) void {
        for (self.devices.items, 0..) |d, i| {
            if (d.id == id) {
                _ = self.devices.orderedRemove(i);
                return;
            }
        }
    }

    pub fn localsLive(self: *const Fake) usize {
        var count: usize = 0;
        for (self.refs.items) |r| {
            if (r.state == .local) count += 1;
        }
        return count;
    }

    /// The global references that the library holds, not counting the two of the app.
    pub fn globalsLive(self: *const Fake) usize {
        var count: usize = 0;
        for (self.refs.items[2..]) |r| {
            if (r.state == .global) count += 1;
        }
        return count;
    }

    pub fn frameDepth(self: *const Fake) usize {
        return self.marks.items.len;
    }

    /// True when the library left a reference, a frame, an exception or a misuse behind.
    pub fn dirty(self: *const Fake) bool {
        return self.localsLive() != 0 or self.globalsLive() != 0 or self.frameDepth() != 0 or self.pending or self.violations != 0;
    }
};

fn handle(index: usize) *jni.Object {
    return @ptrFromInt(index + 1);
}

fn fakeOf(env: jni.EnvPtr) *Fake {
    return @constCast(@fieldParentPtr("env_iface", env));
}

fn newRef(self: *Fake, target: Target) *jni.Object {
    self.refs.append(self.gpa, .{ .target = target, .state = .local }) catch @panic("out of memory");
    return handle(self.refs.items.len - 1);
}

fn resolve(self: *Fake, object: ?*jni.Object) ?Target {
    const raw = @intFromPtr(object orelse {
        self.violations += 1;
        return null;
    });
    if (raw == 0 or raw > self.refs.items.len or self.refs.items[raw - 1].state == .dead) {
        self.violations += 1;
        return null;
    }
    return self.refs.items[raw - 1].target;
}

fn throw(self: *Fake) void {
    self.pending = true;
    self.throws += 1;
}

/// Every call except the few that the JNI rules allow needs a clean exception state.
fn enter(self: *Fake) void {
    if (self.pending) self.violations += 1;
}

fn findClass(env: jni.EnvPtr, name: [*:0]const u8) callconv(.c) ?*jni.Object {
    const self = fakeOf(env);
    enter(self);
    for (class_names) |row| {
        if (std.mem.eql(u8, std.mem.span(name), row.name)) return newRef(self, .{ .class = row.class });
    }
    throw(self);
    return null;
}

fn exceptionCheck(env: jni.EnvPtr) callconv(.c) u8 {
    return @intFromBool(fakeOf(env).pending);
}

fn exceptionClear(env: jni.EnvPtr) callconv(.c) void {
    fakeOf(env).pending = false;
}

fn pushLocalFrame(env: jni.EnvPtr, capacity: i32) callconv(.c) i32 {
    _ = capacity;
    const self = fakeOf(env);
    enter(self);
    self.marks.append(self.gpa, self.refs.items.len) catch @panic("out of memory");
    return 0;
}

fn popLocalFrame(env: jni.EnvPtr, result: ?*jni.Object) callconv(.c) ?*jni.Object {
    const self = fakeOf(env);
    const mark = self.marks.pop() orelse {
        self.violations += 1;
        return null;
    };
    for (self.refs.items[mark..]) |*r| {
        if (r.state == .local) r.state = .dead;
    }
    return result;
}

fn newGlobalRef(env: jni.EnvPtr, object: *jni.Object) callconv(.c) ?*jni.Object {
    const self = fakeOf(env);
    enter(self);
    const target = resolve(self, object) orelse return null;
    self.refs.append(self.gpa, .{ .target = target, .state = .global }) catch @panic("out of memory");
    return handle(self.refs.items.len - 1);
}

fn deleteGlobalRef(env: jni.EnvPtr, object: *jni.Object) callconv(.c) void {
    const self = fakeOf(env);
    _ = resolve(self, object) orelse return;
    const ref = &self.refs.items[@intFromPtr(object) - 1];
    if (ref.state != .global) self.violations += 1;
    ref.state = .dead;
}

fn deleteLocalRef(env: jni.EnvPtr, object: *jni.Object) callconv(.c) void {
    const self = fakeOf(env);
    _ = resolve(self, object) orelse return;
    const ref = &self.refs.items[@intFromPtr(object) - 1];
    if (ref.state != .local) self.violations += 1;
    ref.state = .dead;
}

fn getObjectClass(env: jni.EnvPtr, object: *jni.Object) callconv(.c) ?*jni.Object {
    const self = fakeOf(env);
    enter(self);
    const target = resolve(self, object) orelse return null;
    return switch (target) {
        .context => newRef(self, .{ .class = .context }),
        .manager => newRef(self, .{ .class = .audio_manager }),
        else => blk: {
            self.violations += 1;
            break :blk null;
        },
    };
}

fn getMethodId(env: jni.EnvPtr, class: *jni.Object, name: [*:0]const u8, signature: [*:0]const u8) callconv(.c) ?*jni.MethodId {
    const self = fakeOf(env);
    enter(self);
    const target = resolve(self, class) orelse return null;
    const wanted = switch (target) {
        .class => |c| c,
        else => {
            self.violations += 1;
            return null;
        },
    };
    for (method_rows) |row| {
        if (row.class != wanted) continue;
        if (!std.mem.eql(u8, std.mem.span(name), row.name) or !std.mem.eql(u8, std.mem.span(signature), row.signature)) continue;
        if (row.method == .get_audio_devices_for_attributes and !self.has_route_api) {
            throw(self);
            return null;
        }
        return @ptrFromInt(@backingInt(row.method) + 1);
    }
    self.violations += 1;
    throw(self);
    return null;
}

fn methodOf(mid: *jni.MethodId) Method {
    return @fromBackingInt(@intCast(@intFromPtr(mid) - 1));
}

fn thrown(self: *Fake, method: Method) bool {
    if (self.throw_on != method) return false;
    throw(self);
    return true;
}

fn argString(self: *Fake, args: [*]const jni.Value, i: usize) ?[]const u8 {
    return switch (resolve(self, args[i].l) orelse return null) {
        .string => |s| s,
        else => blk: {
            self.violations += 1;
            break :blk null;
        },
    };
}

fn deviceOf(self: *Fake, target: Target) ?*const Device {
    switch (target) {
        .device => |i| return &self.devices.items[i],
        else => {
            self.violations += 1;
            return null;
        },
    }
}

fn matches(device: Device, flags: i32) bool {
    if (device.hidden) return false;
    return (flags & 1 != 0 and device.source) or (flags & 2 != 0 and device.sink);
}

fn nthMatch(self: *Fake, flags: i32, n: usize) ?usize {
    var seen: usize = 0;
    for (self.devices.items, 0..) |d, i| {
        if (!matches(d, flags)) continue;
        if (seen == n) return i;
        seen += 1;
    }
    return null;
}

fn callObjectMethodA(env: jni.EnvPtr, object: *jni.Object, mid: *jni.MethodId, args: [*]const jni.Value) callconv(.c) ?*jni.Object {
    const self = fakeOf(env);
    enter(self);
    const target = resolve(self, object) orelse return null;
    const method = methodOf(mid);
    if (thrown(self, method)) return null;
    switch (method) {
        .get_system_service => {
            const name = argString(self, args, 0) orelse return null;
            if (!std.mem.eql(u8, name, "audio")) return null;
            return newRef(self, .manager);
        },
        .get_devices => {
            self.get_devices_calls += 1;
            return newRef(self, .{ .devices = args[0].i });
        },
        .get_audio_devices_for_attributes => {
            const arg = resolve(self, args[0].l) orelse return null;
            if (arg != .attributes) self.violations += 1;
            return newRef(self, .route_list);
        },
        .list_get => {
            const id = self.route orelse return null;
            for (self.devices.items, 0..) |d, i| {
                if (d.id == id and args[0].i == 0) return newRef(self, .{ .device = i });
            }
            throw(self);
            return null;
        },
        .product_name => {
            const device = deviceOf(self, target) orelse return null;
            return newRef(self, .{ .sequence = device.name });
        },
        .to_string => switch (target) {
            .sequence => |s| return newRef(self, .{ .string = s }),
            else => {
                self.violations += 1;
                return null;
            },
        },
        .builder_set_usage => return newRef(self, .builder),
        .builder_build => return newRef(self, .attributes),
        else => {
            self.violations += 1;
            return null;
        },
    }
}

fn newObjectA(env: jni.EnvPtr, class: *jni.Object, mid: *jni.MethodId, args: [*]const jni.Value) callconv(.c) ?*jni.Object {
    _ = args;
    const self = fakeOf(env);
    enter(self);
    _ = resolve(self, class) orelse return null;
    if (methodOf(mid) != .builder_init) {
        self.violations += 1;
        return null;
    }
    return newRef(self, .builder);
}

fn callBooleanMethodA(env: jni.EnvPtr, object: *jni.Object, mid: *jni.MethodId, args: [*]const jni.Value) callconv(.c) u8 {
    _ = args;
    const self = fakeOf(env);
    enter(self);
    const target = resolve(self, object) orelse return 0;
    const method = methodOf(mid);
    if (thrown(self, method)) return 0;
    return switch (method) {
        .is_stream_mute => @intFromBool(self.muted),
        .is_volume_fixed => @intFromBool(self.fixed),
        .is_sink => @intFromBool((deviceOf(self, target) orelse return 0).sink),
        .is_source => @intFromBool((deviceOf(self, target) orelse return 0).source),
        else => blk: {
            self.violations += 1;
            break :blk 0;
        },
    };
}

fn callIntMethodA(env: jni.EnvPtr, object: *jni.Object, mid: *jni.MethodId, args: [*]const jni.Value) callconv(.c) i32 {
    const self = fakeOf(env);
    enter(self);
    const target = resolve(self, object) orelse return 0;
    const method = methodOf(mid);
    if (thrown(self, method)) return 0;
    switch (method) {
        .check_self_permission => {
            const name = argString(self, args, 0) orelse return -1;
            if (!std.mem.eql(u8, name, permission_name)) self.violations += 1;
            const at = @min(self.permission_calls, self.permission.len - 1);
            self.permission_calls += 1;
            return self.permission[at];
        },
        .get_stream_volume, .get_stream_max_volume => {
            if (args[0].i != 3) self.violations += 1;
            return if (method == .get_stream_volume) self.volume else self.max_volume;
        },
        .device_id => return (deviceOf(self, target) orelse return 0).id,
        .device_type => return (deviceOf(self, target) orelse return 0).type,
        .list_size => return @intFromBool(self.route != null),
        else => {
            self.violations += 1;
            return 0;
        },
    }
}

fn callVoidMethodA(env: jni.EnvPtr, object: *jni.Object, mid: *jni.MethodId, args: [*]const jni.Value) callconv(.c) void {
    const self = fakeOf(env);
    enter(self);
    _ = resolve(self, object) orelse return;
    const method = methodOf(mid);
    if (thrown(self, method)) return;
    if (args[0].i != 3) self.violations += 1;
    switch (method) {
        .set_stream_volume => {
            self.set_volume_calls += 1;
            self.last_volume_index = args[1].i;
            self.last_volume_flags = args[2].i;
            self.volume = args[1].i;
        },
        .adjust_stream_volume => {
            self.adjust_calls += 1;
            self.last_adjust = args[1].i;
            self.last_volume_flags = args[2].i;
            switch (args[1].i) {
                -100 => self.muted = true,
                100 => self.muted = false,
                else => self.violations += 1,
            }
        },
        else => self.violations += 1,
    }
}

fn newStringUtf(env: jni.EnvPtr, chars: [*:0]const u8) callconv(.c) ?*jni.Object {
    const self = fakeOf(env);
    enter(self);
    const copy = self.gpa.dupe(u8, std.mem.span(chars)) catch @panic("out of memory");
    self.strings.append(self.gpa, copy) catch @panic("out of memory");
    return newRef(self, .{ .string = copy });
}

fn stringOf(self: *Fake, object: *jni.Object) ?[]const u8 {
    return switch (resolve(self, object) orelse return null) {
        .string => |s| s,
        else => blk: {
            self.violations += 1;
            break :blk null;
        },
    };
}

/// Java counts UTF-16 units, so a character outside the BMP counts twice.
fn utf16Units(s: []const u8) i32 {
    var units: i32 = 0;
    var view = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (view.nextCodepoint()) |cp| units += if (cp >= 0x10000) 2 else 1;
    return units;
}

fn getStringLength(env: jni.EnvPtr, string: *jni.Object) callconv(.c) i32 {
    const self = fakeOf(env);
    enter(self);
    const s = stringOf(self, string) orelse return 0;
    return utf16Units(s);
}

fn getStringUtfLength(env: jni.EnvPtr, string: *jni.Object) callconv(.c) i32 {
    const self = fakeOf(env);
    enter(self);
    return @intCast((stringOf(self, string) orelse return 0).len);
}

/// Writes the bytes and a zero, as the system does. It does not look at the size of the buffer.
fn getStringUtfRegion(env: jni.EnvPtr, string: *jni.Object, start: i32, len: i32, buffer: [*]u8) callconv(.c) void {
    const self = fakeOf(env);
    enter(self);
    const s = stringOf(self, string) orelse return;
    const units = utf16Units(s);
    if (start != 0 or len != units) {
        throw(self);
        return;
    }
    @memcpy(buffer[0..s.len], s);
    buffer[s.len] = 0;
}

fn getArrayLength(env: jni.EnvPtr, array: *jni.Object) callconv(.c) i32 {
    const self = fakeOf(env);
    enter(self);
    switch (resolve(self, array) orelse return 0) {
        .devices => |flags| {
            var n: i32 = 0;
            for (self.devices.items) |d| n += @intFromBool(matches(d, flags));
            return n;
        },
        else => {
            self.violations += 1;
            return 0;
        },
    }
}

fn getObjectArrayElement(env: jni.EnvPtr, array: *jni.Object, index: i32) callconv(.c) ?*jni.Object {
    const self = fakeOf(env);
    enter(self);
    switch (resolve(self, array) orelse return null) {
        .devices => |flags| {
            const at = nthMatch(self, flags, @intCast(index)) orelse {
                throw(self);
                return null;
            };
            return newRef(self, .{ .device = at });
        },
        else => {
            self.violations += 1;
            return null;
        },
    }
}

fn vmOf(vm: jni.VmPtr) *Fake {
    return @constCast(@fieldParentPtr("vm_iface", vm));
}

fn getEnv(vm: jni.VmPtr, out: *?*anyopaque, version: i32) callconv(.c) i32 {
    const self = vmOf(vm);
    out.* = null;
    if (version != jni.version_1_6) return -3;
    if (!self.attached) return jni.detached;
    out.* = @ptrCast(&self.env_iface);
    return jni.ok;
}

fn attachCurrentThread(vm: jni.VmPtr, out: *?*anyopaque, args: ?*anyopaque) callconv(.c) i32 {
    _ = args;
    const self = vmOf(vm);
    if (self.attach_fails) return -1;
    self.attach_calls += 1;
    self.attached = true;
    out.* = @ptrCast(&self.env_iface);
    return jni.ok;
}

fn detachCurrentThread(vm: jni.VmPtr) callconv(.c) i32 {
    const self = vmOf(vm);
    self.detach_calls += 1;
    self.attached = false;
    return jni.ok;
}
