//! Root of the wasm32-freestanding check build. It makes the web backend analyze the real table.
//! The page keeps the Context pointer as a number and gives it back to `chorusTick`.
const std = @import("std");
const chorus = @import("chorus");

fn render(ctx: ?*anyopaque, stream: *chorus.Stream, buffer: chorus.Stream.Buffer) chorus.Stream.Status {
    _ = ctx;
    _ = stream;
    @memset(buffer.bytes, 0);
    return .@"continue";
}

export fn chorusStart() ?*chorus.Context {
    const ctx = chorus.Context.init(std.heap.wasm_allocator, std.Io.failing, .{
        .app_name = "check",
        .backend = .web,
    }) catch return null;
    const stream = ctx.openStream(.{
        .direction = .playback,
        .format = .{ .sample = .f32, .rate = 48000, .channels = .stereo },
        .callback = .{ .ctx = null, .func = render },
    }) catch {
        ctx.deinit();
        return null;
    };
    stream.start() catch {
        ctx.deinit();
        return null;
    };
    return ctx;
}

export fn chorusTick(ctx: *chorus.Context) u32 {
    _ = ctx.dispatch() catch return 0;
    return ctx.timeoutMs() orelse 20;
}
