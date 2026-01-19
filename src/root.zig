//! three-native library module
//!
//! Native runtime for Three.js games.

const std = @import("std");

// Platform modules
pub const window = @import("platform/window.zig");

// Shim modules
pub const globals = @import("shim/globals.zig");

// Re-export main types for convenience
pub const Window = window.Window;
pub const WindowConfig = window.WindowConfig;
pub const ClearColor = window.ClearColor;
pub const GlobalState = globals.GlobalState;

test {
    // Run all module tests
    std.testing.refAllDecls(@This());
}
