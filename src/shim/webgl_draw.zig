//! WebGL draw state and command queue (Phase 2.4)
//!
//! Minimal pipeline wiring for drawArrays/drawElements with sokol_gfx.

const std = @import("std");
const testing = std.testing;
const sokol = @import("sokol");
const sg = sokol.gfx;
const webgl = @import("webgl.zig");
const webgl_state = @import("webgl_state.zig");
const webgl_program = @import("webgl_program.zig");

// Scoped logger for draw queue debug tracing
const log = std.log.scoped(.webgl_draw);

const GL_COLOR_BUFFER_BIT: u32 = 0x00004000;
const GL_DEPTH_BUFFER_BIT: u32 = 0x00000100;
const GL_STENCIL_BUFFER_BIT: u32 = 0x00000400;
const GL_NEVER: u32 = 0x0200;
const GL_LESS: u32 = 0x0201;
const GL_EQUAL: u32 = 0x0202;
const GL_LEQUAL: u32 = 0x0203;
const GL_GREATER: u32 = 0x0204;
const GL_NOTEQUAL: u32 = 0x0205;
const GL_GEQUAL: u32 = 0x0206;
const GL_ALWAYS: u32 = 0x0207;
const GL_KEEP: u32 = 0x1E00;
const GL_REPLACE: u32 = 0x1E01;
const GL_INCR: u32 = 0x1E02;
const GL_DECR: u32 = 0x1E03;
const GL_INVERT: u32 = 0x150A;
const GL_INCR_WRAP: u32 = 0x8507;
const GL_DECR_WRAP: u32 = 0x8508;
const GL_FRONT: u32 = 0x0404;
const GL_BACK: u32 = 0x0405;
const GL_FRONT_AND_BACK: u32 = 0x0408;
const GL_CW: u32 = 0x0900;
const GL_CCW: u32 = 0x0901;
const GL_ZERO: u32 = 0;
const GL_ONE: u32 = 1;
const GL_SRC_COLOR: u32 = 0x0300;
const GL_ONE_MINUS_SRC_COLOR: u32 = 0x0301;
const GL_SRC_ALPHA: u32 = 0x0302;
const GL_ONE_MINUS_SRC_ALPHA: u32 = 0x0303;
const GL_DST_ALPHA: u32 = 0x0304;
const GL_ONE_MINUS_DST_ALPHA: u32 = 0x0305;
const GL_DST_COLOR: u32 = 0x0306;
const GL_ONE_MINUS_DST_COLOR: u32 = 0x0307;
const GL_CONSTANT_COLOR: u32 = 0x8001;
const GL_ONE_MINUS_CONSTANT_COLOR: u32 = 0x8002;
const GL_CONSTANT_ALPHA: u32 = 0x8003;
const GL_ONE_MINUS_CONSTANT_ALPHA: u32 = 0x8004;
const GL_FUNC_ADD: u32 = 0x8006;
const GL_FUNC_SUBTRACT: u32 = 0x800A;
const GL_FUNC_REVERSE_SUBTRACT: u32 = 0x800B;

pub const MaxVertexAttribs: usize = 16;
pub const MaxDrawCommands: usize = 64;
const MaxVertexBuffers: usize = (sg.Bindings{}).vertex_buffers.len;
const MaxPipelineCacheEntries: usize = 64;

const PipelineCacheEntry = struct {
    key: u64 = 0,
    pipeline: sg.Pipeline = .{},
    valid: bool = false,
};

pub const VertexAttrib = struct {
    enabled: bool = false,
    size: u8 = 0,
    gl_type: u32 = 0,
    normalized: bool = false,
    stride: u32 = 0,
    offset: u32 = 0,
    buffer: ?webgl.BufferId = null,
};

const DrawKind = enum {
    arrays,
    elements,
};

const DrawCommand = struct {
    kind: DrawKind,
    mode: u32,
    first: i32,
    count: i32,
    index_type: u32,
    index_offset: u32,
    program: webgl_program.ProgramId,
    attribs: [MaxVertexAttribs]VertexAttrib,
    element_buffer: ?webgl.BufferId,
    viewport: [4]i32,
    scissor: [4]i32,
    scissor_enabled: bool,
    depth_enabled: bool,
    depth_func: u32,
    depth_mask: bool,
    polygon_offset: [2]f32,
    polygon_offset_enabled: bool,
    cull_enabled: bool,
    cull_face: u32,
    front_face: u32,
    blend_enabled: bool,
    blend_src: u32,
    blend_dst: u32,
    blend_src_alpha: u32,
    blend_dst_alpha: u32,
    blend_eq: u32,
    blend_eq_alpha: u32,
    color_mask: [4]bool,
    alpha_to_coverage_enabled: bool,
    stencil_enabled: bool,
    stencil_func_front: u32,
    stencil_func_back: u32,
    stencil_ref_front: u8,
    stencil_ref_back: u8,
    stencil_read_mask_front: u8,
    stencil_read_mask_back: u8,
    stencil_write_mask_front: u8,
    stencil_write_mask_back: u8,
    stencil_fail_front: u32,
    stencil_zfail_front: u32,
    stencil_zpass_front: u32,
    stencil_fail_back: u32,
    stencil_zfail_back: u32,
    stencil_zpass_back: u32,
};

