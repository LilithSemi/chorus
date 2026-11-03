//! The part of JNI that the AAudio backend uses. A JNIEnv and a JavaVM are pointers to tables of
//! functions. The tables have one entry per function, and an entry is as large as a pointer.
//! So the code indexes the tables and never uses byte offsets.
const std = @import("std");
const builtin = @import("builtin");

pub const Object = opaque {};
pub const MethodId = opaque {};

pub const Slots = [*]const ?*const anyopaque;
pub const EnvPtr = *const Slots;
pub const VmPtr = *const Slots;

pub const Value = extern union {
    z: u8,
    b: i8,
    c: u16,
    s: i16,
    i: i32,
    j: i64,
    f: f32,
    d: f64,
    l: ?*Object,
};

pub const ok: i32 = 0;
pub const detached: i32 = -2;
pub const version_1_6: i32 = 0x00010006;

pub const Error = error{
    /// A Java call threw. The exception is cleared.
    JavaException,
    /// A call returned null where the caller needs an object.
    NullResult,
    VmFailure,
    /// A string does not fit in the buffer of the caller.
    NameTooLong,
};

/// The position of each function in the JNIEnv table.
pub const Slot = struct {
    pub const find_class = 6;
    pub const exception_clear = 17;
    pub const push_local_frame = 19;
    pub const pop_local_frame = 20;
    pub const new_global_ref = 21;
    pub const delete_global_ref = 22;
    pub const delete_local_ref = 23;
    pub const new_object_a = 30;
    pub const get_object_class = 31;
    pub const get_method_id = 33;
    pub const call_object_method_a = 36;
    pub const call_boolean_method_a = 39;
    pub const call_int_method_a = 51;
    pub const call_void_method_a = 63;
    pub const get_string_length = 164;
    pub const new_string_utf = 167;
    pub const get_string_utf_length = 168;
    pub const get_array_length = 171;
    pub const get_object_array_element = 173;
    pub const get_string_utf_region = 221;
    pub const exception_check = 228;
};

/// The position of each function in the JavaVM table.
pub const VmSlot = struct {
    pub const attach_current_thread = 4;
    pub const detach_current_thread = 5;
    pub const get_env = 6;
};

fn slot(table: *const Slots, comptime index: usize, comptime F: type) *const F {
    return @ptrCast(@alignCast(table.*[index].?));
}

