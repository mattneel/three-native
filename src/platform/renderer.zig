//! Triangle renderer for three-native
//!
//! Phase 1.3: Renders a hardcoded colored triangle using sokol_gfx.

const std = @import("std");
const sokol = @import("sokol");
const sgfx = sokol.gfx;

/// Vertex with position (xy) and color (rgb)
const Vertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
};

/// Triangle renderer state
pub const TriangleRenderer = struct {
    pipeline: sgfx.Pipeline,
    bindings: sgfx.Bindings,
    initialized: bool,

    const Self = @This();

    pub fn init() Self {
        // Triangle vertices: positions in clip space (-1 to 1), with RGB colors
        const vertices = [_]Vertex{
            .{ .x = 0.0, .y = 0.5, .r = 1.0, .g = 0.0, .b = 0.0 }, // top - red
            .{ .x = 0.5, .y = -0.5, .r = 0.0, .g = 1.0, .b = 0.0 }, // bottom right - green
            .{ .x = -0.5, .y = -0.5, .r = 0.0, .g = 0.0, .b = 1.0 }, // bottom left - blue
        };

        // Create vertex buffer
        const vbuf = sgfx.makeBuffer(.{
            .data = sgfx.asRange(&vertices),
            .label = "triangle-vertices",
        });

        // Create shader
        const shd = sgfx.makeShader(shaderDesc());

        // Create pipeline
        var pip_desc = sgfx.PipelineDesc{};
        pip_desc.shader = shd;
        pip_desc.layout.attrs[0] = .{ .format = .FLOAT2 }; // position
        pip_desc.layout.attrs[1] = .{ .format = .FLOAT3 }; // color
        pip_desc.label = "triangle-pipeline";

        const pip = sgfx.makePipeline(pip_desc);

        // Set up bindings
        var bind = sgfx.Bindings{};
        bind.vertex_buffers[0] = vbuf;

        return .{
            .pipeline = pip,
            .bindings = bind,
            .initialized = true,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            sgfx.destroyPipeline(self.pipeline);
            sgfx.destroyBuffer(self.bindings.vertex_buffers[0]);
            self.initialized = false;
        }
    }

    pub fn draw(self: *const Self) void {
        if (!self.initialized) return;

        sgfx.applyPipeline(self.pipeline);
        sgfx.applyBindings(self.bindings);
        sgfx.draw(0, 3, 1); // base_element, num_elements, num_instances
    }
};

// =============================================================================
// Shader source - GLSL for OpenGL backend
// =============================================================================

fn shaderDesc() sgfx.ShaderDesc {
    var desc = sgfx.ShaderDesc{};

    // Vertex shader
    desc.vertex_func.source =
        \\#version 410
        \\layout(location=0) in vec2 position;
        \\layout(location=1) in vec3 color0;
        \\out vec3 color;
        \\void main() {
        \\    gl_Position = vec4(position, 0.0, 1.0);
        \\    color = color0;
        \\}
    ;

    // Fragment shader
    desc.fragment_func.source =
        \\#version 410
        \\in vec3 color;
        \\out vec4 frag_color;
        \\void main() {
        \\    frag_color = vec4(color, 1.0);
        \\}
    ;

    // Attribute names for the shader
    desc.attrs[0].glsl_name = "position";
    desc.attrs[1].glsl_name = "color0";

    desc.label = "triangle-shader";

    return desc;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "Vertex struct has correct size" {
    // 5 floats × 4 bytes = 20 bytes
    try testing.expectEqual(@as(usize, 20), @sizeOf(Vertex));
}

test "Vertex struct has correct alignment" {
    // Should be 4-byte aligned (float alignment)
    try testing.expectEqual(@as(usize, 4), @alignOf(Vertex));
}
