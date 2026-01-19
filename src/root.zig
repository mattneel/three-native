//! three-native library module
//!
//! Native runtime for Three.js games.

const std = @import("std");

// Platform modules
pub const window = @import("platform/window.zig");
pub const renderer = @import("platform/renderer.zig");

// Runtime modules
pub const js = @import("runtime/js.zig");

// Shim modules
pub const globals = @import("shim/globals.zig");
pub const webgl = @import("shim/webgl.zig");
pub const webgl_state = @import("shim/webgl_state.zig");

// Re-export main types for convenience
pub const Window = window.Window;
pub const WindowConfig = window.WindowConfig;
pub const ClearColor = window.ClearColor;
pub const GlobalState = globals.GlobalState;
pub const TriangleRenderer = renderer.TriangleRenderer;
pub const JsRuntime = js.Runtime;
pub const WebGLContextTable = webgl.ContextTable;
pub const WebGLBufferTable = webgl.BufferTable;
pub const WebGLBindState = webgl_state.BindState;

test {
    // Run all module tests
    std.testing.refAllDecls(@This());
}
