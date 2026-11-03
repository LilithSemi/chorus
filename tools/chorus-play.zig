//! A small program to check by ear that Chorus makes sound.
const std = @import("std");
const chorus = @import("chorus");
const codec = @import("codec");

const Context = chorus.Context;
const Player = chorus.Player;
const Stream = chorus.Stream;
const Mixer = chorus.Mixer;

const usage =
    \\usage: chorus-play [--list] [--backend NAME] [--device ID] [--gain G] [--loop] [FILE]
    \\  FILE plays a WAV, FLAC, Ogg Vorbis or Ogg Opus file. With no FILE a 2 s tone plays.
    \\  --list shows the backend and the endpoints. --backend is auto, pipewire, coreaudio,
    \\  aaudio, web or null. --device takes an endpoint id from --list.
    \\
;

const no_restore = [_][2][]const u8{
    .{ "state.restore-props", "false" },
    .{ "state.restore-target", "false" },
};

const tone_rate = 48000;
const tone_hz = 440.0;
const tone_seconds = 2;
const tone_fade_frames = 960;
const settle_ms = 300;
const idle_poll_ms = 100;

const Args = struct {
    file: ?[]const u8 = null,
    list: bool = false,
    help: bool = false,
    loop: bool = false,
    backend: Context.BackendChoice = .auto,
    device: ?Mixer.Id = null,
    gain: ?f32 = null,
};

const ArgsError = error{ BadArgument, MissingValue, OutOfMemory };

const RunError = ArgsError || Context.InitError || Context.ReconnectError || Player.InitError ||
    Player.StreamError || Stream.StartError || Stream.OpenError || std.Io.File.OpenError ||
    std.Io.Writer.Error || std.posix.PollError || std.process.Args.Iterator.InitError ||
    std.Io.Cancelable || codec.InitError || error{PlaybackFailed};

pub fn main(init: std.process.Init) u8 {
    const args = parseArgs(init) catch |err| {
        std.debug.print("chorus-play: bad arguments ({t})\n{s}", .{ err, usage });
        return 1;
    };
    if (args.help) {
        std.debug.print("{s}", .{usage});
        return 0;
    }
    run(init, args) catch |err| {
        std.debug.print("chorus-play: {t}\n", .{err});
        return 1;
    };
    return 0;
}

fn parseArgs(init: std.process.Init) (ArgsError || std.process.Args.Iterator.InitError)!Args {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.skip();
    var args: Args = .{};
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            args.help = true;
        } else if (std.mem.eql(u8, arg, "--list")) {
            args.list = true;
        } else if (std.mem.eql(u8, arg, "--loop")) {
            args.loop = true;
        } else if (std.mem.eql(u8, arg, "--backend")) {
            const value = it.next() orelse return error.MissingValue;
            args.backend = std.meta.stringToEnum(Context.BackendChoice, value) orelse return error.BadArgument;
        } else if (std.mem.eql(u8, arg, "--device")) {
            const value = it.next() orelse return error.MissingValue;
            const id = std.fmt.parseInt(u32, value, 10) catch return error.BadArgument;
            args.device = @fromBackingInt(@intCast(id));
        } else if (std.mem.eql(u8, arg, "--gain")) {
            const value = it.next() orelse return error.MissingValue;
            const gain = std.fmt.parseFloat(f32, value) catch return error.BadArgument;
            if (!std.math.isFinite(gain) or gain < 0) return error.BadArgument;
            args.gain = gain;
        } else if (arg.len > 0 and arg[0] == '-') {
            return error.BadArgument;
        } else if (args.file == null) {
            args.file = init.arena.allocator().dupe(u8, arg) catch return error.OutOfMemory;
        } else {
            return error.BadArgument;
        }
    }
    return args;
}

fn run(init: std.process.Init, args: Args) RunError!void {
    const io = init.io;
    var options: Context.Options = .{
        .app_name = "chorus-play",
        .environ = init.environ_map,
        .backend = args.backend,
    };
    if (comptime chorus.backend.Backend.pipewire_enabled) {
        options.pipewire_backend.stream_props = &no_restore;
    }
    const ctx = try Context.init(init.gpa, io, options);
    defer ctx.deinit();

    var out_buffer: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buffer);
    const w = &out.interface;

    try w.print("backend: {t}\n", .{ctx.info().backend});
    if (ctx.info().backend == .null) {
        try w.writeAll("warning: this is the null backend, so no audio is heard\n");
    }
    try w.flush();

    if (args.list) {
        try settle(ctx);
        try printEndpoints(w, ctx.mixer());
        try w.flush();
        return;
    }
    if (args.file) |path| {
        try playFile(io, ctx, path, args);
    } else {
        try playTone(ctx, args);
    }
}

