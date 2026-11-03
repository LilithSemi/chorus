//! Test helper: runs a test body in a forked child process.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const testing = std.testing;

const exit_ok = 0;
const exit_failed = 1;
const exit_skipped = 2;

/// Runs `body` in a forked child so process wide changes, such as the RTTIME limit or the
/// scheduler of a thread, stay out of the test binary. The child exits with a code that this
/// function checks.
pub fn inChild(comptime body: fn () anyerror!void) !void {
    if (comptime builtin.single_threaded) return error.SkipZigTest;
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
    if (rc == 0) {
        const code: u8 = if (body()) (if (testing.allocator_instance.deinit() == 0) exit_ok else exit_failed) else |err| switch (err) {
            error.SkipZigTest => exit_skipped,
            else => blk: {
                std.debug.print("child failed: {s}\n", .{@errorName(err)});
                break :blk exit_failed;
            },
        };
        linux.exit_group(code);
    }
    var status: i32 = 0;
    var wrc = linux.waitpid(@intCast(rc), &status, 0);
    while (linux.errno(wrc) == .INTR) wrc = linux.waitpid(@intCast(rc), &status, 0);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(wrc));
    try testing.expect(linux.W.IFEXITED(@bitCast(status)));
    const code = linux.W.EXITSTATUS(@bitCast(status));
    if (code == exit_skipped) return error.SkipZigTest;
    try testing.expectEqual(@as(u8, exit_ok), code);
}