const DrawState = struct {
    current_program: ?webgl_program.ProgramId = null,
    attribs: [MaxVertexAttribs]VertexAttrib = [_]VertexAttrib{.{}} ** MaxVertexAttribs,
    commands: [MaxDrawCommands]DrawCommand = undefined,
    command_count: usize = 0,
    pipeline_cache: [MaxPipelineCacheEntries]PipelineCacheEntry = [_]PipelineCacheEntry{.{}} ** MaxPipelineCacheEntries,
    pipeline_cache_next: usize = 0,
    viewport: [4]i32 = .{ 0, 0, 0, 0 },
    scissor: [4]i32 = .{ 0, 0, 0, 0 },
    scissor_enabled: bool = false,
    depth_enabled: bool = false,
    depth_func: u32 = GL_LESS,
    depth_mask: bool = true,
    polygon_offset: [2]f32 = .{ 0.0, 0.0 },
    polygon_offset_enabled: bool = false,
    cull_enabled: bool = false,
    cull_face: u32 = GL_BACK,
    front_face: u32 = GL_CCW,
    blend_enabled: bool = false,
    blend_src: u32 = GL_ONE,
    blend_dst: u32 = GL_ZERO,
    blend_src_alpha: u32 = GL_ONE,
    blend_dst_alpha: u32 = GL_ZERO,
    blend_eq: u32 = GL_FUNC_ADD,
    blend_eq_alpha: u32 = GL_FUNC_ADD,
    color_mask: [4]bool = .{ true, true, true, true },
    alpha_to_coverage_enabled: bool = false,
    stencil_enabled: bool = false,
    stencil_func_front: u32 = GL_ALWAYS,
    stencil_func_back: u32 = GL_ALWAYS,
    stencil_ref_front: u8 = 0,
    stencil_ref_back: u8 = 0,
    stencil_read_mask_front: u8 = 0xFF,
    stencil_read_mask_back: u8 = 0xFF,
    stencil_write_mask_front: u8 = 0xFF,
    stencil_write_mask_back: u8 = 0xFF,
    stencil_fail_front: u32 = GL_KEEP,
    stencil_zfail_front: u32 = GL_KEEP,
    stencil_zpass_front: u32 = GL_KEEP,
    stencil_fail_back: u32 = GL_KEEP,
    stencil_zfail_back: u32 = GL_KEEP,
    stencil_zpass_back: u32 = GL_KEEP,
    clear_color: sg.Color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 },
    clear_depth: f32 = 1.0,
    clear_stencil: u8 = 0,
    clear_pending: bool = false,
    clear_mask: u32 = 0,
};

var g_state: DrawState = .{};

pub fn reset() void {
    clearPipelineCache();
    g_state = .{};
}

pub fn setViewport(x: i32, y: i32, width: i32, height: i32) void {
    g_state.viewport = .{ x, y, width, height };
}

pub fn setScissor(x: i32, y: i32, width: i32, height: i32) void {
    g_state.scissor = .{ x, y, width, height };
}

pub fn setScissorEnabled(enabled: bool) void {
    g_state.scissor_enabled = enabled;
}

pub fn setClearColor(r: f32, g: f32, b: f32, a: f32) void {
    g_state.clear_color = .{ .r = r, .g = g, .b = b, .a = a };
}

pub fn setClearDepth(depth: f32) void {
    g_state.clear_depth = depth;
}

pub fn setClearStencil(stencil: i32) void {
    var value = stencil;
    if (value < 0) value = 0;
    if (value > 255) value = 255;
    g_state.clear_stencil = @intCast(value);
}

pub fn requestClear(mask: u32) void {
    if (mask == 0) return;
    g_state.clear_pending = true;
    g_state.clear_mask = mask;
}

pub fn setDepthTestEnabled(enabled: bool) void {
    g_state.depth_enabled = enabled;
}

pub fn setDepthFunc(func: u32) void {
    g_state.depth_func = func;
}

pub fn setDepthMask(enabled: bool) void {
    g_state.depth_mask = enabled;
}

pub fn setPolygonOffset(factor: f32, units: f32) void {
    g_state.polygon_offset = .{ factor, units };
}

pub fn setPolygonOffsetEnabled(enabled: bool) void {
    g_state.polygon_offset_enabled = enabled;
}

pub fn setCullEnabled(enabled: bool) void {
    g_state.cull_enabled = enabled;
}

pub fn setCullFace(face: u32) void {
    g_state.cull_face = face;
}

pub fn setFrontFace(face: u32) void {
    g_state.front_face = face;
}

pub fn setBlendEnabled(enabled: bool) void {
    g_state.blend_enabled = enabled;
}

pub fn setBlendFunc(src: u32, dst: u32) void {
    g_state.blend_src = src;
    g_state.blend_dst = dst;
    g_state.blend_src_alpha = src;
    g_state.blend_dst_alpha = dst;
}

pub fn setBlendFuncSeparate(src: u32, dst: u32, src_alpha: u32, dst_alpha: u32) void {
    g_state.blend_src = src;
    g_state.blend_dst = dst;
    g_state.blend_src_alpha = src_alpha;
    g_state.blend_dst_alpha = dst_alpha;
}

pub fn setBlendEquation(eq: u32) void {
    g_state.blend_eq = eq;
    g_state.blend_eq_alpha = eq;
}

pub fn setBlendEquationSeparate(eq: u32, eq_alpha: u32) void {
    g_state.blend_eq = eq;
    g_state.blend_eq_alpha = eq_alpha;
}

pub fn setColorMask(r: bool, g: bool, b: bool, a: bool) void {
    g_state.color_mask = .{ r, g, b, a };
}

pub fn setAlphaToCoverageEnabled(enabled: bool) void {
    g_state.alpha_to_coverage_enabled = enabled;
}

pub fn setStencilEnabled(enabled: bool) void {
    g_state.stencil_enabled = enabled;
}

pub fn setStencilFunc(func: u32, ref: i32, mask: u32) void {
    setStencilFuncSeparate(GL_FRONT_AND_BACK, func, ref, mask);
}

pub fn setStencilFuncSeparate(face: u32, func: u32, ref: i32, mask: u32) void {
    const ref_u8 = clampStencilU8(ref);
    const mask_u8: u8 = if (mask > 255) 255 else @as(u8, @intCast(mask));
    switch (face) {
        GL_FRONT => {
            g_state.stencil_func_front = func;
            g_state.stencil_ref_front = ref_u8;
            g_state.stencil_read_mask_front = mask_u8;
        },
        GL_BACK => {
            g_state.stencil_func_back = func;
            g_state.stencil_ref_back = ref_u8;
            g_state.stencil_read_mask_back = mask_u8;
        },
        GL_FRONT_AND_BACK => {
            g_state.stencil_func_front = func;
            g_state.stencil_func_back = func;
            g_state.stencil_ref_front = ref_u8;
            g_state.stencil_ref_back = ref_u8;
            g_state.stencil_read_mask_front = mask_u8;
            g_state.stencil_read_mask_back = mask_u8;
        },
        else => {},
    }
}

pub fn setStencilMask(mask: u32) void {
    setStencilMaskSeparate(GL_FRONT_AND_BACK, mask);
}

