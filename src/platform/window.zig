//! Window management for three-native
//!
//! Provides native window creation and management using sokol_app + sokol_gfx.

const std = @import("std");
const testing = std.testing;
const sokol = @import("sokol");
const sapp = sokol.app;
const sgfx = sokol.gfx;
const sglue = sokol.glue;
const slog = sokol.log;
const TriangleRenderer = @import("renderer.zig").TriangleRenderer;
const webgl_state = @import("../shim/webgl_state.zig");
const webgl_backend = @import("../shim/webgl_backend.zig");
const webgl_draw = @import("../shim/webgl_draw.zig");
const events = @import("../runtime/events.zig");
const js = @import("../runtime/js.zig");

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

    /// Convert to sokol pass action color
    fn toSokolColor(self: ClearColor) sgfx.Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a };
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

/// Frame callback type - called each frame with delta time in seconds
pub const FrameCallback = *const fn (delta_seconds: f64) void;

/// Click detection threshold (in pixels)
const ClickThreshold: f32 = 5.0;

/// Global window state (sokol uses callbacks, so we need global state)
var g_state: struct {
    config: WindowConfig = .{},
    state: WindowState = .uninitialized,
    clear_color: ClearColor = ClearColor.rgb(0.0, 0.0, 0.0),
    frame_count: u64 = 0,
    frame_callback: ?FrameCallback = null,
    last_time: u64 = 0,
    pass_action: sgfx.PassAction = .{},
    triangle_renderer: ?TriangleRenderer = null,
    draw_triangle: bool = false,
    // Mouse tracking for click detection
    mouse_down_x: f32 = 0,
    mouse_down_y: f32 = 0,
    mouse_down_button: u8 = 0,
    mouse_is_down: bool = false,
} = .{};

// =============================================================================
// Sokol callbacks
// =============================================================================

fn sokolInit() callconv(.c) void {
    // Initialize sokol subsystems
    sokol.time.setup();
    sgfx.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });

    // Query and log features
    const features = sgfx.queryFeatures();
    std.debug.print("[window] Sokol features: image_clamp_to_border={}, mrt_independent_blend_state={}, mrt_independent_write_mask={}\n", .{
        features.image_clamp_to_border,
        features.mrt_independent_blend_state,
        features.mrt_independent_write_mask,
    });

    // Wire WebGL buffer backend to sokol
    webgl_state.globalBufferManager().setBackend(webgl_backend.getSokolBackend()) catch |err| {
        std.debug.print("[window] buffer backfill failed: {}\n", .{err});
        sapp.requestQuit();
        return;
    };

    // Initialize triangle renderer
    g_state.triangle_renderer = TriangleRenderer.init();

    g_state.state = .running;
    g_state.last_time = sokol.time.now();
    updatePassAction();
    std.debug.print("[window] initialized {}x{}\n", .{
        sapp.width(),
        sapp.height(),
    });
}

fn sokolFrame() callconv(.c) void {
    // Calculate delta time
    const now = sokol.time.now();
    const delta_ns = sokol.time.diff(now, g_state.last_time);
    const delta_seconds = sokol.time.sec(delta_ns);
    g_state.last_time = now;

    // Call user frame callback if set
    if (g_state.frame_callback) |cb| {
        cb(delta_seconds);
    }

    // Begin default render pass with clear color
    const pass_action = webgl_draw.consumePassAction(g_state.pass_action);
    sgfx.beginPass(.{
        .action = pass_action,
        .swapchain = sglue.swapchain(),
    });

    // Draw triangle if enabled
    if (g_state.draw_triangle) {
        if (g_state.triangle_renderer) |renderer| {
            renderer.draw();
        }
    }

    // Flush queued WebGL draw calls
    webgl_draw.flush();

    // End pass and commit
    sgfx.endPass();
    sgfx.commit();

    g_state.frame_count += 1;
}

fn sokolCleanup() callconv(.c) void {
    // Cleanup triangle renderer
    if (g_state.triangle_renderer) |*renderer| {
        renderer.deinit();
        g_state.triangle_renderer = null;
    }

    sgfx.shutdown();
    g_state.state = .closed;
    std.debug.print("[window] shutdown after {} frames\n", .{g_state.frame_count});
}

