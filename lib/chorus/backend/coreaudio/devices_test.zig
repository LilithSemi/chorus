//! Tests of the Mixer side of the CoreAudio backend with the fake CoreAudio.
const std = @import("std");
const Mixer = @import("../../Mixer.zig");
const Backend = @import("../Backend.zig");
const ca = @import("api.zig");
const map = @import("map.zig");
const Fake = @import("fake.zig");
const bt = @import("backend_test.zig");
const Harness = bt.Harness;
const testing = std.testing;

const out = ca.Scope.output;
const in = ca.Scope.input;
const S = ca.Selector;

const ispk = ca.fourcc("ispk");
const hdpn = ca.fourcc("hdpn");
const speaker_sources = [_]Fake.Source{
    .{ .id = ispk, .name = "Internal Speakers" },
    .{ .id = hdpn, .name = "Headphones" },
    .{ .id = ca.fourcc("nono") },
    .{ .id = 7, .name = "Seven" },
};

const Events = struct {
    added: u32 = 0,
    changed: u32 = 0,
    removed: u32 = 0,
    defaults: u32 = 0,

    fn listener(self: *Events) Mixer.Listener {
        return .{ .ctx = self, .func = record };
    }

    fn record(ctx: ?*anyopaque, mixer: *const Mixer, change: Mixer.Change) void {
        _ = mixer;
        const self: *Events = @ptrCast(@alignCast(ctx.?));
        switch (change) {
            .endpoint_added => self.added += 1,
            .endpoint_changed => self.changed += 1,
            .endpoint_removed => self.removed += 1,
            .default_changed => self.defaults += 1,
            else => {},
        }
    }
};

fn sinkId(device: ca.AudioObjectID) Mixer.Id {
    return map.endpointId(device, false).?;
}

fn sourceId(device: ca.AudioObjectID) Mixer.Id {
    return map.endpointId(device, true).?;
}

fn volumeOf(h: *Harness, id: Mixer.Id) []const f32 {
    return h.ctx.mixer().endpoint(id).?.volume.slice();
}

fn dispatch(h: *Harness) !void {
    _ = try h.ctx.dispatch();
}

/// The writes of one selector, in order.
fn writes(h: *Harness, selector: u32, out_list: []Fake.SetRecord) []Fake.SetRecord {
    var n: usize = 0;
    for (h.fake.sets.items) |record| {
        if (record.selector != selector) continue;
        out_list[n] = record;
        n += 1;
    }
    return out_list[0..n];
}

fn bits(value: f32) u32 {
    return @bitCast(value);
}

test "the scan lists a sink and a source for each visible device" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.device(71).uid = "BuiltInSpeakerDevice";
    h.fake.device(71).name = "Mac mini Speakers";
    h.fake.addDevice(.{ .id = 72, .out_channels = 0, .in_channels = 2, .uid = "mic-uid", .name = "Microphone" });
    h.fake.addDevice(.{ .id = 73, .out_channels = 2, .in_channels = 1, .uid = "both-uid", .name = null });
    h.fake.addDevice(.{ .id = 74, .hidden = true, .uid = "hidden-uid" });
    h.fake.addDevice(.{ .id = 75, .uid = null });
    h.fake.addDevice(.{ .id = 76, .alive = false, .uid = "dead-uid" });
    h.fake.addDevice(.{ .id = 77, .listed = false, .uid = "unlisted-uid" });
    h.fake.addDevice(.{ .id = 78, .out_channels = 0, .in_channels = 0, .uid = "silent-uid" });
    try h.attach(.{});
    defer h.deinit();
    const m = h.ctx.mixer();
    try testing.expectEqual(@as(usize, 4), m.endpoints().len);
    const speakers = m.endpoint(sinkId(71)).?;
    try testing.expectEqual(Mixer.Kind.sink, speakers.kind);
    try testing.expectEqualStrings("BuiltInSpeakerDevice", speakers.name);
    try testing.expectEqualStrings("Mac mini Speakers", speakers.description);
    try testing.expectEqual(@as(?Mixer.Id, null), speakers.card);
    const mic = m.endpoint(sourceId(72)).?;
    try testing.expectEqual(Mixer.Kind.source, mic.kind);
    try testing.expectEqualStrings("mic-uid", mic.name);
    try testing.expectEqualStrings("Microphone", mic.description);
    // A device without a name shows its UID.
    try testing.expectEqualStrings("both-uid", m.endpoint(sinkId(73)).?.description);
    try testing.expectEqualStrings("both-uid", m.endpoint(sourceId(73)).?.name);
    try testing.expectEqual(@as(?Mixer.Id, sinkId(71)), m.default(.sink));
    try testing.expectEqual(@as(?Mixer.Id, sourceId(72)), m.default(.source));
    try testing.expectEqual(@as(i32, 0), h.fake.strings_live);
}