/// Gives the backend a short time to report its endpoints.
fn settle(ctx: *Context) RunError!void {
    var waited: u32 = 0;
    while (waited < settle_ms) : (waited += idle_poll_ms) {
        try wait(ctx, idle_poll_ms);
        try pump(ctx);
    }
}

fn printEndpoints(w: *std.Io.Writer, mixer: *Mixer) std.Io.Writer.Error!void {
    for (mixer.endpoints()) |endpoint| {
        const direction = switch (endpoint.kind) {
            .sink => "playback",
            .source => "capture",
        };
        const default_kind: Mixer.Kind = endpoint.kind;
        const mark = if (mixer.default(default_kind) == endpoint.id) " default" else "";
        try w.print("{d}\t{s}\t{s}\t{s}{s}", .{
            @backingInt(endpoint.id), endpoint.name, endpoint.description, direction, mark,
        });
        const volume = endpoint.volume.slice();
        if (volume.len > 0) {
            try w.writeAll("\tvolume");
            for (volume) |value| try w.print(" {d:.2}", .{value});
            try w.print("\tmute {s}", .{if (endpoint.mute) "yes" else "no"});
        }
        try w.writeByte('\n');
    }
}

/// Waits for the backend fd or the timeout, at most `limit_ms`.
fn wait(ctx: *Context, limit_ms: u32) std.posix.PollError!void {
    const timeout = @min(ctx.timeoutMs() orelse limit_ms, limit_ms);
    var fds: [1]std.posix.pollfd = undefined;
    var count: usize = 0;
    if (ctx.fd()) |fd| {
        fds[0] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
        count = 1;
    }
    _ = try std.posix.poll(fds[0..count], @intCast(timeout));
}

fn pump(ctx: *Context) (Context.ReconnectError || chorus.backend.Backend.DispatchError)!void {
    const event = try ctx.dispatch();
    if (event == .disconnected) try ctx.reconnect();
}

const Watch = struct {
    ended: bool = false,
    failed: bool = false,

    fn listen(raw: ?*anyopaque, player: *Player, event: Player.Event) void {
        _ = player;
        const self: *Watch = @ptrCast(@alignCast(raw.?));
        switch (event) {
            .ended => self.ended = true,
            .failed => self.failed = true,
        }
    }
};

fn playFile(
    io: std.Io,
    ctx: *Context,
    path: []const u8,
    args: Args,
) RunError!void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);

    const player = try Player.init(ctx, .{ .device = args.device });
    defer player.deinit();
    var watch: Watch = .{};
    player.listen(.{ .ctx = &watch, .func = Watch.listen });
    _ = try player.stream(.{ .file = &reader }, .{ .gain = args.gain orelse 1, .loop = args.loop });

    while (!watch.ended) {
        try wait(ctx, idle_poll_ms);
        try pump(ctx);
    }
    if (watch.failed) return error.PlaybackFailed;
}

const Tone = struct {
    frame: u64 = 0,
    gain: f32,

    fn render(raw: ?*anyopaque, stream: *Stream, buffer: Stream.Buffer) Stream.Status {
        _ = stream;
        const self: *Tone = @ptrCast(@alignCast(raw.?));
        const total: u64 = tone_rate * tone_seconds;
        const channels = buffer.format.channels.count;
        const sample_bytes = @sizeOf(f32);
        var i: usize = 0;
        while (i < buffer.frames) : (i += 1) {
            var value: f32 = 0;
            if (self.frame < total) {
                const turns = @as(f64, @floatFromInt(self.frame)) * tone_hz / tone_rate;
                const wave: f32 = @floatCast(@sin(turns * std.math.tau));
                const edge = @min(self.frame, total - 1 - self.frame);
                const fade: f32 = @min(1.0, @as(f32, @floatFromInt(edge)) / tone_fade_frames);
                value = wave * fade * self.gain;
            }
            self.frame += 1;
            for (0..channels) |c| {
                const at = (i * channels + c) * sample_bytes;
                @memcpy(buffer.bytes[at..][0..sample_bytes], std.mem.asBytes(&value));
            }
        }
        return if (self.frame >= total) .drain else .@"continue";
    }
};

fn playTone(ctx: *Context, args: Args) RunError!void {
    var tone: Tone = .{ .gain = args.gain orelse 0.2 };
    const stream = try ctx.openStream(.{
        .direction = .playback,
        .format = .{ .sample = .f32, .rate = tone_rate, .channels = .stereo },
        .device = args.device,
        .callback = .{ .ctx = &tone, .func = Tone.render },
    });
    defer stream.close();
    try stream.start();
    while (stream.state() != .stopped) {
        try wait(ctx, idle_poll_ms);
        try pump(ctx);
    }
}
