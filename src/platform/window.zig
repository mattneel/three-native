//! Window management for three-native
//!
//! Provides native window creation and management using sokol_app.
//! This is Phase 1.0 - type definitions only, no implementation yet.

const std = @import("std");
const testing = std.testing;

/// Window configuration options
pub const WindowConfig = struct {
    /// Window width in pixels
    width: u32 = 800,
    /// Window height in pixels
    height: u32 = 600,
    /// Window title
    title: [:0]const u8 = "three-native",
    /// Enable high DPI support
    high_dpi: bool = true,
    /// Target frames per second (0 = vsync)
    target_fps: u32 = 60,
};

/// Clear color for the render pass
pub const ClearColor = struct {
    r: f32 = 0.0,
    g: f32 = 0.0,
    b: f32 = 0.0,
    a: f32 = 1.0,

    pub fn rgb(r: f32, g: f32, b: f32) ClearColor {
        return .{ .r = r, .g = g, .b = b, .a = 1.0 };
    }

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) ClearColor {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
};

/// Window state
pub const WindowState = enum {
    /// Window not yet created
    uninitialized,
    /// Window is open and running
    running,
    /// Window close requested
    closing,
    /// Window has been closed
    closed,
};

/// Window handle - opaque type for the native window
pub const Window = struct {
    config: WindowConfig,
    state: WindowState,
    clear_color: ClearColor,
    frame_count: u64,

    const Self = @This();

    /// Initialize window with default config
    pub fn init() Self {
        return initWithConfig(.{});
    }

    /// Initialize window with custom config
    pub fn initWithConfig(config: WindowConfig) Self {
        return .{
            .config = config,
            .state = .uninitialized,
            .clear_color = ClearColor.rgb(0.0, 0.0, 0.0),
            .frame_count = 0,
        };
    }

    /// Set the clear color
    pub fn setClearColor(self: *Self, color: ClearColor) void {
        self.clear_color = color;
    }

    /// Get current clear color
    pub fn getClearColor(self: *const Self) ClearColor {
        return self.clear_color;
    }

    /// Check if window is running
    pub fn isRunning(self: *const Self) bool {
        return self.state == .running;
    }

    /// Get frame count
    pub fn getFrameCount(self: *const Self) u64 {
        return self.frame_count;
    }
};

// =============================================================================
// Tests - Tiger Style: test positive AND negative space
// =============================================================================

test "WindowConfig has sensible defaults" {
    const config = WindowConfig{};
    try testing.expectEqual(@as(u32, 800), config.width);
    try testing.expectEqual(@as(u32, 600), config.height);
    try testing.expectEqualStrings("three-native", config.title);
    try testing.expect(config.high_dpi);
    try testing.expectEqual(@as(u32, 60), config.target_fps);
}

test "ClearColor rgb constructor" {
    const color = ClearColor.rgb(1.0, 0.5, 0.25);
    try testing.expectApproxEqAbs(@as(f32, 1.0), color.r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), color.g, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), color.b, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), color.a, 0.001);
}

test "ClearColor rgba constructor" {
    const color = ClearColor.rgba(0.1, 0.2, 0.3, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.1), color.r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.2), color.g, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.3), color.b, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), color.a, 0.001);
}

test "Window initializes with default config" {
    const window = Window.init();
    try testing.expectEqual(WindowState.uninitialized, window.state);
    try testing.expectEqual(@as(u32, 800), window.config.width);
    try testing.expectEqual(@as(u64, 0), window.frame_count);
}

test "Window initializes with custom config" {
    const config = WindowConfig{
        .width = 1920,
        .height = 1080,
        .title = "Custom Title",
    };
    const window = Window.initWithConfig(config);
    try testing.expectEqual(@as(u32, 1920), window.config.width);
    try testing.expectEqual(@as(u32, 1080), window.config.height);
}

test "Window clear color can be set and retrieved" {
    var window = Window.init();

    // Initial color is black
    const initial = window.getClearColor();
    try testing.expectApproxEqAbs(@as(f32, 0.0), initial.r, 0.001);

    // Set to red
    window.setClearColor(ClearColor.rgb(1.0, 0.0, 0.0));
    const red = window.getClearColor();
    try testing.expectApproxEqAbs(@as(f32, 1.0), red.r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), red.g, 0.001);
}

test "Window isRunning reflects state" {
    var window = Window.init();
    try testing.expect(!window.isRunning());

    window.state = .running;
    try testing.expect(window.isRunning());

    window.state = .closing;
    try testing.expect(!window.isRunning());
}

test "Window struct size is reasonable" {
    // Should fit in a cache line or two
    try testing.expect(@sizeOf(Window) <= 128);
}