test "the Mixer reports what the backend can do" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const caps = h.ctx.backend.capabilities();
    try testing.expect(caps.set_default and caps.endpoint_volume and caps.ports);
    try testing.expect(!caps.stream_volume and !caps.app_streams and !caps.move_stream and !caps.profiles);
    const unknown: Mixer.Id = @fromBackingInt(9999);
    try testing.expectError(error.UnknownObject, h.ctx.backend.setVolume(.{ .endpoint = unknown }, &.{0.5}));
    try testing.expectError(error.UnknownObject, h.ctx.backend.setMute(.{ .endpoint = unknown }, true));
    try testing.expectError(error.UnknownObject, h.ctx.backend.setPort(unknown, 1));
    try testing.expectError(error.UnknownObject, h.ctx.backend.setDefault(.sink, unknown));
    try testing.expectError(error.Unsupported, h.ctx.backend.setVolume(.{ .stream = unknown }, &.{0.5}));
    try testing.expectError(error.Unsupported, h.ctx.backend.moveStream(unknown, unknown));
    try testing.expectError(error.Unsupported, h.ctx.backend.setProfile(unknown, 0));
}

test "a device with a vold per channel shows one linear level per channel" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.addControl(.{ .object = 71, .scope = out, .element = 1, .db = -10 });
    h.fake.addControl(.{ .object = 71, .scope = out, .element = 2, .db = -20 });
    try h.attach(.{});
    defer h.deinit();
    const id = sinkId(71);
    const levels = volumeOf(&h, id);
    try testing.expectEqual(@as(usize, 2), levels.len);
    try testing.expectApproxEqAbs(@as(f32, 0.31622776), levels[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.1), levels[1], 1e-6);

    try h.ctx.mixer().setVolume(.{ .endpoint = id }, .{ .channels = &.{0.5} });
    var buf: [8]Fake.SetRecord = undefined;
    const sets = writes(&h, S.volume_decibels, &buf);
    try testing.expectEqual(@as(usize, 2), sets.len);
    try testing.expectEqual(@as(u32, 1), sets[0].element);
    try testing.expectEqual(@as(u32, 2), sets[1].element);
    try testing.expectEqual(out, sets[0].scope);
    try testing.expectApproxEqAbs(@as(f32, -6.0206), @as(f32, @bitCast(sets[0].value)), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, -6.0206), @as(f32, @bitCast(sets[1].value)), 1e-3);
    // The Mixer shows the new value after the change notification.
    try testing.expectApproxEqAbs(@as(f32, 0.31622776), volumeOf(&h, id)[0], 1e-6);
    try dispatch(&h);
    try testing.expectApproxEqAbs(@as(f32, 0.5), volumeOf(&h, id)[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), volumeOf(&h, id)[1], 1e-4);

    try h.ctx.mixer().setVolume(.{ .endpoint = id }, .{ .channels = &.{ 0.0, 2.0 } });
    try dispatch(&h);
    try testing.expectEqual(@as(f32, 0), volumeOf(&h, id)[0]);
    // Above the range the control stays at 0 dB.
    try testing.expectApproxEqAbs(@as(f32, 1.0), volumeOf(&h, id)[1], 1e-6);
    try testing.expectEqual(@as(f32, -63.5), h.fake.controlAt(71, out, 1).db.?);
}