pub fn setStencilMaskSeparate(face: u32, mask: u32) void {
    const mask_u8: u8 = if (mask > 255) 255 else @as(u8, @intCast(mask));
    switch (face) {
        GL_FRONT => g_state.stencil_write_mask_front = mask_u8,
        GL_BACK => g_state.stencil_write_mask_back = mask_u8,
        GL_FRONT_AND_BACK => {
            g_state.stencil_write_mask_front = mask_u8;
            g_state.stencil_write_mask_back = mask_u8;
        },
        else => {},
    }
}

pub fn setStencilOp(fail: u32, zfail: u32, zpass: u32) void {
    setStencilOpSeparate(GL_FRONT_AND_BACK, fail, zfail, zpass);
}

pub fn setStencilOpSeparate(face: u32, fail: u32, zfail: u32, zpass: u32) void {
    switch (face) {
        GL_FRONT => {
            g_state.stencil_fail_front = fail;
            g_state.stencil_zfail_front = zfail;
            g_state.stencil_zpass_front = zpass;
        },
        GL_BACK => {
            g_state.stencil_fail_back = fail;
            g_state.stencil_zfail_back = zfail;
            g_state.stencil_zpass_back = zpass;
        },
        GL_FRONT_AND_BACK => {
            g_state.stencil_fail_front = fail;
            g_state.stencil_zfail_front = zfail;
            g_state.stencil_zpass_front = zpass;
            g_state.stencil_fail_back = fail;
            g_state.stencil_zfail_back = zfail;
            g_state.stencil_zpass_back = zpass;
        },
        else => {},
    }
}

pub fn consumePassAction(default_action: sg.PassAction) sg.PassAction {
    if (!g_state.clear_pending) return default_action;
    log.debug("consumePassAction: clear_mask={x} color=[{d:.2},{d:.2},{d:.2},{d:.2}]", .{ g_state.clear_mask, g_state.clear_color.r, g_state.clear_color.g, g_state.clear_color.b, g_state.clear_color.a });
    var action = sg.PassAction{};
    if ((g_state.clear_mask & GL_COLOR_BUFFER_BIT) != 0) {
        action.colors[0].load_action = .CLEAR;
        action.colors[0].clear_value = g_state.clear_color;
    } else {
        action.colors[0].load_action = .LOAD;
    }
    if ((g_state.clear_mask & GL_DEPTH_BUFFER_BIT) != 0) {
        action.depth.load_action = .CLEAR;
        action.depth.clear_value = g_state.clear_depth;
    } else {
        action.depth.load_action = .LOAD;
    }
    if ((g_state.clear_mask & GL_STENCIL_BUFFER_BIT) != 0) {
        action.stencil.load_action = .CLEAR;
        action.stencil.clear_value = g_state.clear_stencil;
    } else {
        action.stencil.load_action = .LOAD;
    }
    g_state.clear_pending = false;
    g_state.clear_mask = 0;
    return action;
}

pub fn useProgram(id: webgl_program.ProgramId) !void {
    const programs = webgl_program.globalProgramTable();
    if (programs.get(id) == null) return error.InvalidProgram;
    g_state.current_program = id;
}

pub fn clearProgram() void {
    g_state.current_program = null;
}

pub fn currentProgram() ?webgl_program.ProgramId {
    return g_state.current_program;
}

pub fn getAttribLocation(id: webgl_program.ProgramId, name: []const u8) !i32 {
    const programs = webgl_program.globalProgramTable();
    return programs.getAttribLocation(id, name);
}

pub fn enableVertexAttribArray(index: u32) !void {
    const idx = try attrIndex(index);
    g_state.attribs[idx].enabled = true;
}

pub fn disableVertexAttribArray(index: u32) !void {
    const idx = try attrIndex(index);
    g_state.attribs[idx].enabled = false;
}

pub fn vertexAttribPointer(
    index: u32,
    size: u8,
    gl_type: u32,
    normalized: bool,
    stride: u32,
    offset: u32,
    buffer: webgl.BufferId,
) !void {
    const idx = try attrIndex(index);
    if (size == 0 or size > 4) return error.InvalidSize;
    if (typeSize(gl_type) == 0) return error.UnsupportedType;
    const mgr = webgl_state.globalBufferManager();
    if (!mgr.buffers.isValid(buffer)) return error.InvalidBuffer;
    g_state.attribs[idx].size = size;
    g_state.attribs[idx].gl_type = gl_type;
    g_state.attribs[idx].normalized = normalized;
    g_state.attribs[idx].stride = stride;
    g_state.attribs[idx].offset = offset;
    g_state.attribs[idx].buffer = buffer;
}

pub fn drawArrays(mode: u32, first: i32, count: i32) !void {
    if (count <= 0) return;
    const program = g_state.current_program orelse return error.NoProgram;
    if (g_state.command_count >= MaxDrawCommands) return error.CommandQueueFull;
    g_state.commands[g_state.command_count] = .{
        .kind = .arrays,
        .mode = mode,
        .first = first,
        .count = count,
        .index_type = 0,
        .index_offset = 0,
        .program = program,
        .attribs = g_state.attribs,
        .element_buffer = null,
        .viewport = g_state.viewport,
        .scissor = g_state.scissor,
        .scissor_enabled = g_state.scissor_enabled,
        .depth_enabled = g_state.depth_enabled,
        .depth_func = g_state.depth_func,
        .depth_mask = g_state.depth_mask,
        .polygon_offset = g_state.polygon_offset,
        .polygon_offset_enabled = g_state.polygon_offset_enabled,
        .cull_enabled = g_state.cull_enabled,
        .cull_face = g_state.cull_face,
        .front_face = g_state.front_face,
        .blend_enabled = g_state.blend_enabled,
        .blend_src = g_state.blend_src,
        .blend_dst = g_state.blend_dst,
        .blend_src_alpha = g_state.blend_src_alpha,
        .blend_dst_alpha = g_state.blend_dst_alpha,
        .blend_eq = g_state.blend_eq,
        .blend_eq_alpha = g_state.blend_eq_alpha,
        .color_mask = g_state.color_mask,
        .alpha_to_coverage_enabled = g_state.alpha_to_coverage_enabled,
        .stencil_enabled = g_state.stencil_enabled,
        .stencil_func_front = g_state.stencil_func_front,
        .stencil_func_back = g_state.stencil_func_back,
        .stencil_ref_front = g_state.stencil_ref_front,
        .stencil_ref_back = g_state.stencil_ref_back,
        .stencil_read_mask_front = g_state.stencil_read_mask_front,
        .stencil_read_mask_back = g_state.stencil_read_mask_back,
        .stencil_write_mask_front = g_state.stencil_write_mask_front,
        .stencil_write_mask_back = g_state.stencil_write_mask_back,
        .stencil_fail_front = g_state.stencil_fail_front,
        .stencil_zfail_front = g_state.stencil_zfail_front,
        .stencil_zpass_front = g_state.stencil_zpass_front,
        .stencil_fail_back = g_state.stencil_fail_back,
        .stencil_zfail_back = g_state.stencil_zfail_back,
        .stencil_zpass_back = g_state.stencil_zpass_back,
    };
    g_state.command_count += 1;
}

