//! The AudioManager view of the AAudio backend. It lists the devices of the system, tells which
//! ones are the default, and reads and writes the volume of STREAM_MUSIC. All JNI calls run on the
//! app thread.
const std = @import("std");
const jni = @import("jni.zig");
const api = @import("api.zig");
const Mixer = @import("../../Mixer.zig");
const AAudio = @import("../AAudio.zig");

pub const ScanError = jni.Error || error{OutOfMemory};

const stream_music: i32 = 3;
/// AudioManager.GET_DEVICES_ALL
const all_devices: i32 = 3;
const adjust_mute: i32 = -100;
const adjust_unmute: i32 = 100;
const record_audio = "android.permission.RECORD_AUDIO";
const frame_capacity = 32;
const kinds = [_]Mixer.Kind{ .sink, .source };

const Route = struct {
    method: *jni.MethodId,
    attributes: *jni.Object,
    size: *jni.MethodId,
    get: *jni.MethodId,
};

const Ids = struct {
    check_permission: *jni.MethodId,
    get_devices: *jni.MethodId,
    get_stream_volume: *jni.MethodId,
    get_stream_max_volume: *jni.MethodId,
    set_stream_volume: *jni.MethodId,
    is_stream_mute: *jni.MethodId,
    adjust_stream_volume: *jni.MethodId,
    is_volume_fixed: *jni.MethodId,
    device_id: *jni.MethodId,
    device_type: *jni.MethodId,
    is_sink: *jni.MethodId,
    is_source: *jni.MethodId,
    product_name: *jni.MethodId,
    to_string: *jni.MethodId,
};

/// What the system says about one AudioDeviceInfo.
pub const Info = struct {
    id: i32,
    type: i32,
    sink: bool,
    source: bool,
    name: []const u8,

    fn has(self: Info, kind: Mixer.Kind) bool {
        return switch (kind) {
            .sink => self.sink,
            .source => self.source,
        };
    }
};

/// The volume and mute of STREAM_MUSIC as the Mixer shows them.
pub const Sound = struct {
    volume: Mixer.Volume = .{},
    mute: bool = false,
};

pub fn soundOf(index: i32, max: i32, mute: bool) Sound {
    if (max <= 0) return .{ .mute = mute };
    const clamped = std.math.clamp(index, 0, max);
    const cubic = @as(f32, @floatFromInt(clamped)) / @as(f32, @floatFromInt(max));
    return .{ .volume = .init(&.{Mixer.cubicToLinear(cubic)}), .mute = mute };
}

pub fn typeName(value: i32) []const u8 {
    inline for (comptime std.meta.declarations(api.DeviceType)) |decl| {
        if (@field(api.DeviceType, decl) == value) return decl;
    }
    return "unknown";
}