test "the lowest level of the range reads as silence" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.addControl(.{ .object = 71, .scope = out, .element = 1, .db = -63.5 });
    h.fake.addControl(.{ .object = 71, .scope = out, .element = 2, .db = -63.4 });
    try h.attach(.{});
    defer h.deinit();
    const levels = volumeOf(&h, sinkId(71));
    try testing.expectEqual(@as(f32, 0), levels[0]);
    try testing.expect(levels[1] > 0 and levels[1] < 0.001);
}

test "a device with one main vold shows the same level on every channel" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.addControl(.{ .object = 71, .scope = out, .element = 0, .db = -6.0206 });
    try h.attach(.{});
    defer h.deinit();
    const id = sinkId(71);
    try testing.expectEqual(@as(usize, 2), volumeOf(&h, id).len);
    try testing.expectApproxEqAbs(@as(f32, 0.5), volumeOf(&h, id)[1], 1e-4);
    try h.ctx.mixer().setVolume(.{ .endpoint = id }, .{ .channels = &.{ 0.25, 0.75 } });
    var buf: [8]Fake.SetRecord = undefined;
    const sets = writes(&h, S.volume_decibels, &buf);
    try testing.expectEqual(@as(usize, 1), sets.len);
    try testing.expectEqual(@as(u32, 0), sets[0].element);
    try testing.expectApproxEqAbs(@as(f32, -6.0206), @as(f32, @bitCast(sets[0].value)), 1e-3);
}

test "vmvc is the volume when no element has vold" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.addControl(.{ .object = 71, .scope = out, .element = 0, .scalar = 0.5 });
    try h.attach(.{});
    defer h.deinit();
    const id = sinkId(71);
    try testing.expectApproxEqAbs(@as(f32, 0.125), volumeOf(&h, id)[0], 1e-6);
    try h.ctx.mixer().setVolume(.{ .endpoint = id }, .{ .channels = &.{0.027} });
    var buf: [8]Fake.SetRecord = undefined;
    try testing.expectEqual(@as(usize, 0), writes(&h, S.volume_decibels, &buf).len);
    const sets = writes(&h, S.virtual_main_volume, &buf);
    try testing.expectEqual(@as(usize, 1), sets.len);
    try testing.expectApproxEqAbs(@as(f32, 0.3), @as(f32, @bitCast(sets[0].value)), 1e-5);
    try dispatch(&h);
    try testing.expectApproxEqAbs(@as(f32, 0.027), volumeOf(&h, id)[0], 1e-5);
    h.fake.changeScalar(71, out, 0, 1.0);
    try dispatch(&h);
    try testing.expectEqual(@as(f32, 1.0), volumeOf(&h, id)[1]);
}

test "vold wins over vmvc and the missing range is no volume" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.addControl(.{ .object = 71, .scope = out, .element = 0, .db = -20, .scalar = 0.9 });
    try h.attach(.{});
    defer h.deinit();
    try testing.expectApproxEqAbs(@as(f32, 0.1), volumeOf(&h, sinkId(71))[0], 1e-6);
}

test "a device without a volume control has no volume and no mute" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const id = sinkId(71);
    try testing.expectEqual(@as(usize, 0), volumeOf(&h, id).len);
    try testing.expectError(error.Unsupported, h.ctx.mixer().setVolume(.{ .endpoint = id }, .{ .channels = &.{0.5} }));
    try testing.expectError(error.Unsupported, h.ctx.mixer().setMute(.{ .endpoint = id }, true));
    try testing.expectEqual(@as(usize, 0), h.fake.sets.items.len);
    try testing.expectEqual(@as(usize, 4), h.fake.objectListenerCount());
}