pub const Env = struct {
    ptr: EnvPtr,

    /// Turns a pending Java exception into an error. The exception is cleared.
    pub fn check(self: Env) Error!void {
        if (slot(self.ptr, Slot.exception_check, fn (EnvPtr) callconv(.c) u8)(self.ptr) == 0) return;
        slot(self.ptr, Slot.exception_clear, fn (EnvPtr) callconv(.c) void)(self.ptr);
        return error.JavaException;
    }

    pub fn pushFrame(self: Env, capacity: i32) Error!void {
        const result = slot(self.ptr, Slot.push_local_frame, fn (EnvPtr, i32) callconv(.c) i32)(self.ptr, capacity);
        if (result != ok) {
            try self.check();
            return error.JavaException;
        }
    }

    /// Frees every local reference made since the matching `pushFrame`.
    pub fn popFrame(self: Env) void {
        _ = slot(self.ptr, Slot.pop_local_frame, fn (EnvPtr, ?*Object) callconv(.c) ?*Object)(self.ptr, null);
    }

    pub fn findClass(self: Env, name: [*:0]const u8) Error!*Object {
        const result = slot(self.ptr, Slot.find_class, fn (EnvPtr, [*:0]const u8) callconv(.c) ?*Object)(self.ptr, name);
        try self.check();
        return result orelse error.NullResult;
    }

    pub fn objectClass(self: Env, object: *Object) Error!*Object {
        const result = slot(self.ptr, Slot.get_object_class, fn (EnvPtr, *Object) callconv(.c) ?*Object)(self.ptr, object);
        try self.check();
        return result orelse error.NullResult;
    }

    pub fn methodId(self: Env, class: *Object, name: [*:0]const u8, signature: [*:0]const u8) Error!*MethodId {
        const result = slot(self.ptr, Slot.get_method_id, fn (EnvPtr, *Object, [*:0]const u8, [*:0]const u8) callconv(.c) ?*MethodId)(self.ptr, class, name, signature);
        try self.check();
        return result orelse error.NullResult;
    }

    pub fn newObject(self: Env, class: *Object, method: *MethodId, args: []const Value) Error!*Object {
        const result = slot(self.ptr, Slot.new_object_a, fn (EnvPtr, *Object, *MethodId, [*]const Value) callconv(.c) ?*Object)(self.ptr, class, method, args.ptr);
        try self.check();
        return result orelse error.NullResult;
    }

    pub fn callObject(self: Env, object: *Object, method: *MethodId, args: []const Value) Error!?*Object {
        const result = slot(self.ptr, Slot.call_object_method_a, fn (EnvPtr, *Object, *MethodId, [*]const Value) callconv(.c) ?*Object)(self.ptr, object, method, args.ptr);
        try self.check();
        return result;
    }

    pub fn callBool(self: Env, object: *Object, method: *MethodId, args: []const Value) Error!bool {
        const result = slot(self.ptr, Slot.call_boolean_method_a, fn (EnvPtr, *Object, *MethodId, [*]const Value) callconv(.c) u8)(self.ptr, object, method, args.ptr);
        try self.check();
        return result != 0;
    }

    pub fn callInt(self: Env, object: *Object, method: *MethodId, args: []const Value) Error!i32 {
        const result = slot(self.ptr, Slot.call_int_method_a, fn (EnvPtr, *Object, *MethodId, [*]const Value) callconv(.c) i32)(self.ptr, object, method, args.ptr);
        try self.check();
        return result;
    }

    pub fn callVoid(self: Env, object: *Object, method: *MethodId, args: []const Value) Error!void {
        slot(self.ptr, Slot.call_void_method_a, fn (EnvPtr, *Object, *MethodId, [*]const Value) callconv(.c) void)(self.ptr, object, method, args.ptr);
        try self.check();
    }

    pub fn newString(self: Env, chars: [*:0]const u8) Error!*Object {
        const result = slot(self.ptr, Slot.new_string_utf, fn (EnvPtr, [*:0]const u8) callconv(.c) ?*Object)(self.ptr, chars);
        try self.check();
        return result orelse error.NullResult;
    }

    pub fn globalRef(self: Env, object: *Object) Error!*Object {
        const result = slot(self.ptr, Slot.new_global_ref, fn (EnvPtr, *Object) callconv(.c) ?*Object)(self.ptr, object);
        try self.check();
        return result orelse error.NullResult;
    }

    pub fn deleteGlobalRef(self: Env, object: *Object) void {
        slot(self.ptr, Slot.delete_global_ref, fn (EnvPtr, *Object) callconv(.c) void)(self.ptr, object);
    }

    pub fn deleteLocalRef(self: Env, object: *Object) void {
        slot(self.ptr, Slot.delete_local_ref, fn (EnvPtr, *Object) callconv(.c) void)(self.ptr, object);
    }

    pub fn arrayLength(self: Env, array: *Object) Error!usize {
        const result = slot(self.ptr, Slot.get_array_length, fn (EnvPtr, *Object) callconv(.c) i32)(self.ptr, array);
        try self.check();
        return @intCast(@max(result, 0));
    }

    pub fn objectArrayElement(self: Env, array: *Object, index: usize) Error!?*Object {
        const result = slot(self.ptr, Slot.get_object_array_element, fn (EnvPtr, *Object, i32) callconv(.c) ?*Object)(self.ptr, array, @intCast(index));
        try self.check();
        return result;
    }

    /// The number of bytes of a string in modified UTF-8.
    pub fn utf8Length(self: Env, string: *Object) Error!usize {
        const bytes = slot(self.ptr, Slot.get_string_utf_length, fn (EnvPtr, *Object) callconv(.c) i32)(self.ptr, string);
        try self.check();
        return @intCast(@max(bytes, 0));
    }

    /// Copies a string in modified UTF-8 into `buffer` and returns the bytes of it.
    pub fn stringUtf8(self: Env, string: *Object, buffer: []u8) Error![]const u8 {
        return self.copyUtf8(string, try self.utf8Length(string), buffer);
    }

    /// Like `stringUtf8` for a caller that has the byte count from `utf8Length`.
    pub fn copyUtf8(self: Env, string: *Object, count: usize, buffer: []u8) Error![]const u8 {
        // The system writes a terminating zero after the bytes.
        if (count >= buffer.len) return error.NameTooLong;
        const units = slot(self.ptr, Slot.get_string_length, fn (EnvPtr, *Object) callconv(.c) i32)(self.ptr, string);
        try self.check();
        slot(self.ptr, Slot.get_string_utf_region, fn (EnvPtr, *Object, i32, i32, [*]u8) callconv(.c) void)(self.ptr, string, 0, units, buffer.ptr);
        try self.check();
        return buffer[0..count];
    }
};