fn sokolEvent(event: [*c]const sapp.Event) callconv(.c) void {
    const ev = event.*;

    // Extract modifier flags
    const shift = (ev.modifiers & sapp.modifier_shift) != 0;
    const ctrl = (ev.modifiers & sapp.modifier_ctrl) != 0;
    const alt = (ev.modifiers & sapp.modifier_alt) != 0;
    const meta = (ev.modifiers & sapp.modifier_super) != 0;

    // Track mouse button state
    const lmb = (ev.modifiers & sapp.modifier_lmb) != 0;
    const rmb = (ev.modifiers & sapp.modifier_rmb) != 0;
    const mmb = (ev.modifiers & sapp.modifier_mmb) != 0;
    var buttons: u8 = 0;
    if (lmb) buttons |= 1;
    if (rmb) buttons |= 2;
    if (mmb) buttons |= 4;

    switch (ev.type) {
        .QUIT_REQUESTED => {
            g_state.state = .closing;
        },
        .KEY_DOWN => {
            // ESC to quit
            if (ev.key_code == .ESCAPE) {
                sapp.requestQuit();
            }
            // Dispatch keydown event
            const key_code: u32 = @intCast(@intFromEnum(ev.key_code));
            js.dispatchKeyboardEvent(.keydown, .{
                .key = events.sokolKeyCodeToKey(key_code, shift),
                .code = events.sokolKeyCodeToCode(key_code),
                .keyCode = events.sokolKeyCodeToDom(key_code),
                .shiftKey = shift,
                .ctrlKey = ctrl,
                .altKey = alt,
                .metaKey = meta,
                .repeat = ev.key_repeat,
            });
        },
        .KEY_UP => {
            const key_code: u32 = @intCast(@intFromEnum(ev.key_code));
            js.dispatchKeyboardEvent(.keyup, .{
                .key = events.sokolKeyCodeToKey(key_code, shift),
                .code = events.sokolKeyCodeToCode(key_code),
                .keyCode = events.sokolKeyCodeToDom(key_code),
                .shiftKey = shift,
                .ctrlKey = ctrl,
                .altKey = alt,
                .metaKey = meta,
                .repeat = false,
            });
        },
        .MOUSE_DOWN => {
            const button: u8 = switch (ev.mouse_button) {
                .LEFT => 0,
                .MIDDLE => 1,
                .RIGHT => 2,
                else => 0,
            };
            // Track mouse down position for click detection
            g_state.mouse_down_x = ev.mouse_x;
            g_state.mouse_down_y = ev.mouse_y;
            g_state.mouse_down_button = button;
            g_state.mouse_is_down = true;

            js.dispatchMouseEvent(.mousedown, .{
                .clientX = @intFromFloat(ev.mouse_x),
                .clientY = @intFromFloat(ev.mouse_y),
                .button = button,
                .buttons = buttons,
                .shiftKey = shift,
                .ctrlKey = ctrl,
                .altKey = alt,
                .metaKey = meta,
            });
        },
        .MOUSE_UP => {
            const button: u8 = switch (ev.mouse_button) {
                .LEFT => 0,
                .MIDDLE => 1,
                .RIGHT => 2,
                else => 0,
            };
            js.dispatchMouseEvent(.mouseup, .{
                .clientX = @intFromFloat(ev.mouse_x),
                .clientY = @intFromFloat(ev.mouse_y),
                .button = button,
                .buttons = buttons,
                .shiftKey = shift,
                .ctrlKey = ctrl,
                .altKey = alt,
                .metaKey = meta,
            });

            // Synthesize click/contextmenu if mouse didn't move much
            if (g_state.mouse_is_down and g_state.mouse_down_button == button) {
                const dx = ev.mouse_x - g_state.mouse_down_x;
                const dy = ev.mouse_y - g_state.mouse_down_y;
                const distance = @sqrt(dx * dx + dy * dy);

                if (distance < ClickThreshold) {
                    const mouse_data = events.MouseEventData{
                        .clientX = @intFromFloat(ev.mouse_x),
                        .clientY = @intFromFloat(ev.mouse_y),
                        .button = button,
                        .buttons = buttons,
                        .shiftKey = shift,
                        .ctrlKey = ctrl,
                        .altKey = alt,
                        .metaKey = meta,
                    };

                    if (button == 2) {
                        // Right click -> contextmenu
                        js.dispatchMouseEvent(.contextmenu, mouse_data);
                    } else {
                        // Left/middle click -> click
                        js.dispatchMouseEvent(.click, mouse_data);
                    }
                }
            }
            g_state.mouse_is_down = false;
        },
        .MOUSE_MOVE => {
            js.dispatchMouseEvent(.mousemove, .{
                .clientX = @intFromFloat(ev.mouse_x),
                .clientY = @intFromFloat(ev.mouse_y),
                .button = 0,
                .buttons = buttons,
                .shiftKey = shift,
                .ctrlKey = ctrl,
                .altKey = alt,
                .metaKey = meta,
            });
        },
        .MOUSE_SCROLL => {
            js.dispatchMouseEvent(.wheel, .{
                .clientX = @intFromFloat(ev.mouse_x),
                .clientY = @intFromFloat(ev.mouse_y),
                .button = 0,
                .buttons = buttons,
                .shiftKey = shift,
                .ctrlKey = ctrl,
                .altKey = alt,
                .metaKey = meta,
                .deltaX = ev.scroll_x * -120, // Scale to match browser wheel delta
                .deltaY = ev.scroll_y * -120,
                .deltaMode = 0, // Pixel mode
            });
        },
        .RESIZED => {
            // Dispatch resize event with new dimensions
            js.dispatchResizeEvent(.{
                .width = @intCast(sapp.width()),
                .height = @intCast(sapp.height()),
            });
        },
        else => {},
    }
}