test "the backend refuses a volume of the wrong size and a failed write" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.addControl(.{ .object = 71, .scope = out, .element = 1, .db = -10 });
    h.fake.addControl(.{ .object = 71, .scope = out, .element = 2, .db = -10 });
    try h.attach(.{});
    defer h.deinit();
    const id = sinkId(71);
    try testing.expectError(error.InvalidVolume, h.ctx.backend.setVolume(.{ .endpoint = id }, &.{ 0.1, 0.2, 0.3 }));
    h.fake.fail_set = ca.Status.illegal_operation;
    try testing.expectError(error.Unsupported, h.ctx.mixer().setVolume(.{ .endpoint = id }, .{ .channels = &.{0.5} }));
    h.fake.fail_set = ca.Status.mem_full;
    try testing.expectError(error.OutOfMemory, h.ctx.mixer().setVolume(.{ .endpoint = id }, .{ .channels = &.{0.5} }));
    h.fake.fail_set = null;
    h.fake.controlAt(71, out, 2).settable = false;
    try testing.expectError(error.Unsupported, h.ctx.mixer().setVolume(.{ .endpoint = id }, .{ .channels = &.{0.5} }));
    try testing.expectEqual(@as(f32, -10), h.fake.controlAt(71, out, 2).db.?);
}

test "a device with more than 64 channels shows 64 levels" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.device(71).out_channels = 70;
    h.fake.addControl(.{ .object = 71, .scope = out, .element = 0, .db = -20 });
    try h.attach(.{});
    defer h.deinit();
    const id = sinkId(71);
    try testing.expectEqual(@as(usize, Mixer.max_channels), volumeOf(&h, id).len);
    try h.ctx.mixer().setVolume(.{ .endpoint = id }, .{ .channels = &.{0.5} });
    var buf: [8]Fake.SetRecord = undefined;
    try testing.expectEqual(@as(usize, 1), writes(&h, S.volume_decibels, &buf).len);
}

test "mute reads and writes the main element" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.addControl(.{ .object = 71, .scope = out, .element = 0, .mute = false });
    try h.attach(.{});
    defer h.deinit();
    const id = sinkId(71);
    const m = h.ctx.mixer();
    try testing.expect(!m.endpoint(id).?.mute);
    try m.setMute(.{ .endpoint = id }, true);
    var buf: [8]Fake.SetRecord = undefined;
    const sets = writes(&h, S.mute, &buf);
    try testing.expectEqual(@as(usize, 1), sets.len);
    try testing.expectEqual(@as(u32, 0), sets[0].element);
    try testing.expectEqual(@as(u32, 1), sets[0].value);
    try dispatch(&h);
    try testing.expect(m.endpoint(id).?.mute);
    h.fake.changeMute(71, out, 0, false);
    try dispatch(&h);
    try testing.expect(!m.endpoint(id).?.mute);
}

test "mute on every channel element counts as muted only when all are muted" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.addControl(.{ .object = 71, .scope = out, .element = 1, .mute = true });
    h.fake.addControl(.{ .object = 71, .scope = out, .element = 2, .mute = false });
    try h.attach(.{});
    defer h.deinit();
    const id = sinkId(71);
    const m = h.ctx.mixer();
    try testing.expect(!m.endpoint(id).?.mute);
    try m.setMute(.{ .endpoint = id }, true);
    var buf: [8]Fake.SetRecord = undefined;
    const sets = writes(&h, S.mute, &buf);
    try testing.expectEqual(@as(usize, 2), sets.len);
    try testing.expectEqual(@as(u32, 2), sets[1].element);
    try dispatch(&h);
    try testing.expect(m.endpoint(id).?.mute);
    try m.setMute(.{ .endpoint = id }, false);
    try dispatch(&h);
    try testing.expect(!m.endpoint(id).?.mute);
}