/// The JavaVM of the app and the attach state of the thread that uses it.
pub const Vm = struct {
    ptr: VmPtr,
    /// True when `env` attached the thread of `thread`.
    attached: bool = false,
    thread: std.Thread.Id = 0,
    /// The thread of the first `env` call. No other thread gets attached.
    owner: ?std.Thread.Id = null,

    pub fn init(raw: *anyopaque) Vm {
        return .{ .ptr = @ptrCast(@alignCast(raw)) };
    }

    /// The JNIEnv of the calling thread. A thread that the VM does not know gets attached once.
    pub fn env(self: *Vm) Error!Env {
        var out: ?*anyopaque = null;
        const get = slot(self.ptr, VmSlot.get_env, fn (VmPtr, *?*anyopaque, i32) callconv(.c) i32);
        const found = get(self.ptr, &out, version_1_6);
        if (found == detached) {
            const current = std.Thread.getCurrentId();
            if (self.owner) |owner| {
                if (owner != current) return error.VmFailure;
            }
            const attach = slot(self.ptr, VmSlot.attach_current_thread, fn (VmPtr, *?*anyopaque, ?*anyopaque) callconv(.c) i32);
            if (attach(self.ptr, &out, null) != ok) return error.VmFailure;
            self.attached = true;
            self.thread = std.Thread.getCurrentId();
        } else if (found != ok) {
            return error.VmFailure;
        }
        const raw = out orelse return error.VmFailure;
        if (self.owner == null) self.owner = std.Thread.getCurrentId();
        return .{ .ptr = @ptrCast(@alignCast(raw)) };
    }

    /// Detaches the thread when `env` attached it. Call it on the thread that called `env`.
    pub fn deinit(self: *Vm) void {
        if (!self.attached or self.thread != std.Thread.getCurrentId()) return;
        _ = slot(self.ptr, VmSlot.detach_current_thread, fn (VmPtr) callconv(.c) i32)(self.ptr);
        self.attached = false;
    }
};

const fake_jni = @import("fake_jni.zig");
const testing = std.testing;

test "a jvalue is 8 bytes and a table entry is as large as a pointer" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Value));
    try testing.expectEqual(@sizeOf(usize), @sizeOf(?*const anyopaque));
}

test "a detached thread is attached once and detached by deinit" {
    var fake: fake_jni.Fake = undefined;
    fake.init(testing.allocator);
    defer fake.deinit();
    fake.attached = false;
    var vm: Vm = .init(fake.vm());
    _ = try vm.env();
    _ = try vm.env();
    try testing.expectEqual(@as(u32, 1), fake.attach_calls);
    try testing.expect(fake.attached);
    vm.deinit();
    try testing.expectEqual(@as(u32, 1), fake.detach_calls);
    try testing.expect(!fake.attached);
    vm.deinit();
    try testing.expectEqual(@as(u32, 1), fake.detach_calls);
}

test "a thread that was attached before is not detached" {
    var fake: fake_jni.Fake = undefined;
    fake.init(testing.allocator);
    defer fake.deinit();
    var vm: Vm = .init(fake.vm());
    _ = try vm.env();
    vm.deinit();
    try testing.expectEqual(@as(u32, 0), fake.attach_calls);
    try testing.expectEqual(@as(u32, 0), fake.detach_calls);
    try testing.expect(fake.attached);
}

test "a thread that cannot attach gives an error" {
    var fake: fake_jni.Fake = undefined;
    fake.init(testing.allocator);
    defer fake.deinit();
    fake.attached = false;
    fake.attach_fails = true;
    var vm: Vm = .init(fake.vm());
    try testing.expectError(error.VmFailure, vm.env());
    try testing.expect(!vm.attached);
}