fn updatePassAction() void {
    const color = g_state.clear_color.toSokolColor();
    g_state.pass_action = .{
        .colors = .{
            .{
                .load_action = .CLEAR,
                .clear_value = color,
            },
            .{},
            .{},
            .{},
            .{},
            .{},
            .{},
            .{},
        },
    };
}

// =============================================================================
// Public API
// =============================================================================

/// Run the application with the given config.
/// This function blocks until the window is closed.
pub fn run(config: WindowConfig) void {
    g_state.config = config;
    g_state.clear_color = ClearColor.rgb(0.0, 0.0, 0.0);
    g_state.frame_count = 0;
    g_state.state = .uninitialized;

    sapp.run(.{
        .init_cb = sokolInit,
        .frame_cb = sokolFrame,
        .cleanup_cb = sokolCleanup,
        .event_cb = sokolEvent,
        .width = @intCast(config.width),
        .height = @intCast(config.height),
        .window_title = config.title.ptr,
        .high_dpi = config.high_dpi,
        .logger = .{ .func = slog.func },
    });
}

/// Set the frame callback - called each frame with delta time
pub fn setFrameCallback(callback: ?FrameCallback) void {
    g_state.frame_callback = callback;
}

/// Set the clear color
pub fn setClearColor(color: ClearColor) void {
    g_state.clear_color = color;
    if (g_state.state == .running) {
        updatePassAction();
    }
}

/// Get current clear color
pub fn getClearColor() ClearColor {
    return g_state.clear_color;
}

/// Get frame count
pub fn getFrameCount() u64 {
    return g_state.frame_count;
}

/// Check if window is running
pub fn isRunning() bool {
    return g_state.state == .running;
}

/// Request window close
pub fn requestClose() void {
    sapp.requestQuit();
}

/// Enable or disable triangle rendering
pub fn setDrawTriangle(enabled: bool) void {
    g_state.draw_triangle = enabled;
}

/// Get window width
pub fn getWidth() u32 {
    return @intCast(sapp.width());
}

/// Get window height
pub fn getHeight() u32 {
    return @intCast(sapp.height());
}

// =============================================================================
// Legacy Window struct API (for backwards compatibility with tests)
// =============================================================================

/// Window handle - wrapper around global state
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
    pub fn setClearColorMethod(self: *Self, color: ClearColor) void {
        self.clear_color = color;
    }

    /// Get current clear color
    pub fn getClearColorMethod(self: *const Self) ClearColor {
        return self.clear_color;
    }

    /// Check if window is running
    pub fn isRunningMethod(self: *const Self) bool {
        return self.state == .running;
    }

    /// Get frame count
    pub fn getFrameCountMethod(self: *const Self) u64 {
        return self.frame_count;
    }
};

// =============================================================================
// Tests
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

test "ClearColor converts to sokol format" {
    const color = ClearColor.rgb(0.5, 0.6, 0.7);
    const sokol_color = color.toSokolColor();
    try testing.expectApproxEqAbs(@as(f32, 0.5), sokol_color.r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.6), sokol_color.g, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.7), sokol_color.b, 0.001);
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

test "Window struct size is reasonable" {
    try testing.expect(@sizeOf(Window) <= 128);
}
