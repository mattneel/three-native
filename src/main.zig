const std = @import("std");
const three_native = @import("three_native");
const window = three_native.window;
const JsRuntime = three_native.JsRuntime;

var g_js_rt: ?*JsRuntime = null;
var g_time_ms: f64 = 0;

fn onFrame(delta: f64) void {
    g_time_ms += delta * 1000.0;

    if (g_js_rt) |rt| {
        rt.tick(g_time_ms);
        const shared = rt.getSharedState();
        window.setClearColor(window.ClearColor.rgb(
            shared.clear_color[0],
            shared.clear_color[1],
            shared.clear_color[2],
        ));
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize JS runtime (pure Zig bindings)
    var runtime = try JsRuntime.init(allocator, 64 * 1024);
    defer runtime.deinit();
    runtime.makeCurrent();
    g_js_rt = &runtime;

    // Run initialization script
    try runtime.eval(
        \\print('hello from mquickjs (Zig stdlib bindings)');
        \\function animate(ts) {
        \\  var t = ts * 0.001;
        \\  var r = 0.4 + 0.4 * Math.sin(t);
        \\  var g = 0.3 + 0.3 * Math.sin(t + 2.0);
        \\  var b = 0.5 + 0.3 * Math.sin(t + 4.0);
        \\  setClearColor(r, g, b);
        \\  requestAnimationFrame(animate);
        \\}
        \\requestAnimationFrame(animate);
    , "init");

    // Set up frame callback
    window.setFrameCallback(onFrame);

    // Enable triangle rendering
    window.setDrawTriangle(true);

    // Run the window (blocks until closed)
    std.debug.print("Opening window with triangle... Press ESC to close.\n", .{});
    window.run(.{
        .width = 800,
        .height = 600,
        .title = "three-native",
    });
}