pub fn drawElements(mode: u32, count: i32, index_type: u32, offset: u32, element_buffer: webgl.BufferId) !void {
    if (count <= 0) return;
    const program = g_state.current_program orelse return error.NoProgram;
    if (g_state.command_count >= MaxDrawCommands) return error.CommandQueueFull;
    g_state.commands[g_state.command_count] = .{
        .kind = .elements,
        .mode = mode,
        .first = 0,
        .count = count,
        .index_type = index_type,
        .index_offset = offset,
        .program = program,
        .attribs = g_state.attribs,
        .element_buffer = element_buffer,
        .viewport = g_state.viewport,
        .scissor = g_state.scissor,
        .scissor_enabled = g_state.scissor_enabled,
        .depth_enabled = g_state.depth_enabled,
        .depth_func = g_state.depth_func,
        .depth_mask = g_state.depth_mask,
        .polygon_offset = g_state.polygon_offset,
        .polygon_offset_enabled = g_state.polygon_offset_enabled,
        .cull_enabled = g_state.cull_enabled,
        .cull_face = g_state.cull_face,
        .front_face = g_state.front_face,
        .blend_enabled = g_state.blend_enabled,
        .blend_src = g_state.blend_src,
        .blend_dst = g_state.blend_dst,
        .blend_src_alpha = g_state.blend_src_alpha,
        .blend_dst_alpha = g_state.blend_dst_alpha,
        .blend_eq = g_state.blend_eq,
        .blend_eq_alpha = g_state.blend_eq_alpha,
        .color_mask = g_state.color_mask,
        .alpha_to_coverage_enabled = g_state.alpha_to_coverage_enabled,
        .stencil_enabled = g_state.stencil_enabled,
        .stencil_func_front = g_state.stencil_func_front,
        .stencil_func_back = g_state.stencil_func_back,
        .stencil_ref_front = g_state.stencil_ref_front,
        .stencil_ref_back = g_state.stencil_ref_back,
        .stencil_read_mask_front = g_state.stencil_read_mask_front,
        .stencil_read_mask_back = g_state.stencil_read_mask_back,
        .stencil_write_mask_front = g_state.stencil_write_mask_front,
        .stencil_write_mask_back = g_state.stencil_write_mask_back,
        .stencil_fail_front = g_state.stencil_fail_front,
        .stencil_zfail_front = g_state.stencil_zfail_front,
        .stencil_zpass_front = g_state.stencil_zpass_front,
        .stencil_fail_back = g_state.stencil_fail_back,
        .stencil_zfail_back = g_state.stencil_zfail_back,
        .stencil_zpass_back = g_state.stencil_zpass_back,
    };
    g_state.command_count += 1;
}

fn validateCommand(
    cmd: *const DrawCommand,
    mgr: *webgl_state.BufferManager,
    programs: *webgl_program.ProgramTable,
) !*const webgl_program.Program {
    const prog = programs.get(cmd.program) orelse return error.InvalidProgram;
    if (!prog.linked) return error.ProgramNotLinked;
    if (!programs.ensureBackendShader(cmd.program)) return error.ShaderNotReady;
    if (mapPrimitive(cmd.mode) == null) return error.InvalidPrimitive;

    var slot_buffers: [MaxVertexBuffers]?webgl.BufferId = [_]?webgl.BufferId{null} ** MaxVertexBuffers;
    var slot_strides: [MaxVertexBuffers]u32 = [_]u32{0} ** MaxVertexBuffers;
    var slot_count: usize = 0;

    for (cmd.attribs, 0..) |attrib, attr_index| {
        _ = attr_index;
        if (!attrib.enabled) continue;
        const buf_id = attrib.buffer orelse return error.MissingVertexBuffer;
        if (mapVertexFormat(attrib.size, attrib.gl_type, attrib.normalized) == null) {
            return error.InvalidAttribFormat;
        }

        var slot: ?usize = null;
        for (slot_buffers, 0..) |maybe_buf, sidx| {
            if (maybe_buf != null and maybe_buf.? == buf_id) {
                slot = sidx;
                break;
            }
        }
        if (slot == null) {
            if (slot_count >= MaxVertexBuffers) return error.TooManyVertexBuffers;
            slot = slot_count;
            slot_buffers[slot_count] = buf_id;
            slot_count += 1;
        }
        const slot_idx = slot.?;

        var stride = attrib.stride;
        if (stride == 0) {
            const elem_size = typeSize(attrib.gl_type);
            if (elem_size == 0) return error.InvalidStride;
            stride = attrib.size * elem_size;
        }
        if (stride == 0) return error.InvalidStride;
        if (slot_strides[slot_idx] == 0) {
            slot_strides[slot_idx] = stride;
        } else if (slot_strides[slot_idx] != stride) {
            return error.InconsistentStride;
        }

        const buf = mgr.buffers.get(buf_id) orelse return error.InvalidBuffer;
        if (buf.backend == 0) return error.BufferNotReady;
    }

    if (cmd.kind == .elements) {
        if (mapIndexType(cmd.index_type) == null) return error.InvalidIndexType;
        const eid = cmd.element_buffer orelse return error.MissingIndexBuffer;
        const buf = mgr.buffers.get(eid) orelse return error.InvalidBuffer;
        if (buf.backend == 0) return error.BufferNotReady;
    }

    return prog;
}