test "a Java exception is cleared and becomes an error" {
    var fake: fake_jni.Fake = undefined;
    fake.init(testing.allocator);
    defer fake.deinit();
    var vm: Vm = .init(fake.vm());
    const env = try vm.env();
    const class = try env.findClass("android/media/AudioManager");
    const method = try env.methodId(class, "getStreamVolume", "(I)I");
    const manager = fake.managerObject();
    fake.throw_on = .get_stream_volume;
    try testing.expectError(error.JavaException, env.callInt(manager, method, &.{.{ .i = 3 }}));
    try testing.expect(!fake.pending);
    try testing.expectEqual(@as(u32, 1), fake.throws);
    fake.throw_on = null;
    try testing.expectEqual(@as(i32, 7), try env.callInt(manager, method, &.{.{ .i = 3 }}));
    try testing.expectEqual(@as(u32, 0), fake.violations);
}

test "a method that does not exist gives an error and no pending exception" {
    var fake: fake_jni.Fake = undefined;
    fake.init(testing.allocator);
    defer fake.deinit();
    var vm: Vm = .init(fake.vm());
    const env = try vm.env();
    const class = try env.findClass("android/media/AudioManager");
    fake.has_route_api = false;
    try testing.expectError(error.JavaException, env.methodId(class, "getAudioDevicesForAttributes", "(Landroid/media/AudioAttributes;)Ljava/util/List;"));
    try testing.expect(!fake.pending);
    try testing.expectError(error.JavaException, env.findClass("no/such/Class"));
    try testing.expect(!fake.pending);
    try testing.expectEqual(@as(u32, 0), fake.violations);
}

test "a frame frees the local references made inside it" {
    var fake: fake_jni.Fake = undefined;
    fake.init(testing.allocator);
    defer fake.deinit();
    var vm: Vm = .init(fake.vm());
    const env = try vm.env();
    try env.pushFrame(8);
    const keep = try env.globalRef(try env.findClass("android/media/AudioManager"));
    _ = try env.newString("a");
    _ = try env.newString("b");
    try testing.expectEqual(@as(usize, 3), fake.localsLive());
    env.popFrame();
    try testing.expectEqual(@as(usize, 0), fake.localsLive());
    try testing.expectEqual(@as(usize, 0), fake.frameDepth());
    try testing.expectEqual(@as(usize, 1), fake.globalsLive());
    env.deleteGlobalRef(keep);
    try testing.expectEqual(@as(usize, 0), fake.globalsLive());
    try testing.expectEqual(@as(u32, 0), fake.violations);
}

test "a string is copied in modified UTF-8 into the buffer" {
    var fake: fake_jni.Fake = undefined;
    fake.init(testing.allocator);
    defer fake.deinit();
    var vm: Vm = .init(fake.vm());
    const env = try vm.env();
    const string = try env.newString("Écouteurs");
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("Écouteurs", try env.stringUtf8(string, &buffer));
    var small: [10]u8 = undefined;
    try testing.expectError(error.NameTooLong, env.stringUtf8(string, &small));
    var exact: [11]u8 = undefined;
    try testing.expectEqualStrings("Écouteurs", try env.stringUtf8(string, &exact));
    const emoji = try env.newString("Ear 🎧");
    var wide: [16]u8 = undefined;
    try testing.expectEqualStrings("Ear 🎧", try env.stringUtf8(emoji, &wide));
    try testing.expectEqual(@as(u32, 0), fake.violations);
}

test "a second thread is not attached" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var fake: fake_jni.Fake = undefined;
    fake.init(testing.allocator);
    defer fake.deinit();
    var vm: Vm = .init(fake.vm());
    _ = try vm.env();
    fake.attached = false;
    const Other = struct {
        vm: *Vm,
        result: ?Error = null,

        fn run(self: *@This()) void {
            self.result = if (self.vm.env()) |_| null else |err| err;
        }
    };
    var other: Other = .{ .vm = &vm };
    const thread = try std.Thread.spawn(.{}, Other.run, .{&other});
    thread.join();
    try testing.expectEqual(@as(?Error, error.VmFailure), other.result);
    try testing.expectEqual(@as(u32, 0), fake.attach_calls);
}