test "data sources become ports and the current source is the active port" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.addSources(.{ .object = 71, .scope = out, .items = &speaker_sources, .current = hdpn });
    try h.attach(.{});
    defer h.deinit();
    const id = sinkId(71);
    const m = h.ctx.mixer();
    const ports = m.endpoint(id).?.ports;
    try testing.expectEqual(@as(usize, 4), ports.len);
    try testing.expectEqual(ispk, ports[0].index);
    try testing.expectEqualStrings("ispk", ports[0].name);
    try testing.expectEqualStrings("Internal Speakers", ports[0].description);
    // A source without a name shows its code, and a code that is no text shows its number.
    try testing.expectEqualStrings("nono", ports[2].description);
    try testing.expectEqualStrings("7", ports[3].name);
    try testing.expectEqualStrings("Seven", ports[3].description);
    try testing.expectEqual(@as(?u32, hdpn), m.endpoint(id).?.active_port);
    try testing.expectEqual(@as(i32, 0), h.fake.strings_live);

    try m.setPort(id, ispk);
    var buf: [8]Fake.SetRecord = undefined;
    const sets = writes(&h, S.data_source, &buf);
    try testing.expectEqual(@as(usize, 1), sets.len);
    try testing.expectEqual(ispk, sets[0].value);
    try testing.expectEqual(out, sets[0].scope);
    try dispatch(&h);
    try testing.expectEqual(@as(?u32, ispk), m.endpoint(id).?.active_port);
    h.fake.changeSource(71, out, 7);
    try dispatch(&h);
    try testing.expectEqual(@as(?u32, 7), m.endpoint(id).?.active_port);
    try testing.expectError(error.InvalidIndex, m.setPort(id, 12345));
}

test "a data source that cannot be set is unsupported" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.addSources(.{ .object = 71, .scope = out, .items = speaker_sources[0..1], .current = ispk, .settable = false });
    try h.attach(.{});
    defer h.deinit();
    const id = sinkId(71);
    try testing.expectEqual(@as(usize, 1), h.ctx.mixer().endpoint(id).?.ports.len);
    try testing.expectError(error.Unsupported, h.ctx.mixer().setPort(id, ispk));
    try testing.expectEqual(@as(usize, 0), h.fake.sets.items.len);
}

test "input sources belong to the source endpoint" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.addDevice(.{ .id = 72, .out_channels = 0, .in_channels = 2, .uid = "mic-uid", .name = "Mic" });
    h.fake.addSources(.{ .object = 72, .scope = in, .items = speaker_sources[1..2], .current = hdpn });
    h.fake.addControl(.{ .object = 72, .scope = in, .element = 0, .db = -3, .mute = false });
    try h.attach(.{});
    defer h.deinit();
    const m = h.ctx.mixer();
    try testing.expectEqual(@as(usize, 1), m.endpoint(sourceId(72)).?.ports.len);
    try testing.expectEqual(@as(usize, 0), m.endpoint(sinkId(71)).?.ports.len);
    try m.setMute(.{ .endpoint = sourceId(72) }, true);
    var buf: [8]Fake.SetRecord = undefined;
    try testing.expectEqual(in, writes(&h, S.mute, &buf)[0].scope);
    try m.setVolume(.{ .endpoint = sourceId(72) }, .{ .channels = &.{0.5} });
    try testing.expectEqual(in, writes(&h, S.volume_decibels, &buf)[0].scope);
}