pub fn flush() void {
    if (g_state.command_count == 0) return;
    log.debug("flush: processing {d} commands", .{g_state.command_count});
    defer g_state.command_count = 0;
    if (!sg.isvalid()) return;

    const mgr = webgl_state.globalBufferManager();
    const programs = webgl_program.globalProgramTable();

    for (g_state.commands[0..g_state.command_count], 0..) |cmd, cmd_idx| {
        const prog = validateCommand(&cmd, mgr, programs) catch |err| {
            log.debug("flush: command {d} validation failed: {s}", .{ cmd_idx, @errorName(err) });
            continue;
        };

        const vp = sanitizeRect(cmd.viewport);
        sg.applyViewport(vp[0], vp[1], vp[2], vp[3], false);
        const scissor = if (cmd.scissor_enabled) sanitizeRect(cmd.scissor) else vp;
        sg.applyScissorRect(scissor[0], scissor[1], scissor[2], scissor[3], false);

        var pip_desc = sg.PipelineDesc{};
        pip_desc.shader = prog.backend_shader;
        pip_desc.primitive_type = mapPrimitive(cmd.mode) orelse continue;
        if (cmd.kind == .elements) {
            pip_desc.index_type = mapIndexType(cmd.index_type) orelse continue;
        }
        pip_desc.cull_mode = mapCullMode(cmd.cull_enabled, cmd.cull_face);
        pip_desc.face_winding = mapFaceWinding(cmd.front_face);
        pip_desc.depth.compare = if (cmd.depth_enabled) mapCompare(cmd.depth_func) else .ALWAYS;
        pip_desc.depth.write_enabled = cmd.depth_mask;
        if (cmd.polygon_offset_enabled) {
            pip_desc.depth.bias = cmd.polygon_offset[1];
            pip_desc.depth.bias_slope_scale = cmd.polygon_offset[0];
        }
        pip_desc.stencil.enabled = cmd.stencil_enabled;
        pip_desc.stencil.read_mask = cmd.stencil_read_mask_front;
        pip_desc.stencil.write_mask = cmd.stencil_write_mask_front;
        pip_desc.stencil.ref = cmd.stencil_ref_front;
        pip_desc.stencil.front.compare = mapCompare(cmd.stencil_func_front);
        pip_desc.stencil.front.fail_op = mapStencilOp(cmd.stencil_fail_front);
        pip_desc.stencil.front.depth_fail_op = mapStencilOp(cmd.stencil_zfail_front);
        pip_desc.stencil.front.pass_op = mapStencilOp(cmd.stencil_zpass_front);
        pip_desc.stencil.back.compare = mapCompare(cmd.stencil_func_back);
        pip_desc.stencil.back.fail_op = mapStencilOp(cmd.stencil_fail_back);
        pip_desc.stencil.back.depth_fail_op = mapStencilOp(cmd.stencil_zfail_back);
        pip_desc.stencil.back.pass_op = mapStencilOp(cmd.stencil_zpass_back);
        pip_desc.color_count = 1;
        pip_desc.colors[0].write_mask = mapColorMask(cmd.color_mask);
        pip_desc.colors[0].blend.enabled = cmd.blend_enabled;
        pip_desc.colors[0].blend.src_factor_rgb = mapBlendFactor(cmd.blend_src);
        pip_desc.colors[0].blend.dst_factor_rgb = mapBlendFactor(cmd.blend_dst);
        pip_desc.colors[0].blend.op_rgb = mapBlendOp(cmd.blend_eq);
        pip_desc.colors[0].blend.src_factor_alpha = mapBlendFactor(cmd.blend_src_alpha);
        pip_desc.colors[0].blend.dst_factor_alpha = mapBlendFactor(cmd.blend_dst_alpha);
        pip_desc.colors[0].blend.op_alpha = mapBlendOp(cmd.blend_eq_alpha);
        pip_desc.alpha_to_coverage_enabled = cmd.alpha_to_coverage_enabled;

        var bindings = sg.Bindings{};
        var slot_buffers: [MaxVertexBuffers]?webgl.BufferId = [_]?webgl.BufferId{null} ** MaxVertexBuffers;
        var slot_strides: [MaxVertexBuffers]u32 = [_]u32{0} ** MaxVertexBuffers;
        var slot_count: usize = 0;
        var max_attr_index: ?usize = null;

        for (cmd.attribs, 0..) |attrib, attr_index| {
            if (!attrib.enabled) continue;
            const buf_id = attrib.buffer orelse continue;

            var slot: ?usize = null;
            for (slot_buffers, 0..) |maybe_buf, sidx| {
                if (maybe_buf != null and maybe_buf.? == buf_id) {
                    slot = sidx;
                    break;
                }
            }
            if (slot == null) {
                if (slot_count >= MaxVertexBuffers) continue;
                slot = slot_count;
                slot_buffers[slot_count] = buf_id;
                slot_count += 1;
            }
            const slot_idx = slot.?;

            const format = mapVertexFormat(attrib.size, attrib.gl_type, attrib.normalized) orelse continue;
            pip_desc.layout.attrs[attr_index].buffer_index = @intCast(slot_idx);
            pip_desc.layout.attrs[attr_index].offset = @intCast(attrib.offset);
            pip_desc.layout.attrs[attr_index].format = format;
            if (max_attr_index == null or attr_index > max_attr_index.?) {
                max_attr_index = attr_index;
            }

            var stride = attrib.stride;
            if (stride == 0) {
                stride = attrib.size * typeSize(attrib.gl_type);
            }
            if (slot_strides[slot_idx] == 0) {
                slot_strides[slot_idx] = stride;
            } else if (slot_strides[slot_idx] != stride) {
                continue;
            }
        }

        if (slot_count > 0) {
            if (max_attr_index) |max_idx| {
                for (0..max_idx + 1) |idx| {
                    if (pip_desc.layout.attrs[idx].format == .INVALID) {
                        pip_desc.layout.attrs[idx].buffer_index = 0;
                        pip_desc.layout.attrs[idx].offset = 0;
                        pip_desc.layout.attrs[idx].format = .FLOAT;
                    }
                }
            }
        }

        for (slot_buffers, 0..) |maybe_buf, sidx| {
            if (maybe_buf) |buf_id| {
                const buf = mgr.buffers.get(buf_id) orelse continue;
                if (buf.backend == 0) continue;
                bindings.vertex_buffers[sidx] = .{ .id = buf.backend };
                if (slot_strides[sidx] != 0) {
                    pip_desc.layout.buffers[sidx].stride = @intCast(slot_strides[sidx]);
                }
            }
        }

        if (cmd.kind == .elements) {
            if (cmd.element_buffer) |eid| {
                const buf = mgr.buffers.get(eid) orelse continue;
                if (buf.backend == 0) continue;
                bindings.index_buffer = .{ .id = buf.backend };
                bindings.index_buffer_offset = @intCast(cmd.index_offset);
            } else {
                continue;
            }
        }

        const key = pipelineKey(prog.backend_shader.id, &pip_desc);
        const pip = getCachedPipeline(key, pip_desc) orelse continue;
        sg.applyPipeline(pip);
        sg.applyBindings(bindings);
        log.debug("flush: vs_uniforms.size={d} fs_uniforms.size={d}", .{ prog.vs_uniforms.size, prog.fs_uniforms.size });
        if (prog.vs_uniforms.size > 0) {
            const size = @as(usize, prog.vs_uniforms.size);
            const slice = prog.vs_uniforms.buffer[0..size];
            log.debug("flush: applying VS uniforms, size={d}", .{size});
            sg.applyUniforms(0, .{ .ptr = slice.ptr, .size = slice.len });
        }
        if (prog.fs_uniforms.size > 0) {
            const size = @as(usize, prog.fs_uniforms.size);
            const slice = prog.fs_uniforms.buffer[0..size];
            log.debug("flush: applying FS uniforms, size={d}", .{size});
            sg.applyUniforms(1, .{ .ptr = slice.ptr, .size = slice.len });
        }
        const base = if (cmd.kind == .arrays) cmd.first else 0;
        const base_u32: u32 = if (base < 0) 0 else @intCast(base);
        const count_u32: u32 = if (cmd.count < 0) 0 else @intCast(cmd.count);
        if (count_u32 == 0) continue;
        log.debug("flush: sg.draw base={d} count={d} kind={s}", .{ base_u32, count_u32, @tagName(cmd.kind) });
        sg.draw(base_u32, count_u32, 1);
    }
}

