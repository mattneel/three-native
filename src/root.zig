//! three-native library module
//!
//! Native runtime for Three.js games.

const std = @import("std");

// Platform modules
pub const window = @import("platform/window.zig");
pub const renderer = @import("platform/renderer.zig");

// Runtime modules
pub const js = @import("runtime/js.zig");
pub const events = @import("runtime/events.zig");

// Shim modules
pub const globals = @import("shim/globals.zig");
pub const webgl = @import("shim/webgl.zig");
pub const webgl_state = @import("shim/webgl_state.zig");
pub const webgl_backend = @import("shim/webgl_backend.zig");
pub const webgl_shader = @import("shim/webgl_shader.zig");
pub const webgl_program = @import("shim/webgl_program.zig");
pub const webgl_draw = @import("shim/webgl_draw.zig");
pub const webgl_texture = @import("shim/webgl_texture.zig");
pub const image_loader = @import("shim/image_loader.zig");

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
pub const WebGLBufferManager = webgl_state.BufferManager;
pub const WebGLSokolBackend = webgl_backend.sokolBufferBackend;
pub const WebGLShaderTable = webgl_shader.ShaderTable;
pub const WebGLProgramTable = webgl_program.ProgramTable;
pub const WebGLDrawState = webgl_draw;

test {
    // Run all module tests
    std.testing.refAllDecls(@This());
}
