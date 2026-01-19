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

pub const MaxVertexAttribs: usize = 16;
pub const MaxDrawCommands: usize = 64;
const MaxVertexBuffers: usize = sg.Bindings.vertex_buffers.len;
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
};

const DrawState = struct {
    current_program: ?webgl_program.ProgramId = null,
    attribs: [MaxVertexAttribs]VertexAttrib = [_]VertexAttrib{.{}} ** MaxVertexAttribs,
    commands: [MaxDrawCommands]DrawCommand = undefined,
    command_count: usize = 0,
    pipeline_cache: [MaxPipelineCacheEntries]PipelineCacheEntry = [_]PipelineCacheEntry{.{}} ** MaxPipelineCacheEntries,
    pipeline_cache_next: usize = 0,
};

var g_state: DrawState = .{};

pub fn reset() void {
    clearPipelineCache();
    g_state = .{};
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
    };
    g_state.command_count += 1;
}

fn validateCommand(
    cmd: *const DrawCommand,
    mgr: *const webgl_state.BufferManager,
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
    defer g_state.command_count = 0;
    if (!sg.isvalid()) return;

    const mgr = webgl_state.globalBufferManager();
    const programs = webgl_program.globalProgramTable();

    for (g_state.commands[0..g_state.command_count]) |cmd| {
        const prog = validateCommand(&cmd, mgr, programs) catch {
            continue;
        };

        var pip_desc = sg.PipelineDesc{};
        pip_desc.shader = prog.backend_shader;
        pip_desc.primitive_type = mapPrimitive(cmd.mode) orelse continue;
        if (cmd.kind == .elements) {
            pip_desc.index_type = mapIndexType(cmd.index_type) orelse continue;
        }

        var bindings = sg.Bindings{};
        var slot_buffers: [MaxVertexBuffers]?webgl.BufferId = [_]?webgl.BufferId{null} ** MaxVertexBuffers;
        var slot_strides: [MaxVertexBuffers]u32 = [_]u32{0} ** MaxVertexBuffers;
        var slot_count: usize = 0;

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
        if (prog.vs_uniforms.size > 0) {
            const size = @as(usize, prog.vs_uniforms.size);
            const slice = prog.vs_uniforms.buffer[0..size];
            sg.applyUniforms(0, .{ .ptr = slice.ptr, .size = slice.len });
        }
        if (prog.fs_uniforms.size > 0) {
            const size = @as(usize, prog.fs_uniforms.size);
            const slice = prog.fs_uniforms.buffer[0..size];
            sg.applyUniforms(1, .{ .ptr = slice.ptr, .size = slice.len });
        }
        const base = if (cmd.kind == .arrays) cmd.first else 0;
        sg.draw(base, cmd.count, 1);
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
    if (sg.queryPipelineState(pip) != .VALID) {
        sg.destroyPipeline(pip);
        return null;
    }

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
    hash = hashU64(hash, @intFromEnum(desc.primitive_type));
    hash = hashU64(hash, @intFromEnum(desc.index_type));
    for (desc.layout.attrs) |attr| {
        hash = hashU64(hash, @intFromEnum(attr.format));
        hash = hashU64(hash, @intCast(attr.offset));
        hash = hashU64(hash, @intCast(attr.buffer_index));
    }
    for (desc.layout.buffers) |buf_layout| {
        hash = hashU64(hash, @intCast(buf_layout.stride));
    }
    return hash;
}

fn hashU64(hash: u64, value: u64) u64 {
    return (hash ^ value) * 1099511628211;
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