test "setDefault sets the default output and the default input of the system" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.addDevice(.{ .id = 72, .out_channels = 0, .in_channels = 2, .uid = "mic-a", .name = "Mic A" });
    h.fake.addDevice(.{ .id = 73, .out_channels = 0, .in_channels = 2, .uid = "mic-b", .name = "Mic B" });
    h.fake.addDevice(.{ .id = 74, .uid = "speakers-b", .name = "Speakers B" });
    try h.attach(.{});
    defer h.deinit();
    const m = h.ctx.mixer();
    try testing.expectEqual(@as(usize, 0), h.fake.sets.items.len);
    try m.setDefault(.sink, sinkId(74));
    try testing.expectEqual(@as(usize, 1), h.fake.sets.items.len);
    try testing.expectEqual(S.default_output_device, h.fake.sets.items[0].selector);
    try testing.expectEqual(@as(u32, 74), h.fake.sets.items[0].value);
    try testing.expectEqual(@as(?Mixer.Id, sinkId(71)), m.default(.sink));
    try dispatch(&h);
    try testing.expectEqual(@as(?Mixer.Id, sinkId(74)), m.default(.sink));
    try m.setDefault(.source, sourceId(73));
    try testing.expectEqual(S.default_input_device, h.fake.sets.items[1].selector);
    try testing.expectEqual(@as(u32, 73), h.fake.sets.items[1].value);
    try dispatch(&h);
    try testing.expectEqual(@as(?Mixer.Id, sourceId(73)), m.default(.source));
    // A source is no sink.
    try testing.expectError(error.UnknownObject, m.setDefault(.sink, sourceId(73)));
    try testing.expectError(error.UnknownObject, h.ctx.backend.setDefault(.sink, sourceId(73)));
    try testing.expectEqual(@as(usize, 2), h.fake.sets.items.len);
    h.fake.fail_set = ca.Status.permissions;
    try testing.expectError(error.Unsupported, m.setDefault(.sink, sinkId(71)));
}

test "a stream that follows the default shows the default sink as its endpoint" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: bt.Tone = .{};
    _ = try h.open(.playback, &tone);
    try testing.expectEqual(@as(?Mixer.Id, sinkId(71)), h.ctx.mixer().streams()[0].endpoint);
}

test "a new device and a removed device change the endpoints and nothing else" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.addControl(.{ .object = 71, .scope = out, .element = 0, .db = -10 });
    try h.attach(.{});
    defer h.deinit();
    const m = h.ctx.mixer();
    var events: Events = .{};
    try m.listen(events.listener());
    h.fake.addDevice(.{ .id = 73, .listed = false, .uid = "usb-uid", .name = "USB", .in_channels = 1 });
    h.fake.addControl(.{ .object = 73, .scope = out, .element = 0, .db = -5 });
    try testing.expectEqual(@as(usize, 6), h.fake.objectListenerCount());
    h.fake.setListed(73, true);
    try dispatch(&h);
    try testing.expectEqual(@as(usize, 3), m.endpoints().len);
    try testing.expectEqual(@as(u32, 2), events.added);
    try testing.expectEqual(@as(u32, 0), events.changed);
    try testing.expectEqual(@as(u32, 0), events.removed);
    try testing.expectEqualStrings("usb-uid", m.endpoint(sinkId(73)).?.name);
    try testing.expectEqual(@as(usize, 8), h.fake.objectListenerCount());
    // Another device list notification finds nothing new and keeps one listener per control.
    h.fake.setListed(73, true);
    try dispatch(&h);
    try testing.expectEqual(@as(u32, 2), events.added);
    try testing.expectEqual(@as(u32, 0), events.changed);
    try testing.expectEqual(@as(usize, 8), h.fake.objectListenerCount());

    h.fake.setDefaultOut(73);
    try dispatch(&h);
    try testing.expectEqual(@as(?Mixer.Id, sinkId(73)), m.default(.sink));
    h.fake.removeDevice(73);
    try dispatch(&h);
    try testing.expectEqual(@as(usize, 1), m.endpoints().len);
    try testing.expectEqual(@as(u32, 2), events.removed);
    try testing.expectEqual(@as(?Mixer.Id, sinkId(71)), m.default(.sink));
    try testing.expectEqual(@as(?Mixer.Id, null), m.default(.source));
    try testing.expectEqual(@as(usize, 6), h.fake.objectListenerCount());
    try testing.expectEqual(@as(i32, 0), h.fake.strings_live);
}