fn clearPipelineCache() void {
    if (!sg.isvalid()) {
        return;
    }
    for (&g_state.pipeline_cache) |*entry| {
        if (entry.valid and entry.pipeline.id != 0) {
            sg.destroyPipeline(entry.pipeline);
        }
        entry.* = .{};
    }
}

fn getCachedPipeline(key: u64, desc: sg.PipelineDesc) ?sg.Pipeline {
    for (g_state.pipeline_cache) |entry| {
        if (entry.valid and entry.key == key) {
            return entry.pipeline;
        }
    }

    const pip = sg.makePipeline(desc);
    const state = sg.queryPipelineState(pip);
    if (state != .VALID) {
        log.debug("getCachedPipeline: failed to create pipeline, state={s}", .{@tagName(state)});
        sg.destroyPipeline(pip);
        return null;
    }
    log.debug("getCachedPipeline: created new pipeline, depth_compare={s} cull={s}", .{ @tagName(desc.depth.compare), @tagName(desc.cull_mode) });

    const slot = g_state.pipeline_cache_next % MaxPipelineCacheEntries;
    g_state.pipeline_cache_next += 1;
    if (g_state.pipeline_cache[slot].valid and g_state.pipeline_cache[slot].pipeline.id != 0) {
        sg.destroyPipeline(g_state.pipeline_cache[slot].pipeline);
    }
    g_state.pipeline_cache[slot] = .{
        .key = key,
        .pipeline = pip,
        .valid = true,
    };
    return pip;
}

fn pipelineKey(shader_id: u32, desc: *const sg.PipelineDesc) u64 {
    var hash: u64 = 1469598103934665603;
    hash = hashU64(hash, shader_id);
    hash = hashEnum(hash, desc.primitive_type);
    hash = hashEnum(hash, desc.index_type);
    hash = hashEnum(hash, desc.cull_mode);
    hash = hashEnum(hash, desc.face_winding);
    hash = hashEnum(hash, desc.depth.compare);
    hash = hashBool(hash, desc.depth.write_enabled);
    hash = hashF32(hash, desc.depth.bias);
    hash = hashF32(hash, desc.depth.bias_slope_scale);
    hash = hashBool(hash, desc.stencil.enabled);
    hash = hashU64(hash, @intCast(desc.stencil.read_mask));
    hash = hashU64(hash, @intCast(desc.stencil.write_mask));
    hash = hashU64(hash, @intCast(desc.stencil.ref));
    hash = hashEnum(hash, desc.stencil.front.compare);
    hash = hashEnum(hash, desc.stencil.front.fail_op);
    hash = hashEnum(hash, desc.stencil.front.depth_fail_op);
    hash = hashEnum(hash, desc.stencil.front.pass_op);
    hash = hashEnum(hash, desc.stencil.back.compare);
    hash = hashEnum(hash, desc.stencil.back.fail_op);
    hash = hashEnum(hash, desc.stencil.back.depth_fail_op);
    hash = hashEnum(hash, desc.stencil.back.pass_op);
    hash = hashEnum(hash, desc.colors[0].write_mask);
    hash = hashBool(hash, desc.colors[0].blend.enabled);
    hash = hashEnum(hash, desc.colors[0].blend.src_factor_rgb);
    hash = hashEnum(hash, desc.colors[0].blend.dst_factor_rgb);
    hash = hashEnum(hash, desc.colors[0].blend.op_rgb);
    hash = hashEnum(hash, desc.colors[0].blend.src_factor_alpha);
    hash = hashEnum(hash, desc.colors[0].blend.dst_factor_alpha);
    hash = hashEnum(hash, desc.colors[0].blend.op_alpha);
    hash = hashBool(hash, desc.alpha_to_coverage_enabled);
    for (desc.layout.attrs) |attr| {
        hash = hashEnum(hash, attr.format);
        hash = hashU64(hash, @intCast(attr.offset));
        hash = hashU64(hash, @intCast(attr.buffer_index));
    }
    for (desc.layout.buffers) |buf_layout| {
        hash = hashU64(hash, @intCast(buf_layout.stride));
    }
    return hash;
}

fn hashU64(hash: u64, value: u64) u64 {
    return (hash ^ value) *% 1099511628211;
}

fn hashEnum(hash: u64, value: anytype) u64 {
    return hashU64(hash, @as(u64, @intCast(@intFromEnum(value))));
}

