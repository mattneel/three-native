//! JavaScript global bindings for three-native
//!
//! Exposes native functions to the JS runtime.
//! This is Phase 1.0 - type definitions only.

const std = @import("std");
const testing = std.testing;
const window = @import("../platform/window.zig");

/// Result of evaluating JS code
pub const EvalResult = union(enum) {
    success: void,
    js_error: []const u8,
    native_error: anyerror,
};

/// Callback type for requestAnimationFrame
pub const FrameCallback = *const fn (timestamp_ms: f64) void;

/// Global state shared between JS and native
pub const GlobalState = struct {
    /// Current clear color (set via setClearColor)
    clear_color: window.ClearColor,
    /// Frame callback (set via requestAnimationFrame)
    frame_callback: ?FrameCallback,
    /// Current timestamp in milliseconds
    timestamp_ms: f64,
    /// Performance.now() start time
    perf_start_ns: i128,

    const Self = @This();

    pub fn init() Self {
        return .{
            .clear_color = window.ClearColor.rgb(0, 0, 0),
            .frame_callback = null,
            .timestamp_ms = 0,
            .perf_start_ns = std.time.nanoTimestamp(),
        };
    }

    /// Get performance.now() value in milliseconds
    pub fn performanceNow(self: *const Self) f64 {
        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - self.perf_start_ns;
        return @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    }

    /// Set clear color from JS (setClearColor(r, g, b))
    pub fn setClearColor(self: *Self, r: f32, g: f32, b: f32) void {
        self.clear_color = window.ClearColor.rgb(r, g, b);
    }

    /// Register frame callback (requestAnimationFrame)
    pub fn requestAnimationFrame(self: *Self, callback: FrameCallback) void {
        self.frame_callback = callback;
    }

    /// Cancel frame callback (cancelAnimationFrame)
    pub fn cancelAnimationFrame(self: *Self) void {
        self.frame_callback = null;
    }
};

/// JS function binding descriptor
pub const JsBinding = struct {
    /// Function name in JS
    name: [:0]const u8,
    /// Number of arguments
    arg_count: u8,
    /// Description for debugging
    description: []const u8,
};

/// List of JS functions we expose
pub const js_bindings = [_]JsBinding{
    .{
        .name = "setClearColor",
        .arg_count = 3,
        .description = "Set the clear color (r, g, b) - values 0.0 to 1.0",
    },
    .{
        .name = "requestAnimationFrame",
        .arg_count = 1,
        .description = "Request a callback before next repaint",
    },
    .{
        .name = "cancelAnimationFrame",
        .arg_count = 0,
        .description = "Cancel a pending animation frame callback",
    },
};

/// Console binding for console.log, console.error, etc.
pub const ConsoleBinding = struct {
    pub const Level = enum {
        log,
        info,
        warn,
        @"error",
        debug,
    };

    /// Write to console at given level
    pub fn write(level: Level, message: []const u8) void {
        const prefix = switch (level) {
            .log => "[LOG]",
            .info => "[INFO]",
            .warn => "[WARN]",
            .@"error" => "[ERROR]",
            .debug => "[DEBUG]",
        };
        std.debug.print("{s} {s}\n", .{ prefix, message });
    }
};

// =============================================================================
// Tests
// =============================================================================

test "GlobalState initializes with defaults" {
    const state = GlobalState.init();
    try testing.expectApproxEqAbs(@as(f32, 0.0), state.clear_color.r, 0.001);
    try testing.expect(state.frame_callback == null);
    try testing.expectEqual(@as(f64, 0), state.timestamp_ms);
}

test "GlobalState setClearColor updates color" {
    var state = GlobalState.init();

    state.setClearColor(1.0, 0.5, 0.25);

    try testing.expectApproxEqAbs(@as(f32, 1.0), state.clear_color.r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), state.clear_color.g, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), state.clear_color.b, 0.001);
}

test "GlobalState performanceNow returns increasing values" {
    const state = GlobalState.init();

    const t1 = state.performanceNow();
    // Small busy wait
    var sum: u64 = 0;
    for (0..10000) |i| {
        sum +%= i;
    }
    std.mem.doNotOptimizeAway(sum);
    const t2 = state.performanceNow();

    try testing.expect(t2 >= t1);
}

test "GlobalState requestAnimationFrame sets callback" {
    var state = GlobalState.init();
    try testing.expect(state.frame_callback == null);

    const testCallback = struct {
        fn cb(_: f64) void {}
    }.cb;

    state.requestAnimationFrame(testCallback);
    try testing.expect(state.frame_callback != null);

    state.cancelAnimationFrame();
    try testing.expect(state.frame_callback == null);
}

test "js_bindings has expected entries" {
    try testing.expectEqual(@as(usize, 3), js_bindings.len);

    // Check setClearColor binding
    try testing.expectEqualStrings("setClearColor", js_bindings[0].name);
    try testing.expectEqual(@as(u8, 3), js_bindings[0].arg_count);
}

test "ConsoleBinding write produces output" {
    // Just verify it doesn't crash - output goes to stderr
    ConsoleBinding.write(.log, "test message");
    ConsoleBinding.write(.@"error", "error message");
}

test "GlobalState struct size is reasonable" {
    // Should be small for cache efficiency
    try testing.expect(@sizeOf(GlobalState) <= 64);
}