test "listeners of the controls are removed when the rescan drops them and when the backend ends" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.addControl(.{ .object = 71, .scope = out, .element = 1, .db = -10 });
    h.fake.addControl(.{ .object = 71, .scope = out, .element = 2, .db = -10 });
    h.fake.addControl(.{ .object = 71, .scope = out, .element = 0, .mute = false });
    h.fake.addSources(.{ .object = 71, .scope = out, .items = speaker_sources[0..2], .current = ispk });
    try h.attach(.{});
    // Four system listeners, a vold and a volm per channel, one mute and one data source.
    try testing.expectEqual(@as(usize, 4 + 4 + 1 + 1), h.fake.objectListenerCount());
    const before = h.fake.count(.add_object_listener);
    h.fake.setListed(71, true);
    try dispatch(&h);
    try testing.expectEqual(@as(usize, 10), h.fake.objectListenerCount());
    try testing.expectEqual(@as(u32, 6), h.fake.count(.add_object_listener) - before);
    try testing.expectEqual(@as(u32, 6), h.fake.count(.remove_object_listener));
    h.ctx.deinit();
    try testing.expectEqual(@as(usize, 0), h.fake.listenerCount());
    try testing.expectEqual(@as(u32, 0), h.fake.bad_uses);
    try testing.expectEqual(@as(u32, 0), h.fake.violations.load(.monotonic));
    h.fake.deinit();
}

test "a change from another program reaches the Mixer once" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.addControl(.{ .object = 71, .scope = out, .element = 0, .db = -10, .mute = false });
    try h.attach(.{});
    defer h.deinit();
    const m = h.ctx.mixer();
    const id = sinkId(71);
    var events: Events = .{};
    try m.listen(events.listener());
    h.fake.changeDb(71, out, 0, -20);
    try testing.expect(h.ctx.fd() != null);
    try dispatch(&h);
    try testing.expectApproxEqAbs(@as(f32, 0.1), volumeOf(&h, id)[0], 1e-6);
    try testing.expectEqual(@as(u32, 1), events.changed);
    try dispatch(&h);
    try testing.expectEqual(@as(u32, 1), events.changed);
    h.fake.changeMute(71, out, 0, true);
    try dispatch(&h);
    try testing.expect(m.endpoint(id).?.mute);
    try testing.expectEqual(@as(u32, 2), events.changed);
    try testing.expectEqual(@as(u32, 0), events.added);
}

test "a coreaudiod restart empties the endpoints and the reconnect fills them again" {
    if (comptime !bt.usable) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.fake.addControl(.{ .object = 71, .scope = out, .element = 0, .db = -10 });
    try h.attach(.{});
    defer h.deinit();
    const m = h.ctx.mixer();
    try testing.expectEqual(@as(usize, 1), m.endpoints().len);
    h.fake.restartService();
    try testing.expectEqual(Backend.Event.disconnected, try h.ctx.dispatch());
    try testing.expectEqual(@as(usize, 0), m.endpoints().len);
    try testing.expectEqual(@as(?Mixer.Id, null), m.default(.sink));
    try testing.expectEqual(@as(usize, 0), h.fake.listenerCount());
    try testing.expectError(error.UnknownObject, h.ctx.backend.setVolume(.{ .endpoint = sinkId(71) }, &.{0.5}));
    try h.ctx.reconnect();
    try testing.expectEqual(@as(usize, 1), m.endpoints().len);
    try testing.expectEqual(@as(?Mixer.Id, sinkId(71)), m.default(.sink));
    try testing.expectEqual(@as(usize, 4 + 2), h.fake.objectListenerCount());
    try testing.expectApproxEqAbs(@as(f32, 0.31622776), volumeOf(&h, sinkId(71))[0], 1e-6);
}
