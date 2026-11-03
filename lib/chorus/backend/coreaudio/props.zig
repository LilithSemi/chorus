//! Typed reads and writes of AudioObject and AudioUnit properties over an `Api` table.
const std = @import("std");
const api = @import("api.zig");
const map = @import("map.zig");
const Props = @This();

binding: api.Binding,

fn table(self: Props) *const api.Api {
    return self.binding.table;
}

pub fn objectValue(self: Props, comptime T: type, object: api.AudioObjectID, selector: u32, scope: u32) map.Failure!T {
    return self.elementValue(T, object, selector, scope, api.element_main);
}

pub fn elementValue(
    self: Props,
    comptime T: type,
    object: api.AudioObjectID,
    selector: u32,
    scope: u32,
    element: u32,
) map.Failure!T {
    const addr = api.address(selector, scope, element);
    var value = std.mem.zeroes(T);
    var size: u32 = @sizeOf(T);
    try map.check(self.table().objectGetPropertyData(self.binding.self, object, &addr, 0, null, &size, &value));
    if (size != @sizeOf(T)) return error.BadCall;
    return value;
}

pub fn setObjectValue(self: Props, comptime T: type, object: api.AudioObjectID, selector: u32, scope: u32, value: T) map.Failure!void {
    return self.setElementValue(T, object, selector, scope, api.element_main, value);
}

pub fn setElementValue(
    self: Props,
    comptime T: type,
    object: api.AudioObjectID,
    selector: u32,
    scope: u32,
    element: u32,
    value: T,
) map.Failure!void {
    const addr = api.address(selector, scope, element);
    try map.check(self.table().objectSetPropertyData(self.binding.self, object, &addr, 0, null, @sizeOf(T), &value));
}

pub fn hasProperty(self: Props, object: api.AudioObjectID, selector: u32, scope: u32, element: u32) bool {
    const addr = api.address(selector, scope, element);
    return self.table().objectHasProperty(self.binding.self, object, &addr);
}

pub fn isSettable(self: Props, object: api.AudioObjectID, selector: u32, scope: u32, element: u32) bool {
    const addr = api.address(selector, scope, element);
    var settable: api.Boolean = 0;
    map.check(self.table().objectIsPropertySettable(self.binding.self, object, &addr, &settable)) catch return false;
    return settable != 0;
}

/// Reads a property that is an array of `T`. The caller frees the slice.
pub fn objectList(
    self: Props,
    gpa: std.mem.Allocator,
    comptime T: type,
    object: api.AudioObjectID,
    selector: u32,
    scope: u32,
) map.Failure![]T {
    return self.elementList(gpa, T, object, selector, scope, api.element_main);
}

pub fn elementList(
    self: Props,
    gpa: std.mem.Allocator,
    comptime T: type,
    object: api.AudioObjectID,
    selector: u32,
    scope: u32,
    element: u32,
) map.Failure![]T {
    const addr = api.address(selector, scope, element);
    var size: u32 = 0;
    try map.check(self.table().objectGetPropertyDataSize(self.binding.self, object, &addr, 0, null, &size));
    const out = try gpa.alloc(T, size / @sizeOf(T));
    errdefer gpa.free(out);
    var used: u32 = @intCast(out.len * @sizeOf(T));
    if (used != 0) try map.check(self.table().objectGetPropertyData(self.binding.self, object, &addr, 0, null, &used, out.ptr));
    return gpa.realloc(out, used / @sizeOf(T));
}

/// Reads a property that is a CFString and copies it as UTF 8. The caller frees the slice.
pub fn objectString(self: Props, gpa: std.mem.Allocator, object: api.AudioObjectID, selector: u32, scope: u32) map.Failure![]u8 {
    const addr = api.address(selector, scope, api.element_main);
    var ref: ?api.CFStringRef = null;
    var size: u32 = @sizeOf(?api.CFStringRef);
    try map.check(self.table().objectGetPropertyData(self.binding.self, object, &addr, 0, null, &size, @ptrCast(&ref)));
    return self.takeString(gpa, ref);
}

/// Gives the name that a device gives to one of its data sources. The caller frees the slice.
pub fn sourceName(self: Props, gpa: std.mem.Allocator, object: api.AudioObjectID, scope: u32, item: u32) map.Failure![]u8 {
    const addr = api.address(api.Selector.data_source_name, scope, api.element_main);
    var input = item;
    var ref: ?api.CFStringRef = null;
    var translation: api.AudioValueTranslation = .{
        .mInputData = &input,
        .mInputDataSize = @sizeOf(u32),
        .mOutputData = @ptrCast(&ref),
        .mOutputDataSize = @sizeOf(?api.CFStringRef),
    };
    var size: u32 = @sizeOf(api.AudioValueTranslation);
    try map.check(self.table().objectGetPropertyData(self.binding.self, object, &addr, 0, null, &size, &translation));
    return self.takeString(gpa, ref);
}

/// Copies the string and releases the reference that the caller owns.
fn takeString(self: Props, gpa: std.mem.Allocator, ref: ?api.CFStringRef) map.Failure![]u8 {
    const string = ref orelse return error.BadCall;
    const t = self.table();
    const s = self.binding.self;
    defer t.cfRelease(s, @ptrCast(string));
    const length = t.cfStringGetLength(s, string);
    const max = t.cfStringGetMaximumSizeForEncoding(s, length, api.kCFStringEncodingUTF8);
    if (length < 0 or max < 0) return error.BadCall;
    const out = try gpa.alloc(u8, @intCast(max));
    errdefer gpa.free(out);
    var used: api.CFIndex = 0;
    const range: api.CFRange = .{ .location = 0, .length = length };
    const converted = t.cfStringGetBytes(s, string, range, api.kCFStringEncodingUTF8, 0, 0, out.ptr, max, &used);
    if (converted != length or used < 0 or used > max) return error.BadCall;
    return gpa.realloc(out, @intCast(used));
}

pub fn unitValue(
    self: Props,
    comptime T: type,
    unit: api.AudioUnit,
    id: api.AudioUnitPropertyID,
    scope: api.AudioUnitScope,
    element: api.AudioUnitElement,
) map.Failure!T {
    var value = std.mem.zeroes(T);
    var size: u32 = @sizeOf(T);
    try map.check(self.table().unitGetProperty(self.binding.self, unit, id, scope, element, &value, &size));
    return value;
}

/// Gives the raw status, for the callers that treat a refusal as a normal answer.
pub fn unitSet(
    self: Props,
    comptime T: type,
    unit: api.AudioUnit,
    id: api.AudioUnitPropertyID,
    scope: api.AudioUnitScope,
    element: api.AudioUnitElement,
    value: T,
) api.OSStatus {
    return self.table().unitSetProperty(self.binding.self, unit, id, scope, element, &value, @sizeOf(T));
}

pub fn setUnitValue(
    self: Props,
    comptime T: type,
    unit: api.AudioUnit,
    id: api.AudioUnitPropertyID,
    scope: api.AudioUnitScope,
    element: api.AudioUnitElement,
    value: T,
) map.Failure!void {
    try map.check(self.unitSet(T, unit, id, scope, element, value));
}