fn hashBool(hash: u64, value: bool) u64 {
    return hashU64(hash, if (value) 1 else 0);
}

fn hashF32(hash: u64, value: f32) u64 {
    const bits: u32 = @bitCast(value);
    return hashU64(hash, bits);
}

fn sanitizeRect(rect: [4]i32) [4]i32 {
    var out = rect;
    if (out[2] < 0) out[2] = 0;
    if (out[3] < 0) out[3] = 0;
    return out;
}

fn clampStencilU8(value: i32) u8 {
    if (value < 0) return 0;
    if (value > 255) return 255;
    return @intCast(value);
}

fn attrIndex(index: u32) !usize {
    if (index >= MaxVertexAttribs) return error.InvalidAttrib;
    return @intCast(index);
}

fn typeSize(gl_type: u32) u32 {
    return switch (gl_type) {
        5126 => 4, // FLOAT
        5120 => 1, // BYTE
        5121 => 1, // UNSIGNED_BYTE
        5122 => 2, // SHORT
        5123 => 2, // UNSIGNED_SHORT
        5124 => 4, // INT
        5125 => 4, // UNSIGNED_INT
        else => 0,
    };
}

fn mapVertexFormat(size: u8, gl_type: u32, normalized: bool) ?sg.VertexFormat {
    return switch (gl_type) {
        5126 => switch (size) { // FLOAT
            1 => .FLOAT,
            2 => .FLOAT2,
            3 => .FLOAT3,
            4 => .FLOAT4,
            else => null,
        },
        5121 => if (normalized) switch (size) { // UNSIGNED_BYTE
            4 => .UBYTE4N,
            else => null,
        } else switch (size) {
            4 => .UBYTE4,
            else => null,
        },
        5120 => if (normalized) switch (size) { // BYTE
            4 => .BYTE4N,
            else => null,
        } else switch (size) {
            4 => .BYTE4,
            else => null,
        },
        5123 => if (normalized) switch (size) { // UNSIGNED_SHORT
            2 => .USHORT2N,
            4 => .USHORT4N,
            else => null,
        } else switch (size) {
            2 => .USHORT2,
            4 => .USHORT4,
            else => null,
        },
        5122 => if (normalized) switch (size) { // SHORT
            2 => .SHORT2N,
            4 => .SHORT4N,
            else => null,
        } else switch (size) {
            2 => .SHORT2,
            4 => .SHORT4,
            else => null,
        },
        else => null,
    };
}

fn mapIndexType(gl_type: u32) ?sg.IndexType {
    return switch (gl_type) {
        5123 => .UINT16,
        5125 => .UINT32,
        else => null,
    };
}

fn mapPrimitive(gl_mode: u32) ?sg.PrimitiveType {
    return switch (gl_mode) {
        0x0000 => .POINTS,
        0x0001 => .LINES,
        0x0004 => .TRIANGLES,
        0x0005 => .TRIANGLE_STRIP,
        else => null,
    };
}

fn mapCompare(gl_func: u32) sg.CompareFunc {
    return switch (gl_func) {
        GL_NEVER => .NEVER,
        GL_LESS => .LESS,
        GL_EQUAL => .EQUAL,
        GL_LEQUAL => .LESS_EQUAL,
        GL_GREATER => .GREATER,
        GL_NOTEQUAL => .NOT_EQUAL,
        GL_GEQUAL => .GREATER_EQUAL,
        GL_ALWAYS => .ALWAYS,
        else => .ALWAYS,
    };
}

fn mapCullMode(enabled: bool, face: u32) sg.CullMode {
    if (!enabled) return .NONE;
    return switch (face) {
        GL_FRONT => .FRONT,
        GL_BACK => .BACK,
        GL_FRONT_AND_BACK => .FRONT,
        else => .BACK,
    };
}

fn mapFaceWinding(front_face: u32) sg.FaceWinding {
    return switch (front_face) {
        GL_CCW => .CCW,
        GL_CW => .CW,
        else => .CCW,
    };
}

fn mapBlendFactor(gl_factor: u32) sg.BlendFactor {
    return switch (gl_factor) {
        GL_ZERO => .ZERO,
        GL_ONE => .ONE,
        GL_SRC_COLOR => .SRC_COLOR,
        GL_ONE_MINUS_SRC_COLOR => .ONE_MINUS_SRC_COLOR,
        GL_SRC_ALPHA => .SRC_ALPHA,
        GL_ONE_MINUS_SRC_ALPHA => .ONE_MINUS_SRC_ALPHA,
        GL_DST_COLOR => .DST_COLOR,
        GL_ONE_MINUS_DST_COLOR => .ONE_MINUS_DST_COLOR,
        GL_DST_ALPHA => .DST_ALPHA,
        GL_ONE_MINUS_DST_ALPHA => .ONE_MINUS_DST_ALPHA,
        GL_CONSTANT_COLOR => .BLEND_COLOR,
        GL_ONE_MINUS_CONSTANT_COLOR => .ONE_MINUS_BLEND_COLOR,
        GL_CONSTANT_ALPHA => .BLEND_ALPHA,
        GL_ONE_MINUS_CONSTANT_ALPHA => .ONE_MINUS_BLEND_ALPHA,
        else => .ONE,
    };
}

fn mapBlendOp(gl_op: u32) sg.BlendOp {
    return switch (gl_op) {
        GL_FUNC_ADD => .ADD,
        GL_FUNC_SUBTRACT => .SUBTRACT,
        GL_FUNC_REVERSE_SUBTRACT => .REVERSE_SUBTRACT,
        else => .ADD,
    };
}

fn mapStencilOp(gl_op: u32) sg.StencilOp {
    return switch (gl_op) {
        GL_KEEP => .KEEP,
        GL_ZERO => .ZERO,
        GL_REPLACE => .REPLACE,
        GL_INCR => .INCR_CLAMP,
        GL_DECR => .DECR_CLAMP,
        GL_INVERT => .INVERT,
        GL_INCR_WRAP => .INCR_WRAP,
        GL_DECR_WRAP => .DECR_WRAP,
        else => .KEEP,
    };
}

fn mapColorMask(mask: [4]bool) sg.ColorMask {
    var bits: u8 = 0;
    if (mask[0]) bits |= 1;
    if (mask[1]) bits |= 2;
    if (mask[2]) bits |= 4;
    if (mask[3]) bits |= 8;
    if (bits == 0) return .NONE;
    return @enumFromInt(@as(i32, bits));
}

