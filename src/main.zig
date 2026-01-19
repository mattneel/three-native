const std = @import("std");
const c = @cImport({
    @cInclude("mquickjs.h");
});

// Import our C wrapper functions
extern fn js_runtime_new(mem_size: usize) ?*anyopaque;
extern fn js_runtime_free(rt: ?*anyopaque) void;
extern fn js_runtime_eval(rt: ?*anyopaque, code: [*]const u8, len: usize, filename: [*:0]const u8) c_int;

pub fn main() !void {
    const rt = js_runtime_new(64 * 1024) orelse {
        std.debug.print("Failed to create JS runtime\n", .{});
        return error.RuntimeInitFailed;
    };
    defer js_runtime_free(rt);

    const code = "print('hello from mquickjs')";
    const result = js_runtime_eval(rt, code.ptr, code.len, "main");
    if (result != 0) {
        std.debug.print("JS evaluation failed\n", .{});
        return error.EvalFailed;
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
