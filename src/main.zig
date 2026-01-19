const std = @import("std");
const three_native = @import("three_native");
const window = three_native.window;

// JS runtime (will be integrated with window loop in later phases)
extern fn js_runtime_new(mem_size: usize) ?*anyopaque;
extern fn js_runtime_free(rt: ?*anyopaque) void;
extern fn js_runtime_eval(rt: ?*anyopaque, code: [*]const u8, len: usize, filename: [*:0]const u8) c_int;

var g_js_rt: ?*anyopaque = null;
var g_time: f64 = 0;

fn onFrame(delta: f64) void {
    g_time += delta;

    // Cycle clear color based on time (for demo)
    const r: f32 = @floatCast(0.5 + 0.5 * @sin(g_time));
    const g: f32 = @floatCast(0.5 + 0.5 * @sin(g_time + 2.0));
    const b: f32 = @floatCast(0.5 + 0.5 * @sin(g_time + 4.0));
    window.setClearColor(window.ClearColor.rgb(r, g, b));
}

pub fn main() !void {
    // Initialize JS runtime
    g_js_rt = js_runtime_new(64 * 1024) orelse {
        std.debug.print("Failed to create JS runtime\n", .{});
        return error.RuntimeInitFailed;
    };
    defer js_runtime_free(g_js_rt);

    // Print hello from JS
    const code = "print('hello from mquickjs')";
    const result = js_runtime_eval(g_js_rt, code.ptr, code.len, "main");
    if (result != 0) {
        std.debug.print("JS evaluation failed\n", .{});
        return error.EvalFailed;
    }

    // Set up frame callback
    window.setFrameCallback(onFrame);

    // Run the window (blocks until closed)
    std.debug.print("Opening window... Press ESC to close.\n", .{});
    window.run(.{
        .width = 800,
        .height = 600,
        .title = "three-native",
    });
}