// =============================================================================
// Tests
// =============================================================================

test "Draw state queues commands" {
    reset();
    const programs = webgl_program.globalProgramTable();
    programs.reset();
    defer programs.reset();

    const pid = try programs.alloc();
    try useProgram(pid);
    try enableVertexAttribArray(0);
    try drawArrays(0x0004, 0, 3);
    try testing.expectEqual(@as(usize, 1), g_state.command_count);
}

test "Draw state captures depth cull blend" {
    reset();
    const programs = webgl_program.globalProgramTable();
    programs.reset();
    defer programs.reset();

    setDepthTestEnabled(true);
    setDepthFunc(GL_GREATER);
    setDepthMask(false);
    setPolygonOffset(1.5, 2.0);
    setPolygonOffsetEnabled(true);
    setCullEnabled(true);
    setCullFace(GL_FRONT);
    setFrontFace(GL_CW);
    setBlendEnabled(true);
    setBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ZERO);
    setBlendEquationSeparate(GL_FUNC_SUBTRACT, GL_FUNC_REVERSE_SUBTRACT);
    setColorMask(true, false, true, false);
    setAlphaToCoverageEnabled(true);

    const pid = try programs.alloc();
    try useProgram(pid);
    try drawArrays(0x0004, 0, 3);

    const cmd = g_state.commands[0];
    try testing.expect(cmd.depth_enabled);
    try testing.expectEqual(GL_GREATER, cmd.depth_func);
    try testing.expectEqual(false, cmd.depth_mask);
    try testing.expectEqual(@as(f32, 1.5), cmd.polygon_offset[0]);
    try testing.expectEqual(@as(f32, 2.0), cmd.polygon_offset[1]);
    try testing.expect(cmd.polygon_offset_enabled);
    try testing.expect(cmd.cull_enabled);
    try testing.expectEqual(GL_FRONT, cmd.cull_face);
    try testing.expectEqual(GL_CW, cmd.front_face);
    try testing.expect(cmd.blend_enabled);
    try testing.expectEqual(GL_SRC_ALPHA, cmd.blend_src);
    try testing.expectEqual(GL_ONE_MINUS_SRC_ALPHA, cmd.blend_dst);
    try testing.expectEqual(GL_ONE, cmd.blend_src_alpha);
    try testing.expectEqual(GL_ZERO, cmd.blend_dst_alpha);
    try testing.expectEqual(GL_FUNC_SUBTRACT, cmd.blend_eq);
    try testing.expectEqual(GL_FUNC_REVERSE_SUBTRACT, cmd.blend_eq_alpha);
    try testing.expectEqual([4]bool{ true, false, true, false }, cmd.color_mask);
    try testing.expect(cmd.alpha_to_coverage_enabled);
}

test "Draw state captures stencil" {
    reset();
    const programs = webgl_program.globalProgramTable();
    programs.reset();
    defer programs.reset();

    setStencilEnabled(true);
    setStencilFuncSeparate(GL_FRONT, GL_ALWAYS, 1, 0xAA);
    setStencilFuncSeparate(GL_BACK, GL_NEVER, 2, 0x0F);
    setStencilMaskSeparate(GL_FRONT, 0x0F);
    setStencilMaskSeparate(GL_BACK, 0xF0);
    setStencilOpSeparate(GL_FRONT, GL_KEEP, GL_INCR, GL_DECR);
    setStencilOpSeparate(GL_BACK, GL_REPLACE, GL_INVERT, GL_INCR_WRAP);

    const pid = try programs.alloc();
    try useProgram(pid);
    try drawArrays(0x0004, 0, 3);

    const cmd = g_state.commands[0];
    try testing.expect(cmd.stencil_enabled);
    try testing.expectEqual(GL_ALWAYS, cmd.stencil_func_front);
    try testing.expectEqual(GL_NEVER, cmd.stencil_func_back);
    try testing.expectEqual(@as(u8, 1), cmd.stencil_ref_front);
    try testing.expectEqual(@as(u8, 2), cmd.stencil_ref_back);
    try testing.expectEqual(@as(u8, 0xAA), cmd.stencil_read_mask_front);
    try testing.expectEqual(@as(u8, 0x0F), cmd.stencil_read_mask_back);
    try testing.expectEqual(@as(u8, 0x0F), cmd.stencil_write_mask_front);
    try testing.expectEqual(@as(u8, 0xF0), cmd.stencil_write_mask_back);
    try testing.expectEqual(GL_KEEP, cmd.stencil_fail_front);
    try testing.expectEqual(GL_INCR, cmd.stencil_zfail_front);
    try testing.expectEqual(GL_DECR, cmd.stencil_zpass_front);
    try testing.expectEqual(GL_REPLACE, cmd.stencil_fail_back);
    try testing.expectEqual(GL_INVERT, cmd.stencil_zfail_back);
    try testing.expectEqual(GL_INCR_WRAP, cmd.stencil_zpass_back);
}

test "Pipeline key includes depth cull blend state" {
    var desc = sg.PipelineDesc{};
    desc.primitive_type = .TRIANGLES;
    const base = pipelineKey(1, &desc);

    desc.depth.compare = .LESS;
    desc.depth.write_enabled = true;
    const depth_key = pipelineKey(1, &desc);
    try testing.expect(depth_key != base);

    desc = sg.PipelineDesc{};
    desc.primitive_type = .TRIANGLES;
    desc.cull_mode = .BACK;
    const cull_key = pipelineKey(1, &desc);
    try testing.expect(cull_key != base);

    desc = sg.PipelineDesc{};
    desc.primitive_type = .TRIANGLES;
    desc.colors[0].blend.enabled = true;
    desc.colors[0].blend.src_factor_rgb = .SRC_ALPHA;
    desc.colors[0].blend.dst_factor_rgb = .ONE_MINUS_SRC_ALPHA;
    const blend_key = pipelineKey(1, &desc);
    try testing.expect(blend_key != base);

    desc = sg.PipelineDesc{};
    desc.primitive_type = .TRIANGLES;
    desc.stencil.enabled = true;
    desc.stencil.front.compare = .LESS;
    const stencil_key = pipelineKey(1, &desc);
    try testing.expect(stencil_key != base);
}