pub const View = struct {
    vm: jni.Vm,
    /// The Context of the app. The app owns this global reference.
    context: *jni.Object,
    manager: *jni.Object,
    manager_class: *jni.Object,
    info_class: *jni.Object,
    route: ?Route,
    ids: Ids,

    pub fn init(vm_raw: *anyopaque, context_raw: *anyopaque) jni.Error!View {
        var vm: jni.Vm = .init(vm_raw);
        errdefer vm.deinit();
        const env = try vm.env();
        try env.pushFrame(frame_capacity);
        defer env.popFrame();
        const context: *jni.Object = @ptrCast(context_raw);

        const context_class = try env.objectClass(context);
        const check_permission = try env.methodId(context_class, "checkSelfPermission", "(Ljava/lang/String;)I");
        const get_service = try env.methodId(context_class, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;");
        const service_name = try env.newString("audio");
        const service = try env.callObject(context, get_service, &.{.{ .l = service_name }}) orelse return error.NullResult;
        const manager = try env.globalRef(service);
        errdefer env.deleteGlobalRef(manager);

        const manager_class = try env.globalRef(try env.findClass("android/media/AudioManager"));
        errdefer env.deleteGlobalRef(manager_class);
        const info_class = try env.globalRef(try env.findClass("android/media/AudioDeviceInfo"));
        errdefer env.deleteGlobalRef(info_class);
        const sequence_class = try env.findClass("java/lang/CharSequence");

        const ids: Ids = .{
            .check_permission = check_permission,
            .get_devices = try env.methodId(manager_class, "getDevices", "(I)[Landroid/media/AudioDeviceInfo;"),
            .get_stream_volume = try env.methodId(manager_class, "getStreamVolume", "(I)I"),
            .get_stream_max_volume = try env.methodId(manager_class, "getStreamMaxVolume", "(I)I"),
            .set_stream_volume = try env.methodId(manager_class, "setStreamVolume", "(III)V"),
            .is_stream_mute = try env.methodId(manager_class, "isStreamMute", "(I)Z"),
            .adjust_stream_volume = try env.methodId(manager_class, "adjustStreamVolume", "(III)V"),
            .is_volume_fixed = try env.methodId(manager_class, "isVolumeFixed", "()Z"),
            .device_id = try env.methodId(info_class, "getId", "()I"),
            .device_type = try env.methodId(info_class, "getType", "()I"),
            .is_sink = try env.methodId(info_class, "isSink", "()Z"),
            .is_source = try env.methodId(info_class, "isSource", "()Z"),
            .product_name = try env.methodId(info_class, "getProductName", "()Ljava/lang/CharSequence;"),
            .to_string = try env.methodId(sequence_class, "toString", "()Ljava/lang/String;"),
        };
        return .{
            .vm = vm,
            .context = context,
            .manager = manager,
            .manager_class = manager_class,
            .info_class = info_class,
            .route = try findRoute(env, manager_class),
            .ids = ids,
        };
    }

    /// Frees the global references and detaches the thread. Call it on the thread of `init`.
    pub fn deinit(self: *View) void {
        const env = self.vm.env() catch {
            self.vm.deinit();
            return;
        };
        if (self.route) |route| env.deleteGlobalRef(route.attributes);
        env.deleteGlobalRef(self.info_class);
        env.deleteGlobalRef(self.manager_class);
        env.deleteGlobalRef(self.manager);
        self.vm.deinit();
    }

    /// True unless the system says that the app has no permission to record. When the check fails,
    /// the answer is true and the open of the stream finds the real state.
    pub fn recordAllowed(self: *View) bool {
        const env = self.begin() catch return true;
        defer env.popFrame();
        const name = env.newString(record_audio) catch return true;
        const granted = env.callInt(self.context, self.ids.check_permission, &.{.{ .l = name }}) catch return true;
        return granted == 0;
    }

    /// Reads the devices again and updates the Mixer. A failed Java call leaves the Mixer and the
    /// device table as they were.
    pub fn scan(self: *View, be: *AAudio) ScanError!void {
        var arena_state: std.heap.ArenaAllocator = .init(be.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const env = try self.begin();
        defer env.popFrame();

        const array = try env.callObject(self.manager, self.ids.get_devices, &.{.{ .i = all_devices }}) orelse return error.NullResult;
        const count = try env.arrayLength(array);
        var infos: std.ArrayList(Info) = .empty;
        for (0..count) |i| {
            try env.pushFrame(frame_capacity);
            defer env.popFrame();
            const device = try env.objectArrayElement(array, i) orelse continue;
            const info = try self.readInfo(env, device, arena);
            // A row with the id 0 would look like the row of the default device.
            if (info.id == api.unspecified) continue;
            try infos.append(arena, info);
        }
        const route = try self.routeId(env);
        const sound = try self.readSound(env);
        try apply(be, arena, infos.items, route, sound);
    }

    pub fn setVolume(self: *View, be: *AAudio, value: f32) Mixer.Error!void {
        const env = self.begin() catch return error.Unsupported;
        defer env.popFrame();
        const written = self.writeVolume(env, value) catch return error.Unsupported;
        if (!written) return error.Unsupported;
        try self.publish(be, env);
    }

    pub fn setMute(self: *View, be: *AAudio, mute: bool) Mixer.Error!void {
        const env = self.begin() catch return error.Unsupported;
        defer env.popFrame();
        const fixed = env.callBool(self.manager, self.ids.is_volume_fixed, &.{}) catch return error.Unsupported;
        if (fixed) return error.Unsupported;
        const direction: i32 = if (mute) adjust_mute else adjust_unmute;
        env.callVoid(self.manager, self.ids.adjust_stream_volume, &.{ .{ .i = stream_music }, .{ .i = direction }, .{ .i = 0 } }) catch return error.Unsupported;
        try self.publish(be, env);
    }

    fn begin(self: *View) jni.Error!jni.Env {
        const env = try self.vm.env();
        try env.pushFrame(frame_capacity);
        return env;
    }

    /// Returns false when the system has a fixed volume.
    fn writeVolume(self: *View, env: jni.Env, value: f32) jni.Error!bool {
        if (try env.callBool(self.manager, self.ids.is_volume_fixed, &.{})) return false;
        const max = try env.callInt(self.manager, self.ids.get_stream_max_volume, &.{.{ .i = stream_music }});
        if (max <= 0) return false;
        const cubic = std.math.clamp(Mixer.linearToCubic(value), 0, 1);
        const index: i32 = @intFromFloat(@round(cubic * @as(f32, @floatFromInt(max))));
        try env.callVoid(self.manager, self.ids.set_stream_volume, &.{ .{ .i = stream_music }, .{ .i = index }, .{ .i = 0 } });
        return true;
    }

    fn publish(self: *View, be: *AAudio, env: jni.Env) Mixer.Error!void {
        // The write worked, so a failed read back is left to the next scan.
        const sound = self.readSound(env) catch return;
        try pushSound(be, sound);
    }

    fn readSound(self: *View, env: jni.Env) jni.Error!Sound {
        const index = try env.callInt(self.manager, self.ids.get_stream_volume, &.{.{ .i = stream_music }});
        const max = try env.callInt(self.manager, self.ids.get_stream_max_volume, &.{.{ .i = stream_music }});
        const mute = try env.callBool(self.manager, self.ids.is_stream_mute, &.{.{ .i = stream_music }});
        return soundOf(index, max, mute);
    }

    fn readInfo(self: *View, env: jni.Env, device: *jni.Object, arena: std.mem.Allocator) ScanError!Info {
        const ids = self.ids;
        var name: []const u8 = "";
        if (try env.callObject(device, ids.product_name, &.{})) |sequence| {
            if (try env.callObject(sequence, ids.to_string, &.{})) |string| {
                const count = try env.utf8Length(string);
                const buffer = try arena.alloc(u8, count + 1);
                name = try env.copyUtf8(string, count, buffer);
            }
        }
        return .{
            .id = try env.callInt(device, ids.device_id, &.{}),
            .type = try env.callInt(device, ids.device_type, &.{}),
            .sink = try env.callBool(device, ids.is_sink, &.{}),
            .source = try env.callBool(device, ids.is_source, &.{}),
            .name = name,
        };
    }

    /// The id of the device that the system plays media on, or null before API 33.
    fn routeId(self: *View, env: jni.Env) jni.Error!?i32 {
        const route = self.route orelse return null;
        const list = try env.callObject(self.manager, route.method, &.{.{ .l = route.attributes }}) orelse return null;
        if (try env.callInt(list, route.size, &.{}) <= 0) return null;
        const device = try env.callObject(list, route.get, &.{.{ .i = 0 }}) orelse return null;
        return try env.callInt(device, self.ids.device_id, &.{});
    }
};

/// The lookup of getAudioDevicesForAttributes fails before API 33. Then there is no route.
fn findRoute(env: jni.Env, manager_class: *jni.Object) jni.Error!?Route {
    const method = env.methodId(manager_class, "getAudioDevicesForAttributes", "(Landroid/media/AudioAttributes;)Ljava/util/List;") catch |err| switch (err) {
        error.JavaException => return null,
        else => return err,
    };
    const list_class = try env.findClass("java/util/List");
    const builder_class = try env.findClass("android/media/AudioAttributes$Builder");
    const builder = try env.newObject(builder_class, try env.methodId(builder_class, "<init>", "()V"), &.{});
    const set_usage = try env.methodId(builder_class, "setUsage", "(I)Landroid/media/AudioAttributes$Builder;");
    const build = try env.methodId(builder_class, "build", "()Landroid/media/AudioAttributes;");
    const with_usage = try env.callObject(builder, set_usage, &.{.{ .i = api.Usage.media }}) orelse return error.NullResult;
    const attributes = try env.callObject(with_usage, build, &.{}) orelse return error.NullResult;
    const size = try env.methodId(list_class, "size", "()I");
    const get = try env.methodId(list_class, "get", "(I)Ljava/lang/Object;");
    return .{
        .method = method,
        .attributes = try env.globalRef(attributes),
        .size = size,
        .get = get,
    };
}

fn rowFor(be: *AAudio, android_id: i32, kind: Mixer.Kind) ?AAudio.Device {
    for (be.devices.items) |row| {
        if (row.android_id == android_id and row.kind == kind) return row;
    }
    return null;
}

/// The android id of the default device of a kind, from the devices of this scan.
fn pickDefault(infos: []const Info, kind: Mixer.Kind, route: ?i32) ?i32 {
    if (kind == .sink) {
        if (route) |wanted| {
            for (infos) |info| {
                if (info.sink and info.id == wanted) return info.id;
            }
        }
    }
    const built_in = if (kind == .sink) api.DeviceType.builtin_speaker else api.DeviceType.builtin_mic;
    for (infos) |info| {
        if (info.has(kind) and info.type == built_in) return info.id;
    }
    for (infos) |info| {
        if (info.has(kind)) return info.id;
    }
    return null;
}

fn findInfo(infos: []const Info, android_id: i32, kind: Mixer.Kind) ?Info {
    for (infos) |info| {
        if (info.id == android_id and info.has(kind)) return info;
    }
    return null;
}

fn sameEndpoint(a: Mixer.Endpoint, b: Mixer.Endpoint) bool {
    return a.kind == b.kind and a.mute == b.mute and
        std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.description, b.description) and
        a.volume.count == b.volume.count and std.mem.eql(f32, a.volume.slice(), b.volume.slice());
}

fn placeholderId(be: *AAudio, kind: Mixer.Kind) error{OutOfMemory}!Mixer.Id {
    if (rowFor(be, api.unspecified, kind) == null) try be.addDefault(kind);
    return rowFor(be, api.unspecified, kind).?.id;
}

fn apply(be: *AAudio, arena: std.mem.Allocator, infos: []const Info, route: ?i32, sound: Sound) error{OutOfMemory}!void {
    for (infos) |info| {
        for (kinds) |kind| {
            if (!info.has(kind) or rowFor(be, info.id, kind) != null) continue;
            try be.putDevice(.{ .id = be.newId(), .android_id = info.id, .kind = kind });
        }
    }
    var defaults: [kinds.len]Mixer.Id = undefined;
    var have_real: [kinds.len]bool = undefined;
    for (kinds, 0..) |kind, k| {
        const picked = pickDefault(infos, kind, route);
        have_real[k] = picked != null;
        defaults[k] = if (picked) |android_id| rowFor(be, android_id, kind).?.id else try placeholderId(be, kind);
    }
    for (be.devices.items) |row| {
        const is_sound = row.kind == .sink and row.id == defaults[0];
        const want_sound: Sound = if (is_sound) sound else .{};
        var want: Mixer.Endpoint = undefined;
        if (row.android_id == api.unspecified) {
            want = AAudio.defaultEndpoint(row.id, row.kind);
        } else {
            const info = findInfo(infos, row.android_id, row.kind) orelse continue;
            want = .{
                .id = row.id,
                .kind = row.kind,
                .name = try std.fmt.allocPrint(arena, "{s}:{d}", .{ typeName(info.type), info.id }),
                .description = info.name,
                .volume = .{},
            };
        }
        want.volume = want_sound.volume;
        want.mute = want_sound.mute;
        const current = be.mixer.endpoint(row.id);
        if (current == null or !sameEndpoint(current.?.*, want)) try be.mixer.putEndpoint(want);
    }
    for (kinds, 0..) |kind, k| be.mixer.putDefault(kind, defaults[k]);
    var i: usize = 0;
    while (i < be.devices.items.len) {
        const row = be.devices.items[i];
        const k: usize = @backingInt(row.kind);
        const stale = if (row.android_id == api.unspecified)
            have_real[k]
        else
            findInfo(infos, row.android_id, row.kind) == null;
        if (!stale) {
            i += 1;
            continue;
        }
        be.mixer.removeEndpoint(row.id);
        be.removeDevice(row.id);
    }
    try syncStreams(be);
}

/// Gives the volume of STREAM_MUSIC to the endpoint of the default sink.
fn pushSound(be: *AAudio, sound: Sound) error{OutOfMemory}!void {
    const id = be.mixer.default(.sink) orelse return;
    const current = be.mixer.endpoint(id) orelse return;
    var want = current.*;
    want.volume = sound.volume;
    want.mute = sound.mute;
    if (!sameEndpoint(current.*, want)) try be.mixer.putEndpoint(want);
}

/// A stream on the default device follows the default. A stream on a device that is gone moves to
/// the default in the Mixer.
fn syncStreams(be: *AAudio) error{OutOfMemory}!void {
    for (be.entries.items) |entry| {
        const current = be.mixer.stream(entry.app_id) orelse continue;
        const fallback = be.mixer.default(if (entry.playback) .sink else .source);
        const own = if (current.endpoint) |id| be.mixer.endpoint(id) != null else false;
        const wanted = if (entry.android_device != api.unspecified and own) current.endpoint else fallback;
        if (current.endpoint == wanted) continue;
        var value = current.*;
        value.endpoint = wanted;
        try be.mixer.putStream(value);
    }
}

const testing = std.testing;
const fake_jni = @import("fake_jni.zig");

test "the sound of the music stream is a cubic position turned into a linear value" {
    const half = soundOf(7, 14, false);
    try testing.expectEqual(@as(u8, 1), half.volume.count);
    try testing.expectEqual(@as(f32, 0.125), half.volume.values[0]);
    try testing.expectApproxEqAbs(@as(f32, 0.5), Mixer.linearToCubic(half.volume.values[0]), 1e-6);
    try testing.expectEqual(@as(f32, 1), soundOf(14, 14, false).volume.values[0]);
    try testing.expectEqual(@as(f32, 0), soundOf(0, 14, true).volume.values[0]);
    try testing.expect(soundOf(0, 14, true).mute);
    try testing.expectEqual(@as(f32, 1), soundOf(30, 14, false).volume.values[0]);
    try testing.expectEqual(@as(f32, 0), soundOf(-3, 14, false).volume.values[0]);
    try testing.expectEqual(@as(u8, 0), soundOf(3, 0, true).volume.count);
    try testing.expect(soundOf(3, 0, true).mute);
}

test "device types have names" {
    try testing.expectEqualStrings("builtin_speaker", typeName(2));
    try testing.expectEqualStrings("usb_headset", typeName(22));
    try testing.expectEqualStrings("ble_central_broadcast", typeName(35));
    try testing.expectEqualStrings("unknown", typeName(28));
    try testing.expectEqualStrings("unknown", typeName(-1));
}

test "the view keeps three global references and frees them" {
    var fake: fake_jni.Fake = undefined;
    fake.init(testing.allocator);
    defer fake.deinit();
    fake.attached = false;
    var view = try View.init(fake.vm(), fake.contextObject());
    try testing.expect(view.route == null);
    try testing.expectEqual(@as(usize, 3), fake.globalsLive());
    try testing.expectEqual(@as(usize, 0), fake.localsLive());
    try testing.expectEqual(@as(usize, 0), fake.frameDepth());
    try testing.expectEqual(@as(u32, 1), fake.attach_calls);
    view.deinit();
    try testing.expectEqual(@as(usize, 0), fake.globalsLive());
    try testing.expectEqual(@as(u32, 1), fake.detach_calls);
    try testing.expect(!fake.dirty());
}

test "the route of API 33 adds the attributes of media" {
    var fake: fake_jni.Fake = undefined;
    fake.init(testing.allocator);
    defer fake.deinit();
    fake.has_route_api = true;
    var view = try View.init(fake.vm(), fake.contextObject());
    try testing.expect(view.route != null);
    try testing.expectEqual(@as(usize, 4), fake.globalsLive());
    try testing.expectEqual(@as(usize, 0), fake.localsLive());
    view.deinit();
    try testing.expect(!fake.dirty());
}

test "a failed init frees what it made" {
    var fake: fake_jni.Fake = undefined;
    fake.init(testing.allocator);
    defer fake.deinit();
    fake.has_route_api = true;
    fake.throw_on = .builder_set_usage;
    try testing.expectError(error.JavaException, View.init(fake.vm(), fake.contextObject()));
    try testing.expect(!fake.dirty());
    fake.throw_on = .get_system_service;
    try testing.expectError(error.JavaException, View.init(fake.vm(), fake.contextObject()));
    try testing.expect(!fake.dirty());
}

test "the record permission is allowed only when the system grants it" {
    var fake: fake_jni.Fake = undefined;
    fake.init(testing.allocator);
    defer fake.deinit();
    var view = try View.init(fake.vm(), fake.contextObject());
    defer view.deinit();
    try testing.expect(view.recordAllowed());
    fake.permission = &.{-1};
    try testing.expect(!view.recordAllowed());
    fake.throw_on = .check_self_permission;
    try testing.expect(view.recordAllowed());
    try testing.expect(!fake.pending);
    try testing.expectEqual(@as(usize, 0), fake.localsLive());
    try testing.expectEqual(@as(u32, 0), fake.violations);
}

test "a device is read with its name, kind" {
    var fake: fake_jni.Fake = undefined;
    fake.init(testing.allocator);
    defer fake.deinit();
    fake.addDevice(.{ .id = 31, .type = 22, .name = "Écouteurs", .sink = true });
    var view = try View.init(fake.vm(), fake.contextObject());
    defer view.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const env = try view.vm.env();
    try env.pushFrame(8);
    defer env.popFrame();
    const array = (try env.callObject(view.manager, view.ids.get_devices, &.{.{ .i = 3 }})).?;
    try testing.expectEqual(@as(usize, 1), try env.arrayLength(array));
    const info = try view.readInfo(env, (try env.objectArrayElement(array, 0)).?, arena_state.allocator());
    try testing.expectEqual(@as(i32, 31), info.id);
    try testing.expectEqual(@as(i32, 22), info.type);
    try testing.expect(info.sink and !info.source);
    try testing.expectEqualStrings("Écouteurs", info.name);
}

test "a long product name is read whole" {
    var fake: fake_jni.Fake = undefined;
    fake.init(testing.allocator);
    defer fake.deinit();
    const long: [300]u8 = @splat('n');
    fake.addDevice(.{ .id = 5, .type = 2, .name = &long, .sink = true });
    var view = try View.init(fake.vm(), fake.contextObject());
    defer view.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const env = try view.vm.env();
    try env.pushFrame(8);
    defer env.popFrame();
    const array = (try env.callObject(view.manager, view.ids.get_devices, &.{.{ .i = 3 }})).?;
    const info = try view.readInfo(env, (try env.objectArrayElement(array, 0)).?, arena_state.allocator());
    try testing.expectEqualStrings(&long, info.name);
}
