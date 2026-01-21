//! WebGL program handle tables (Phase 2.3)
//!
//! TDD slice: program creation, attachment, and link status tracking.

const std = @import("std");
const testing = std.testing;
const shader = @import("webgl_shader.zig");
const gl_uniforms = @import("gl_uniforms.zig");
const sokol = @import("sokol");
const sg = sokol.gfx;

const log = std.log.scoped(.webgl_program);

/// Internal uniform type enum that extends Sokol's UniformType with MAT2/MAT3 support.
/// Sokol only has MAT4; we handle MAT2/MAT3 by mapping them to FLOAT4 arrays in shader descriptors.
pub const UniformType = enum(u8) {
    INVALID = 0,
    FLOAT = 1,
    FLOAT2 = 2,
    FLOAT3 = 3,
    FLOAT4 = 4,
    INT = 5,
    INT2 = 6,
    INT3 = 7,
    INT4 = 8,
    MAT2 = 9,
    MAT3 = 10,
    MAT4 = 11,

    /// Convert to Sokol UniformType.
    /// Note: Sokol only has FLOAT, FLOAT2, FLOAT3, FLOAT4, INT, INT2, INT3, INT4, MAT4
    /// For mat2/mat3, we keep them as single units since that's how WebGL GLSL defines them.
    pub fn toSokol(self: UniformType) sg.UniformType {
        return switch (self) {
            .INVALID => .INVALID,
            .FLOAT => .FLOAT,
            .FLOAT2 => .FLOAT2,
            .FLOAT3 => .FLOAT3,
            .FLOAT4 => .FLOAT4,
            .INT => .INT,
            .INT2 => .INT2,
            .INT3 => .INT3,
            .INT4 => .INT4,
            // Note: Sokol doesn't have MAT2/MAT3, but we use FLOAT4 as a placeholder
            // The actual uniform setting is handled separately by WebGL-style calls
            .MAT2 => .FLOAT4,
            .MAT3 => .FLOAT4,
            .MAT4 => .MAT4,
        };
    }

    /// Get the effective array count for Sokol shader descriptor size validation.
    /// MAT2 becomes FLOAT4[2] (32 bytes), MAT3 becomes FLOAT4[3] (48 bytes).
    /// This ensures the glsl_uniform sizes sum to the uniform block size.
    /// Note: We use dummy names for MAT2/MAT3 so Sokol doesn't try to set them;
    /// they are set via direct GL calls instead.
    pub fn sokolArrayCount(self: UniformType, array_count: u16) u16 {
        const base: u16 = if (array_count == 0) 1 else array_count;
        return switch (self) {
            .MAT2 => base * 2, // 2 columns of vec4
            .MAT3 => base * 3, // 3 columns of vec4
            else => base,
        };
    }

    /// Check if this is a matrix type
    pub fn isMatrix(self: UniformType) bool {
        return switch (self) {
            .MAT2, .MAT3, .MAT4 => true,
            else => false,
        };
    }
};

pub const MaxPrograms: usize = 64;
pub const MaxProgramInfoLogBytes: usize = 4 * 1024;
pub const MaxProgramAttrs: usize = 16;
pub const MaxProgramUniforms: usize = 128;
pub const MaxTranslatedShaderBytes: usize = shader.MaxShaderSourceBytes + 4096;
pub const MaxAttrNameBytes: usize = 64;
pub const MaxUniformNameBytes: usize = 64;
pub const MaxUniformBlockBytes: usize = MaxProgramUniforms * 64;
pub const MaxUniformArrayCount: u16 = 16;
pub const MaxProgramSamplers: usize = 12;

pub const ProgramId = packed struct(u32) {
    index: u16,
    generation: u16,
};

const UniformEntry = struct {
    name_len: u8,
    name_bytes: [MaxUniformNameBytes]u8,
    utype: UniformType,
    array_count: u16,
    offset: u32,
    stride: u32,
    size: u32,
};

const UniformBlock = struct {
    size: u32,
    count: u8,
    items: [MaxProgramUniforms]UniformEntry,
    buffer: [MaxUniformBlockBytes]u8,
};

const SamplerKind = enum {
    sampler2d,
    samplerCube,
};

const SamplerEntry = struct {
    name_len: u8,
    name_bytes: [MaxUniformNameBytes]u8,
    kind: SamplerKind,
    stage: UniformStage,
    array_count: u16,
    units: [MaxUniformArrayCount]i32,
    gl_location: i32, // Cached GL uniform location (-1 if not found)
    dirty: bool, // True if unit needs to be set via glUniform1i
};

/// Tracks mat2/mat3 uniforms that need direct GL calls (Sokol only supports mat4).
const MatrixUniform = struct {
    name_len: u8,
    name_bytes: [MaxUniformNameBytes]u8,
    utype: UniformType, // MAT2 or MAT3
    stage: UniformStage,
    offset: u32, // Offset in the uniform block buffer
    gl_location: i32, // GL uniform location (-1 if not found)
    array_count: u16,
};

pub const MaxMatrixUniforms: usize = 16;

pub const Program = struct {
    id: ProgramId,
    linked: bool,
    vertex_shader: ?shader.ShaderId,
    fragment_shader: ?shader.ShaderId,
    info_log_len: u32,
    info_log_bytes: [MaxProgramInfoLogBytes]u8,
    backend_shader: sg.Shader,
    vertex_source_len: u32,
    vertex_source: [MaxTranslatedShaderBytes]u8,
    fragment_source_len: u32,
    fragment_source: [MaxTranslatedShaderBytes]u8,
    attr_count: u8,
    attr_name_lens: [MaxProgramAttrs]u8,
    attr_names: [MaxProgramAttrs][MaxAttrNameBytes]u8,
    vs_uniforms: UniformBlock,
    fs_uniforms: UniformBlock,
    sampler_count: u8,
    samplers: [MaxProgramSamplers]SamplerEntry,
    link_version: u32,
    /// Mat2/mat3 uniforms that need direct GL calls (Sokol only supports mat4)
    mat_uniform_count: u8,
    mat_uniforms: [MaxMatrixUniforms]MatrixUniform,
    /// GL program ID for direct GL uniform calls
    gl_program: u32,

    /// Count the union of VS and FS uniforms (no duplicates).
    pub fn countUniformUnion(self: *const Program) u32 {
        var count: u32 = self.vs_uniforms.count;
        // Add FS uniforms that are not in VS
        const fs_count: usize = @intCast(self.fs_uniforms.count);
        for (self.fs_uniforms.items[0..fs_count]) |fs_item| {
            if (fs_item.name_len == 0) continue;
            const fs_name = fs_item.name_bytes[0..@as(usize, fs_item.name_len)];
            var found_in_vs = false;
            const vs_count: usize = @intCast(self.vs_uniforms.count);
            for (self.vs_uniforms.items[0..vs_count]) |vs_item| {
                if (vs_item.name_len == 0) continue;
                const vs_name = vs_item.name_bytes[0..@as(usize, vs_item.name_len)];
                if (std.mem.eql(u8, fs_name, vs_name)) {
                    found_in_vs = true;
                    break;
                }
            }
            if (!found_in_vs) count += 1;
        }
        return count;
    }

    /// Get uniform at union index. Returns null if out of range.
    /// Union order: all VS uniforms first, then FS uniforms not in VS.
    pub fn getUniformAtUnionIndex(self: *const Program, index: u32) ?*const UniformEntry {
        const vs_count: u32 = self.vs_uniforms.count;
        if (index < vs_count) {
            const item = &self.vs_uniforms.items[@as(usize, index)];
            if (item.name_len == 0) return null;
            return item;
        }
        // Find the (index - vs_count)th FS uniform that's not in VS
        var fs_only_idx: u32 = 0;
        const target_fs_only_idx: u32 = index - vs_count;
        const fs_count: usize = @intCast(self.fs_uniforms.count);
        for (self.fs_uniforms.items[0..fs_count]) |*fs_item| {
            if (fs_item.name_len == 0) continue;
            const fs_name = fs_item.name_bytes[0..@as(usize, fs_item.name_len)];
            var found_in_vs = false;
            const vs_count_usize: usize = @intCast(self.vs_uniforms.count);
            for (self.vs_uniforms.items[0..vs_count_usize]) |vs_item| {
                if (vs_item.name_len == 0) continue;
                const vs_name = vs_item.name_bytes[0..@as(usize, vs_item.name_len)];
                if (std.mem.eql(u8, fs_name, vs_name)) {
                    found_in_vs = true;
                    break;
                }
            }
            if (!found_in_vs) {
                if (fs_only_idx == target_fs_only_idx) {
                    return fs_item;
                }
                fs_only_idx += 1;
            }
        }
        return null;
    }
};

fn zeroedUniformBlock() UniformBlock {
    var block: UniformBlock = undefined;
    @memset(std.mem.asBytes(&block), 0);
    return block;
}

fn zeroedSamplerEntry() SamplerEntry {
    var entry: SamplerEntry = undefined;
    @memset(std.mem.asBytes(&entry), 0);
    entry.array_count = 1;
    entry.gl_location = -1;
    return entry;
}

fn zeroedMatrixUniform() MatrixUniform {
    var uniform: MatrixUniform = undefined;
    @memset(std.mem.asBytes(&uniform), 0);
    uniform.gl_location = -1;
    return uniform;
}

/// Reset a Program struct in place - zeros memory at runtime
fn resetProgram(program: *Program, id: ProgramId) void {
    @memset(std.mem.asBytes(program), 0);
    program.id = id;
    // Set non-zero defaults for samplers (gl_location = -1)
    for (&program.samplers) |*s| {
        s.gl_location = -1;
        s.array_count = 1;
    }
    // Set non-zero defaults for matrix uniforms (gl_location = -1)
    for (&program.mat_uniforms) |*m| {
        m.gl_location = -1;
    }
}

pub const ProgramTable = struct {
    entries: [MaxPrograms]Entry,
    count: u16,

    const Self = @This();

    const Entry = struct {
        active: bool,
        generation: u16,
        program: Program,
    };

    /// Initialize table - zeros memory at runtime, no comptime cost
    pub fn initInPlace(self: *Self) void {
        @memset(std.mem.asBytes(self), 0);
        // Set non-zero defaults (generation = 1)
        for (&self.entries, 0..) |*entry, idx| {
            entry.generation = 1;
            entry.program.id.index = @intCast(idx);
        }
    }

    pub fn init() Self {
        var self: Self = undefined;
        self.initInPlace();
        return self;
    }

    pub fn initWithAllocator(_: std.mem.Allocator) Self {
        return init();
    }

    pub fn alloc(self: *Self) !ProgramId {
        if (self.count >= MaxPrograms) return error.AtCapacity;
        for (&self.entries, 0..) |*entry, idx| {
            if (!entry.active) {
                if (entry.generation == 0) entry.generation = 1;
                const id = ProgramId{
                    .index = @intCast(idx),
                    .generation = entry.generation,
                };
                resetProgram(&entry.program, id);
                entry.active = true;
                self.count += 1;
                return id;
            }
        }
        return error.AtCapacity;
    }

    pub fn get(self: *Self, id: ProgramId) ?*Program {
        if (!self.isValid(id)) return null;
        return &self.entries[id.index].program;
    }

    pub fn attachShader(
        self: *Self,
        id: ProgramId,
        shader_id: shader.ShaderId,
        shaders: *shader.ShaderTable,
    ) !void {
        if (!self.isValid(id)) return error.InvalidHandle;
        const sh = shaders.get(shader_id) orelse return error.InvalidShader;
        var entry = &self.entries[id.index];
        switch (sh.kind) {
            .vertex => entry.program.vertex_shader = shader_id,
            .fragment => entry.program.fragment_shader = shader_id,
        }
        entry.program.linked = false;
        self.clearInfoLog(entry);
    }

    pub fn link(self: *Self, id: ProgramId, shaders: *shader.ShaderTable) !void {
        if (!self.isValid(id)) return error.InvalidHandle;
        var entry = &self.entries[id.index];
        entry.program.linked = false;
        self.clearInfoLog(entry);
        self.clearBackend(entry);

        const vs_id = entry.program.vertex_shader orelse {
            try self.setInfoLog(entry, "vertex shader missing");
            return;
        };
        const fs_id = entry.program.fragment_shader orelse {
            try self.setInfoLog(entry, "fragment shader missing");
            return;
        };

        const vs = shaders.get(vs_id) orelse {
            try self.setInfoLog(entry, "vertex shader invalid");
            return;
        };
        const fs = shaders.get(fs_id) orelse {
            try self.setInfoLog(entry, "fragment shader invalid");
            return;
        };
        if (!vs.compiled or !fs.compiled) {
            try self.setInfoLog(entry, "shader not compiled");
            return;
        }

        const vs_source = shaders.getSource(vs_id) orelse {
            try self.setInfoLog(entry, "vertex shader source missing");
            return;
        };
        const fs_source = shaders.getSource(fs_id) orelse {
            try self.setInfoLog(entry, "fragment shader source missing");
            return;
        };

        var vs_uniforms_pass1: [MaxProgramUniforms]UniformDecl = undefined;
        var vs_uniform_count_pass1: u8 = 0;
        var vs_samplers_pass1: [MaxProgramSamplers]SamplerDecl = undefined;
        var vs_sampler_count_pass1: u8 = 0;
        var vs_block_size_pass1: u32 = 0;
        var vs_len: u32 = 0;
        translateEsToGl330(
            vs_source,
            .vertex,
            &entry.program.vertex_source,
            &vs_len,
            &vs_uniforms_pass1,
            &vs_uniform_count_pass1,
            &vs_samplers_pass1,
            &vs_sampler_count_pass1,
            &vs_block_size_pass1,
            null,
            null,
        ) catch {
            try self.setInfoLog(entry, "vertex shader translate failed");
            return;
        };

        var fs_uniforms_pass1: [MaxProgramUniforms]UniformDecl = undefined;
        var fs_uniform_count_pass1: u8 = 0;
        var fs_samplers_pass1: [MaxProgramSamplers]SamplerDecl = undefined;
        var fs_sampler_count_pass1: u8 = 0;
        var fs_block_size_pass1: u32 = 0;
        var fs_len: u32 = 0;
        translateEsToGl330(
            fs_source,
            .fragment,
            &entry.program.fragment_source,
            &fs_len,
            &fs_uniforms_pass1,
            &fs_uniform_count_pass1,
            &fs_samplers_pass1,
            &fs_sampler_count_pass1,
            &fs_block_size_pass1,
            null,
            null,
        ) catch {
            try self.setInfoLog(entry, "fragment shader translate failed");
            return;
        };

        var union_uniforms: [MaxProgramUniforms]UniformDecl = undefined;
        var union_count: usize = 0;
        const vs_count_pass1: usize = @intCast(vs_uniform_count_pass1);
        for (vs_uniforms_pass1[0..vs_count_pass1]) |u| {
            if (union_count >= MaxProgramUniforms) {
                try self.setInfoLog(entry, "uniform union too large");
                return;
            }
            union_uniforms[union_count] = u;
            union_count += 1;
        }
        const fs_count_pass1: usize = @intCast(fs_uniform_count_pass1);
        for (fs_uniforms_pass1[0..fs_count_pass1]) |u| {
            if (hasUniformName(union_uniforms[0..union_count], u.name)) continue;
            if (union_count >= MaxProgramUniforms) {
                try self.setInfoLog(entry, "uniform union too large");
                return;
            }
            union_uniforms[union_count] = u;
            union_count += 1;
        }
        const override_uniforms: ?[]const UniformDecl = if (union_count > 0) union_uniforms[0..union_count] else null;

        var vs_uniforms: [MaxProgramUniforms]UniformDecl = undefined;
        var vs_uniform_count: u8 = 0;
        var vs_samplers: [MaxProgramSamplers]SamplerDecl = undefined;
        var vs_sampler_count: u8 = 0;
        var vs_block_size: u32 = 0;
        // Only emit uniforms that were in VS original source (pass1)
        const vs_emit_filter: ?[]const UniformDecl = if (vs_uniform_count_pass1 > 0) vs_uniforms_pass1[0..vs_count_pass1] else null;
        translateEsToGl330(
            vs_source,
            .vertex,
            &entry.program.vertex_source,
            &vs_len,
            &vs_uniforms,
            &vs_uniform_count,
            &vs_samplers,
            &vs_sampler_count,
            &vs_block_size,
            override_uniforms,
            vs_emit_filter,
        ) catch {
            try self.setInfoLog(entry, "vertex shader translate failed");
            return;
        };
        entry.program.vertex_source_len = vs_len;

        var fs_uniforms: [MaxProgramUniforms]UniformDecl = undefined;
        var fs_uniform_count: u8 = 0;
        var fs_samplers: [MaxProgramSamplers]SamplerDecl = undefined;
        var fs_sampler_count: u8 = 0;
        var fs_block_size: u32 = 0;
        // Only emit uniforms that were in FS original source (pass1)
        const fs_emit_filter: ?[]const UniformDecl = if (fs_uniform_count_pass1 > 0) fs_uniforms_pass1[0..fs_count_pass1] else null;
        translateEsToGl330(
            fs_source,
            .fragment,
            &entry.program.fragment_source,
            &fs_len,
            &fs_uniforms,
            &fs_uniform_count,
            &fs_samplers,
            &fs_sampler_count,
            &fs_block_size,
            override_uniforms,
            fs_emit_filter,
        ) catch {
            try self.setInfoLog(entry, "fragment shader translate failed");
            return;
        };
        entry.program.fragment_source_len = fs_len;

        // Debug: Check if fragment shader samples from texture
        const fs_src = entry.program.fragment_source[0..@as(usize, fs_len)];
        const has_texture = std.mem.indexOf(u8, fs_src, "texture(") != null or
            std.mem.indexOf(u8, fs_src, "texture2D(") != null;
        const has_map = std.mem.indexOf(u8, fs_src, "map") != null;
        log.info("linkProgram: FS len={d} has_texture={} has_map={}", .{ fs_len, has_texture, has_map });

        // Store only the uniforms that were in each stage's original source
        // AND are actually used in the shader body (not just declared).
        var vs_filtered: [MaxProgramUniforms]UniformDecl = undefined;
        var vs_filtered_count: usize = 0;
        const vs_count: usize = @intCast(vs_uniform_count);
        for (vs_uniforms[0..vs_count]) |u| {
            if (hasUniformName(vs_uniforms_pass1[0..vs_count_pass1], u.name) and
                isUniformUsedInShader(vs_source, u.name))
            {
                vs_filtered[vs_filtered_count] = u;
                vs_filtered_count += 1;
            }
        }
        self.storeUniforms(entry, .vertex, vs_filtered[0..vs_filtered_count], vs_block_size) catch {
            try self.setInfoLog(entry, "vertex uniforms rejected");
            return;
        };

        var fs_filtered: [MaxProgramUniforms]UniformDecl = undefined;
        var fs_filtered_count: usize = 0;
        const fs_count: usize = @intCast(fs_uniform_count);
        for (fs_uniforms[0..fs_count]) |u| {
            if (hasUniformName(fs_uniforms_pass1[0..fs_count_pass1], u.name) and
                isUniformUsedInShader(fs_source, u.name))
            {
                fs_filtered[fs_filtered_count] = u;
                fs_filtered_count += 1;
            }
        }
        self.storeUniforms(entry, .fragment, fs_filtered[0..fs_filtered_count], fs_block_size) catch {
            try self.setInfoLog(entry, "fragment uniforms rejected");
            return;
        };

        const vs_sampler_count_usize: usize = @intCast(vs_sampler_count);
        self.storeSamplers(entry, .vertex, vs_samplers[0..vs_sampler_count_usize]) catch {
            try self.setInfoLog(entry, "vertex samplers rejected");
            return;
        };
        const fs_sampler_count_usize: usize = @intCast(fs_sampler_count);
        self.storeSamplers(entry, .fragment, fs_samplers[0..fs_sampler_count_usize]) catch {
            try self.setInfoLog(entry, "fragment samplers rejected");
            return;
        };
        const vs_len_usize: usize = @intCast(vs_len);
        self.collectAttrNames(entry, entry.program.vertex_source[0..vs_len_usize]) catch {
            try self.setInfoLog(entry, "attribute parse failed");
            return;
        };

        if (!sg.isvalid()) {
            // No graphics context available (tests or headless).
            entry.program.linked = true;
            return;
        }

        // Reset dummy name counter before building shader descriptor
        dummy_name_count = 0;

        // Collect mat2/mat3 uniforms before shader creation
        self.collectMatrixUniforms(entry);

        const desc = buildShaderDesc(entry);
        const shd = sg.makeShader(desc);
        entry.program.backend_shader = shd;
        if (sg.queryShaderState(shd) != .VALID) {
            sg.destroyShader(shd);
            entry.program.backend_shader = .{};
            try self.setInfoLog(entry, "backend shader compile failed");
            return;
        }

        // Query GL program ID and look up mat2/mat3 uniform locations
        const gl_info = sg.glQueryShaderInfo(shd);
        entry.program.gl_program = gl_info.prog;
        self.lookupMatrixUniformLocations(entry);

        entry.program.linked = true;
    }

    pub fn getInfoLog(self: *Self, id: ProgramId) ?[]const u8 {
        if (!self.isValid(id)) return null;
        const prog = &self.entries[id.index].program;
        if (prog.info_log_len == 0) return null;
        return prog.info_log_bytes[0..@as(usize, prog.info_log_len)];
    }

    pub fn getAttribLocation(self: *Self, id: ProgramId, name: []const u8) !i32 {
        const prog = self.get(id) orelse return error.InvalidHandle;
        for (prog.attr_name_lens, 0..) |len, idx| {
            if (idx >= @as(usize, prog.attr_count)) break;
            if (len == 0) continue;
            const slice = prog.attr_names[idx][0..@as(usize, len)];
            if (std.mem.eql(u8, slice, name)) {
                return @intCast(idx);
            }
        }
        return -1;
    }

    pub fn getUniformLocation(self: *Self, id: ProgramId, name: []const u8) !i32 {
        const prog = self.get(id) orelse return error.InvalidHandle;
        if (findUniform(&prog.vs_uniforms, name)) |idx| {
            return @intCast(encodeUniformLocation(.block, .vertex, idx));
        }
        if (findUniform(&prog.fs_uniforms, name)) |idx| {
            return @intCast(encodeUniformLocation(.block, .fragment, idx));
        }
        if (findSampler(prog, name)) |idx| {
            const sampler = prog.samplers[@as(usize, idx)];
            return @intCast(encodeUniformLocation(.sampler, sampler.stage, idx));
        }
        return -1;
    }

    pub fn setUniformFloats(self: *Self, id: ProgramId, loc: u32, values: []const f32) !void {
        const prog = self.get(id) orelse return error.InvalidHandle;
        const info = decodeUniformLocation(loc);
        if (info.kind != .block) return error.InvalidLocation;
        const block = if (info.stage == .vertex) &prog.vs_uniforms else &prog.fs_uniforms;
        if (info.index >= block.count) return error.InvalidLocation;
        const uniform = block.items[@as(usize, info.index)];
        if (block.size == 0) return error.NoUniformBuffer;
        const size = @as(usize, block.size);
        try writeUniformFloats(uniform, block.buffer[0..size], values);
        const name = uniform.name_bytes[0..@as(usize, uniform.name_len)];
        const other_block = if (info.stage == .vertex) &prog.fs_uniforms else &prog.vs_uniforms;
        if (findUniform(other_block, name)) |other_idx| {
            if (other_block.size == 0) return error.NoUniformBuffer;
            const other_uniform = other_block.items[@as(usize, other_idx)];
            const other_size = @as(usize, other_block.size);
            try writeUniformFloats(other_uniform, other_block.buffer[0..other_size], values);
        }
    }

    pub fn setUniformInts(self: *Self, id: ProgramId, loc: u32, values: []const i32) !void {
        const entry = self.get(id) orelse return error.InvalidHandle;
        const info = decodeUniformLocation(loc);
        if (info.kind == .sampler) {
            return setSamplerUnits(entry, info.index, values);
        }
        const block = if (info.stage == .vertex) &entry.vs_uniforms else &entry.fs_uniforms;
        if (info.index >= block.count) return error.InvalidLocation;
        const uniform = block.items[@as(usize, info.index)];
        if (block.size == 0) return error.NoUniformBuffer;
        const size = @as(usize, block.size);
        try writeUniformInts(uniform, block.buffer[0..size], values);
        const name = uniform.name_bytes[0..@as(usize, uniform.name_len)];
        const other_block = if (info.stage == .vertex) &entry.fs_uniforms else &entry.vs_uniforms;
        if (findUniform(other_block, name)) |other_idx| {
            if (other_block.size == 0) return error.NoUniformBuffer;
            const other_uniform = other_block.items[@as(usize, other_idx)];
            const other_size = @as(usize, other_block.size);
            try writeUniformInts(other_uniform, other_block.buffer[0..other_size], values);
        }
    }

    pub fn ensureBackendShader(self: *Self, id: ProgramId) bool {
        if (!self.isValid(id)) return false;
        if (!sg.isvalid()) return false;
        var entry = &self.entries[id.index];
        if (entry.program.backend_shader.id != 0) return true;
        if (entry.program.vertex_source_len == 0 or entry.program.fragment_source_len == 0) return false;
        const desc = buildShaderDesc(entry);
        const shd = sg.makeShader(desc);
        entry.program.backend_shader = shd;
        if (sg.queryShaderState(shd) != .VALID) {
            sg.destroyShader(shd);
            entry.program.backend_shader = .{};
            return false;
        }
        return true;
    }

    pub fn free(self: *Self, id: ProgramId) bool {
        if (!self.isValid(id)) return false;
        var entry = &self.entries[id.index];
        self.clearInfoLog(entry);
        self.clearBackend(entry);
        entry.active = false;
        entry.generation +%= 1;
        const cleared_id = ProgramId{ .index = id.index, .generation = 0 };
        resetProgram(&entry.program, cleared_id);
        self.count -= 1;
        return true;
    }

    pub fn isValid(self: *Self, id: ProgramId) bool {
        if (id.index >= MaxPrograms) return false;
        const entry = &self.entries[id.index];
        return entry.active and entry.generation == id.generation;
    }

    pub fn reset(self: *Self) void {
        self.initInPlace();
    }

    pub fn deinit(self: *Self) void {
        self.initInPlace();
    }

    /// Apply mat2/mat3 uniforms via direct GL calls.
    /// Call this after sg.applyUniforms to set the matrix uniforms that Sokol can't handle.
    /// Returns true if any uniforms were applied.
    pub fn applyMatrixUniforms(self: *Self, id: ProgramId) bool {
        const prog = self.get(id) orelse return false;
        if (prog.mat_uniform_count == 0) return false;
        if (prog.gl_program == 0) return false;

        if (!gl_uniforms.isAvailable()) return false;

        var applied: u32 = 0;
        const mat_count: usize = @intCast(prog.mat_uniform_count);
        for (prog.mat_uniforms[0..mat_count]) |mat| {
            if (mat.gl_location < 0) continue;

            // Get the data from the appropriate uniform block
            const block = if (mat.stage == .vertex) &prog.vs_uniforms else &prog.fs_uniforms;
            if (block.size == 0) continue;

            const offset: usize = @intCast(mat.offset);
            const block_size: usize = @intCast(block.size);
            if (offset >= block_size) continue;

            // Mat3 in std140 is stored as 3 vec4 columns (48 bytes), but glUniformMatrix3fv
            // expects packed 9 floats. We need to extract the 3x3 from the padded layout.
            const array_count: i32 = if (mat.array_count == 0) 1 else @intCast(mat.array_count);

            switch (mat.utype) {
                .MAT2 => {
                    // Mat2 in std140: 2 vec4 columns (32 bytes) -> extract 2x2 (16 bytes)
                    var mat_data: [4]f32 = undefined;
                    const src = block.buffer[offset..];
                    // Column 0: floats 0,1 from vec4 at offset 0
                    mat_data[0] = @bitCast(src[0..4].*);
                    mat_data[1] = @bitCast(src[4..8].*);
                    // Column 1: floats 0,1 from vec4 at offset 16
                    mat_data[2] = @bitCast(src[16..20].*);
                    mat_data[3] = @bitCast(src[20..24].*);
                    gl_uniforms.uniformMatrix2fv(mat.gl_location, array_count, false, &mat_data);
                },
                .MAT3 => {
                    // Mat3 in std140: 3 vec4 columns (48 bytes) -> extract 3x3 (36 bytes)
                    var mat_data: [9]f32 = undefined;
                    const src = block.buffer[offset..];
                    // Column 0: floats 0,1,2 from vec4 at offset 0
                    mat_data[0] = @bitCast(src[0..4].*);
                    mat_data[1] = @bitCast(src[4..8].*);
                    mat_data[2] = @bitCast(src[8..12].*);
                    // Column 1: floats 0,1,2 from vec4 at offset 16
                    mat_data[3] = @bitCast(src[16..20].*);
                    mat_data[4] = @bitCast(src[20..24].*);
                    mat_data[5] = @bitCast(src[24..28].*);
                    // Column 2: floats 0,1,2 from vec4 at offset 32
                    mat_data[6] = @bitCast(src[32..36].*);
                    mat_data[7] = @bitCast(src[36..40].*);
                    mat_data[8] = @bitCast(src[40..44].*);
                    const name = mat.name_bytes[0..@as(usize, mat.name_len)];
                    log.debug("applyMatrixUniforms MAT3 '{s}' gl_loc={d} offset={d} data=[{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3}]", .{
                        name, mat.gl_location, offset,
                        mat_data[0], mat_data[1], mat_data[2],
                        mat_data[3], mat_data[4], mat_data[5],
                        mat_data[6], mat_data[7], mat_data[8],
                    });
                    gl_uniforms.uniformMatrix3fv(mat.gl_location, array_count, false, &mat_data);
                },
                else => continue,
            }
            applied += 1;
        }

        if (applied > 0) {
            log.debug("applyMatrixUniforms: applied {d} uniforms", .{applied});
        }
        return applied > 0;
    }

    /// Apply sampler uniforms via direct GL calls (sets texture unit for each sampler).
    /// Call this at draw time when the program is active.
    pub fn applySamplerUniforms(self: *Self, id: ProgramId) bool {
        const entry = &self.entries[id.index];
        const prog = &entry.program;
        if (prog.sampler_count == 0) return false;
        if (prog.gl_program == 0) return false;
        if (!gl_uniforms.isAvailable()) return false;

        // Verify the correct program is bound
        const current_prog = gl_uniforms.getCurrentProgram();
        if (current_prog != prog.gl_program) {
            log.warn("applySamplerUniforms: program mismatch! current={d} expected={d}", .{ current_prog, prog.gl_program });
        }

        var applied: u32 = 0;
        const count: usize = @intCast(prog.sampler_count);
        for (prog.samplers[0..count]) |*sampler| {
            if (!sampler.dirty) continue;
            if (sampler.name_len == 0) continue;

            // Look up GL location if not cached
            if (sampler.gl_location < 0) {
                const name_ptr: [*:0]const u8 = @ptrCast(sampler.name_bytes[0..].ptr);
                sampler.gl_location = gl_uniforms.getUniformLocation(prog.gl_program, name_ptr);
            }

            if (sampler.gl_location >= 0) {
                gl_uniforms.uniform1i(sampler.gl_location, sampler.units[0]);
                log.info("applySamplerUniforms: '{s}' gl_loc={d} unit={d} (gl_program={d})", .{
                    sampler.name_bytes[0..@as(usize, sampler.name_len)],
                    sampler.gl_location,
                    sampler.units[0],
                    prog.gl_program,
                });
                applied += 1;
            }
            sampler.dirty = false;
        }

        return applied > 0;
    }

    fn setInfoLog(self: *Self, entry: *Entry, log_msg: []const u8) !void {
        if (log_msg.len > MaxProgramInfoLogBytes) return error.TooLarge;
        self.clearInfoLog(entry);
        if (log_msg.len == 0) return;
        @memcpy(entry.program.info_log_bytes[0..log_msg.len], log_msg);
        entry.program.info_log_len = @intCast(log_msg.len);
    }

    fn clearInfoLog(self: *Self, entry: *Entry) void {
        _ = self;
        entry.program.info_log_len = 0;
    }

    fn clearUniformBlock(self: *Self, block: *UniformBlock) void {
        _ = self;
        block.* = zeroedUniformBlock();
    }

    fn clearUniforms(self: *Self, entry: *Entry) void {
        self.clearUniformBlock(&entry.program.vs_uniforms);
        self.clearUniformBlock(&entry.program.fs_uniforms);
    }

    fn clearBackend(self: *Self, entry: *Entry) void {
        if (entry.program.backend_shader.id != 0) {
            sg.destroyShader(entry.program.backend_shader);
            entry.program.backend_shader = .{};
        }
        entry.program.vertex_source_len = 0;
        entry.program.fragment_source_len = 0;
        @memset(&entry.program.attr_name_lens, 0);
        @memset(std.mem.asBytes(&entry.program.attr_names), 0);
        entry.program.attr_count = 0;
        entry.program.sampler_count = 0;
        for (&entry.program.samplers) |*s| {
            @memset(std.mem.asBytes(s), 0);
            s.array_count = 1;
            s.gl_location = -1;
        }
        self.clearUniforms(entry);
    }

    fn collectAttrNames(self: *Self, entry: *Entry, source: []const u8) !void {
        _ = self;
        @memset(&entry.program.attr_name_lens, 0);
        @memset(std.mem.asBytes(&entry.program.attr_names), 0);
        entry.program.attr_count = 0;

        // Simple preprocessor state to handle #ifdef/#ifndef/#else/#endif
        const MaxDefines: usize = 32;
        const MaxIfdefDepth: usize = 16;
        var defines: [MaxDefines][MaxAttrNameBytes]u8 = undefined;
        var define_lens: [MaxDefines]u8 = undefined;
        @memset(&define_lens, 0);
        var define_count: usize = 0;
        var ifdef_stack: [MaxIfdefDepth]bool = undefined; // true = active section
        var ifdef_depth: usize = 0;

        var it = std.mem.splitScalar(u8, source, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trimLeft(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "#version")) continue;

            // Handle preprocessor directives
            if (std.mem.startsWith(u8, trimmed, "#define ")) {
                if (ifdef_depth == 0 or ifdef_stack[ifdef_depth - 1]) {
                    const rest = trimmed["#define ".len..];
                    var tokens = std.mem.tokenizeAny(u8, rest, " \t\r\n");
                    if (tokens.next()) |def_name| {
                        if (define_count < MaxDefines and def_name.len < MaxAttrNameBytes) {
                            @memcpy(defines[define_count][0..def_name.len], def_name);
                            define_lens[define_count] = @intCast(def_name.len);
                            define_count += 1;
                        }
                    }
                }
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "#ifdef ")) {
                const rest = trimmed["#ifdef ".len..];
                var tokens = std.mem.tokenizeAny(u8, rest, " \t\r\n");
                const def_name = tokens.next() orelse "";
                const defined = isDefined(defines[0..define_count], define_lens[0..define_count], def_name);
                const parent_active = ifdef_depth == 0 or ifdef_stack[ifdef_depth - 1];
                if (ifdef_depth < MaxIfdefDepth) {
                    ifdef_stack[ifdef_depth] = parent_active and defined;
                    ifdef_depth += 1;
                }
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "#ifndef ")) {
                const rest = trimmed["#ifndef ".len..];
                var tokens = std.mem.tokenizeAny(u8, rest, " \t\r\n");
                const def_name = tokens.next() orelse "";
                const defined = isDefined(defines[0..define_count], define_lens[0..define_count], def_name);
                const parent_active = ifdef_depth == 0 or ifdef_stack[ifdef_depth - 1];
                if (ifdef_depth < MaxIfdefDepth) {
                    ifdef_stack[ifdef_depth] = parent_active and !defined;
                    ifdef_depth += 1;
                }
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "#else")) {
                if (ifdef_depth > 0) {
                    const parent_active = ifdef_depth <= 1 or ifdef_stack[ifdef_depth - 2];
                    ifdef_stack[ifdef_depth - 1] = parent_active and !ifdef_stack[ifdef_depth - 1];
                }
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "#endif")) {
                if (ifdef_depth > 0) {
                    ifdef_depth -= 1;
                }
                continue;
            }

            // Skip lines inside inactive preprocessor blocks
            if (ifdef_depth > 0 and !ifdef_stack[ifdef_depth - 1]) continue;

            const decl = extractAttrDecl(trimmed) orelse continue;
            var tokens = std.mem.tokenizeAny(u8, decl, " \t");
            _ = tokens.next() orelse continue; // type
            const name_token = tokens.next() orelse continue;
            var name = std.mem.trimRight(u8, name_token, " \t\r;");
            if (std.mem.indexOfScalar(u8, name, '[')) |idx| {
                name = name[0..idx];
            }
            if (name.len == 0) continue;
            if (@as(usize, entry.program.attr_count) >= MaxProgramAttrs) return error.TooManyAttribs;
            if (name.len >= MaxAttrNameBytes) return error.AttribNameTooLong;
            const attr_index: usize = @intCast(entry.program.attr_count);
            @memcpy(entry.program.attr_names[attr_index][0..name.len], name);
            entry.program.attr_names[attr_index][name.len] = 0;
            entry.program.attr_name_lens[attr_index] = @intCast(name.len);
            entry.program.attr_count += 1;
        }
    }

    /// Collect mat2/mat3 uniforms from both VS and FS uniform blocks
    fn collectMatrixUniforms(self: *Self, entry: *Entry) void {
        _ = self;
        entry.program.mat_uniform_count = 0;

        // Collect from vertex shader uniforms
        const vs_count: usize = @intCast(entry.program.vs_uniforms.count);
        for (entry.program.vs_uniforms.items[0..vs_count]) |item| {
            if (item.name_len == 0) continue;
            if (item.utype == .MAT2 or item.utype == .MAT3) {
                if (entry.program.mat_uniform_count >= MaxMatrixUniforms) break;
                const idx: usize = @intCast(entry.program.mat_uniform_count);
                entry.program.mat_uniforms[idx] = .{
                    .name_len = item.name_len,
                    .name_bytes = item.name_bytes,
                    .utype = item.utype,
                    .stage = .vertex,
                    .offset = item.offset,
                    .gl_location = -1,
                    .array_count = item.array_count,
                };
                entry.program.mat_uniform_count += 1;
            }
        }

        // Collect from fragment shader uniforms
        const fs_count: usize = @intCast(entry.program.fs_uniforms.count);
        for (entry.program.fs_uniforms.items[0..fs_count]) |item| {
            if (item.name_len == 0) continue;
            if (item.utype == .MAT2 or item.utype == .MAT3) {
                // Check if already collected from VS (shared uniform)
                const name = item.name_bytes[0..@as(usize, item.name_len)];
                var already_collected = false;
                const mat_count: usize = @intCast(entry.program.mat_uniform_count);
                for (entry.program.mat_uniforms[0..mat_count]) |mat| {
                    const mat_name = mat.name_bytes[0..@as(usize, mat.name_len)];
                    if (std.mem.eql(u8, name, mat_name)) {
                        already_collected = true;
                        break;
                    }
                }
                if (already_collected) continue;

                if (entry.program.mat_uniform_count >= MaxMatrixUniforms) break;
                const idx: usize = @intCast(entry.program.mat_uniform_count);
                entry.program.mat_uniforms[idx] = .{
                    .name_len = item.name_len,
                    .name_bytes = item.name_bytes,
                    .utype = item.utype,
                    .stage = .fragment,
                    .offset = item.offset,
                    .gl_location = -1,
                    .array_count = item.array_count,
                };
                entry.program.mat_uniform_count += 1;
            }
        }

        if (entry.program.mat_uniform_count > 0) {
            log.info("collectMatrixUniforms: found {d} mat2/mat3 uniforms", .{entry.program.mat_uniform_count});
        }
    }

    /// Look up GL uniform locations for mat2/mat3 uniforms using direct GL calls
    fn lookupMatrixUniformLocations(self: *Self, entry: *Entry) void {
        _ = self;
        if (entry.program.gl_program == 0) return;
        if (entry.program.mat_uniform_count == 0) return;

        // Initialize GL if needed
        gl_uniforms.init();
        if (!gl_uniforms.isAvailable()) {
            log.warn("lookupMatrixUniformLocations: GL not available", .{});
            return;
        }

        const mat_count: usize = @intCast(entry.program.mat_uniform_count);
        for (entry.program.mat_uniforms[0..mat_count]) |*mat| {
            // The name_bytes should be null-terminated
            const name_ptr: [*:0]const u8 = @ptrCast(mat.name_bytes[0..].ptr);
            mat.gl_location = gl_uniforms.getUniformLocation(entry.program.gl_program, name_ptr);
            const name = mat.name_bytes[0..@as(usize, mat.name_len)];
            log.info("lookupMatrixUniformLocations: '{s}' -> gl_loc={d}", .{ name, mat.gl_location });
        }
    }

    fn storeUniforms(self: *Self, entry: *Entry, stage: UniformStage, decls: []UniformDecl, block_size: u32) !void {
        _ = self;
        _ = block_size; // Recompute instead of using passed-in size
        const block = if (stage == .vertex) &entry.program.vs_uniforms else &entry.program.fs_uniforms;
        block.* = zeroedUniformBlock();
        if (decls.len == 0) return;
        if (decls.len > MaxProgramUniforms) return error.TooManyUniforms;
        block.count = @intCast(decls.len);

        // Recompute offsets for this stage's uniforms starting from 0
        // (the decl.offset values may have been computed across all stages combined)
        var offset: u32 = 0;
        for (decls, 0..) |decl, idx| {
            if (decl.name.len >= MaxUniformNameBytes) return error.UniformNameTooLong;
            @memcpy(block.items[idx].name_bytes[0..decl.name.len], decl.name);
            block.items[idx].name_bytes[decl.name.len] = 0;
            block.items[idx].name_len = @intCast(decl.name.len);
            block.items[idx].utype = decl.utype;
            block.items[idx].array_count = decl.array_count;
            block.items[idx].stride = decl.stride;
            block.items[idx].size = decl.size;

            // Compute offset for this stage starting from 0
            const elem_count: u32 = if (decl.array_count == 0) 1 else decl.array_count;
            const alignment = uniformAlign(decl.utype, decl.array_count);
            offset = alignUp(offset, alignment);
            block.items[idx].offset = offset;
            offset += decl.stride * elem_count;
        }
        const computed_size = computeUniformBlockSize(block);
        if (computed_size > MaxUniformBlockBytes) return error.UniformBlockTooLarge;
        block.size = computed_size;
        if (block.size > 0) {
            const size: usize = @intCast(block.size);
            @memset(block.buffer[0..size], 0);
        }

        // Debug: log stored uniforms
        const stage_name = if (stage == .vertex) "VS" else "FS";
        log.info("storeUniforms {s}: {d} uniforms, size={d}", .{ stage_name, decls.len, computed_size });
        for (decls, 0..) |decl, idx| {
            log.info("  [{d}] '{s}' type={s} offset={d}", .{ idx, decl.name, @tagName(decl.utype), block.items[idx].offset });
        }
    }

    fn storeSamplers(self: *Self, entry: *Entry, stage: UniformStage, decls: []SamplerDecl) !void {
        _ = self;
        if (decls.len == 0) return;
        for (decls) |decl| {
            if (entry.program.sampler_count >= MaxProgramSamplers) return error.TooManySamplers;
            if (decl.name.len >= MaxUniformNameBytes) return error.UniformNameTooLong;
            const index: usize = @intCast(entry.program.sampler_count);
            entry.program.samplers[index] = zeroedSamplerEntry();
            entry.program.samplers[index].kind = decl.kind;
            entry.program.samplers[index].stage = stage;
            entry.program.samplers[index].array_count = decl.array_count;
            entry.program.samplers[index].name_len = @intCast(decl.name.len);
            @memcpy(entry.program.samplers[index].name_bytes[0..decl.name.len], decl.name);
            entry.program.samplers[index].name_bytes[decl.name.len] = 0;
            entry.program.sampler_count += 1;
        }
    }

    fn buildShaderDesc(entry: *Entry) sg.ShaderDesc {
        var desc = sg.ShaderDesc{};
        if (entry.program.vertex_source_len > 0) {
            desc.vertex_func.source = entry.program.vertex_source[0..].ptr;
        }
        if (entry.program.fragment_source_len > 0) {
            desc.fragment_func.source = entry.program.fragment_source[0..].ptr;
        }
        for (entry.program.attr_name_lens, 0..) |name_len, idx| {
            if (idx >= @as(usize, entry.program.attr_count)) break;
            if (name_len == 0) continue;
            desc.attrs[idx].glsl_name = entry.program.attr_names[idx][0..].ptr;
        }
        applyUniformBlock(&desc, 0, .VERTEX, &entry.program.vs_uniforms);
        applyUniformBlock(&desc, 1, .FRAGMENT, &entry.program.fs_uniforms);

        // Note: For the GL backend, we don't declare samplers in the shader descriptor.
        // GL handles sampler->texture unit binding natively via uniform1i calls.
        // If we declare samplers here, Sokol validates that bindings exist for ALL declared
        // samplers, but Three.js shaders often have unused samplers that get optimized out.

        return desc;
    }
};

/// Dummy name buffers for MAT2/MAT3 uniforms (static to persist past function return)
var dummy_name_buffers: [16][MaxUniformNameBytes + 16]u8 = undefined;
var dummy_name_count: usize = 0;

fn applyUniformBlock(desc: *sg.ShaderDesc, index: usize, stage: sg.ShaderStage, block: *const UniformBlock) void {
    if (block.count == 0 or block.size == 0) return;
    if (index >= desc.uniform_blocks.len) return;
    desc.uniform_blocks[index].stage = stage;
    desc.uniform_blocks[index].size = block.size;
    desc.uniform_blocks[index].layout = .STD140;
    // IMPORTANT: Use pointer to items to avoid getting dangling pointers to copies
    var out_idx: usize = 0;
    const item_count = @as(usize, block.count);
    for (0..item_count) |idx| {
        const item = &block.items[idx];
        if (item.name_len == 0) continue;
        const count: u16 = if (item.array_count == 0) 1 else item.array_count;
        // For MAT2/MAT3, use a dummy name so Sokol skips setting them
        // (they will be set via direct GL calls). The dummy name ensures
        // glGetUniformLocation returns -1, causing Sokol to skip.
        // For MAT2/MAT3, use a dummy name so Sokol skips setting them
        // (they will be set via direct GL calls). The dummy name ensures
        // glGetUniformLocation returns -1, causing Sokol to skip.
        const glsl_name: [*:0]const u8 = if (item.utype == .MAT2 or item.utype == .MAT3) blk: {
            if (dummy_name_count >= dummy_name_buffers.len) {
                // Fall back to real name if too many (shouldn't happen)
                break :blk @ptrCast(item.name_bytes[0..].ptr);
            }
            const name = item.name_bytes[0..@as(usize, item.name_len)];
            const prefix = "_sokol_skip_";
            var buf = &dummy_name_buffers[dummy_name_count];
            @memcpy(buf[0..prefix.len], prefix);
            @memcpy(buf[prefix.len..][0..name.len], name);
            buf[prefix.len + name.len] = 0;
            dummy_name_count += 1;
            break :blk @ptrCast(buf[0..].ptr);
        } else @ptrCast(item.name_bytes[0..].ptr);

        desc.uniform_blocks[index].glsl_uniforms[out_idx] = .{
            .type = item.utype.toSokol(),
            .array_count = item.utype.sokolArrayCount(count),
            .glsl_name = glsl_name,
        };
        out_idx += 1;
    }
}

const UniformLocationKind = enum(u8) { block = 0, sampler = 1 };

const UniformLocation = struct {
    kind: UniformLocationKind,
    stage: UniformStage,
    index: u8,
};

fn encodeUniformLocation(kind: UniformLocationKind, stage: UniformStage, index: u8) u32 {
    return (@as(u32, @intFromEnum(kind)) << 9) | (@as(u32, @intFromEnum(stage)) << 8) | index;
}

fn decodeUniformLocation(loc: u32) UniformLocation {
    const kind_bit: u8 = @intCast((loc >> 9) & 0x1);
    const stage_bit: u8 = @intCast((loc >> 8) & 0x1);
    const stage: UniformStage = if (stage_bit == 1) .fragment else .vertex;
    const kind: UniformLocationKind = if (kind_bit == 1) .sampler else .block;
    return .{
        .kind = kind,
        .stage = stage,
        .index = @intCast(loc & 0xff),
    };
}

fn findUniform(block: *const UniformBlock, name: []const u8) ?u8 {
    if (block.count == 0) return null;
    var query = name;
    if (std.mem.indexOfScalar(u8, query, '[')) |idx| {
        query = query[0..idx];
    }
    for (block.items, 0..) |item, idx| {
        if (idx >= @as(usize, block.count)) break;
        if (item.name_len == 0) continue;
        const slice = item.name_bytes[0..@as(usize, item.name_len)];
        if (std.mem.eql(u8, slice, query)) {
            return @intCast(idx);
        }
    }
    return null;
}

fn findSampler(prog: *const Program, name: []const u8) ?u8 {
    if (prog.sampler_count == 0) return null;
    var query = name;
    if (std.mem.indexOfScalar(u8, query, '[')) |idx| {
        query = query[0..idx];
    }
    for (prog.samplers, 0..) |sampler, idx| {
        if (idx >= @as(usize, prog.sampler_count)) break;
        if (sampler.name_len == 0) continue;
        const slice = sampler.name_bytes[0..@as(usize, sampler.name_len)];
        if (std.mem.eql(u8, slice, query)) {
            return @intCast(idx);
        }
    }
    return null;
}

fn uniformComponents(utype: UniformType) u32 {
    return switch (utype) {
        .FLOAT, .INT => 1,
        .FLOAT2, .INT2 => 2,
        .FLOAT3, .INT3 => 3,
        .FLOAT4, .INT4 => 4,
        .MAT2 => 4, // 2x2 matrix = 4 floats
        .MAT3 => 9, // 3x3 matrix = 9 floats
        .MAT4 => 16, // 4x4 matrix = 16 floats
        .INVALID => 0,
    };
}

fn writeUniformFloats(uniform: UniformEntry, buffer: []u8, values: []const f32) !void {
    switch (uniform.utype) {
        .FLOAT, .FLOAT2, .FLOAT3, .FLOAT4, .MAT2, .MAT3, .MAT4 => {},
        else => return error.InvalidType,
    }
    const comps = uniformComponents(uniform.utype);
    if (comps == 0) return error.InvalidType;
    const elem_count: usize = if (uniform.array_count == 0) 1 else uniform.array_count;
    const needed = elem_count * comps;
    if (values.len < needed) return error.NotEnoughData;
    if (uniform.stride == 0) return error.InvalidStride;

    // Handle mat2/mat3 specially - they need column padding for std140
    switch (uniform.utype) {
        .MAT2 => {
            // mat2: 4 floats input -> 8 floats output (2 columns * 4 floats each)
            // Each column (2 floats) is padded to vec4 (4 floats)
            for (0..elem_count) |idx| {
                const src = values[idx * 4 .. idx * 4 + 4];
                const dst_off = uniform.offset + uniform.stride * @as(u32, @intCast(idx));
                if (dst_off + uniform.stride > buffer.len) return error.OutOfBounds;
                const dst = buffer[dst_off .. dst_off + uniform.stride];
                @memset(dst, 0);
                // Column 0: src[0..2] -> dst[0..8] (first 2 floats, rest zero)
                @memcpy(dst[0..8], std.mem.sliceAsBytes(src[0..2]));
                // Column 1: src[2..4] -> dst[16..24] (first 2 floats, rest zero)
                @memcpy(dst[16..24], std.mem.sliceAsBytes(src[2..4]));
            }
        },
        .MAT3 => {
            // mat3: 9 floats input -> 12 floats output (3 columns * 4 floats each)
            // Each column (3 floats) is padded to vec4 (4 floats)
            for (0..elem_count) |idx| {
                const src = values[idx * 9 .. idx * 9 + 9];
                const dst_off = uniform.offset + uniform.stride * @as(u32, @intCast(idx));
                if (dst_off + uniform.stride > buffer.len) return error.OutOfBounds;
                const dst = buffer[dst_off .. dst_off + uniform.stride];
                @memset(dst, 0);
                // Column 0: src[0..3] -> dst[0..12]
                @memcpy(dst[0..12], std.mem.sliceAsBytes(src[0..3]));
                // Column 1: src[3..6] -> dst[16..28]
                @memcpy(dst[16..28], std.mem.sliceAsBytes(src[3..6]));
                // Column 2: src[6..9] -> dst[32..44]
                @memcpy(dst[32..44], std.mem.sliceAsBytes(src[6..9]));
            }
        },
        else => {
            // Standard float types and mat4 - no special padding needed
            for (0..elem_count) |idx| {
                const src = values[idx * comps .. idx * comps + comps];
                const dst_off = uniform.offset + uniform.stride * @as(u32, @intCast(idx));
                if (dst_off + uniform.stride > buffer.len) return error.OutOfBounds;
                const dst = buffer[dst_off .. dst_off + uniform.stride];
                @memset(dst, 0);
                @memcpy(dst[0..uniform.size], std.mem.sliceAsBytes(src));
            }
        },
    }
}

fn writeUniformInts(uniform: UniformEntry, buffer: []u8, values: []const i32) !void {
    switch (uniform.utype) {
        .INT, .INT2, .INT3, .INT4 => {},
        else => return error.InvalidType,
    }
    const comps = uniformComponents(uniform.utype);
    if (comps == 0) return error.InvalidType;
    const elem_count: usize = if (uniform.array_count == 0) 1 else uniform.array_count;
    const needed = elem_count * comps;
    if (values.len < needed) return error.NotEnoughData;
    if (uniform.stride == 0) return error.InvalidStride;
    for (0..elem_count) |idx| {
        const src = values[idx * comps .. idx * comps + comps];
        const dst_off = uniform.offset + uniform.stride * @as(u32, @intCast(idx));
        if (dst_off + uniform.stride > buffer.len) return error.OutOfBounds;
        const dst = buffer[dst_off .. dst_off + uniform.stride];
        @memset(dst, 0);
        @memcpy(dst[0..uniform.size], std.mem.sliceAsBytes(src));
    }
}

fn setSamplerUnits(entry: *Program, index: u8, values: []const i32) !void {
    if (index >= entry.sampler_count) return error.InvalidLocation;
    const sampler = &entry.samplers[@as(usize, index)];
    const count: usize = if (sampler.array_count == 0) 1 else sampler.array_count;
    if (values.len < count) return error.NotEnoughData;
    for (0..count) |i| {
        sampler.units[i] = values[i];
    }
    // Mark sampler as dirty - actual GL uniform1i will be called at draw time
    // when the program is guaranteed to be active
    sampler.dirty = true;
}

const ShaderStage = enum { vertex, fragment };

const UniformStage = enum(u8) { vertex = 0, fragment = 1 };

const UniformDecl = struct {
    name: []const u8,
    utype: UniformType,
    array_count: u16,
    offset: u32,
    stride: u32,
    size: u32,
};

const SamplerDecl = struct {
    name: []const u8,
    kind: SamplerKind,
    array_count: u16,
};

const UniformParse = union(enum) {
    block: UniformDecl,
    sampler: SamplerDecl,
};

const MaxShaderLineBytes: usize = 1024;

fn translateEsToGl330(
    source: []const u8,
    stage: ShaderStage,
    out: *[MaxTranslatedShaderBytes]u8,
    out_len: *u32,
    uniforms: *[MaxProgramUniforms]UniformDecl,
    uniform_count: *u8,
    samplers: *[MaxProgramSamplers]SamplerDecl,
    sampler_count: *u8,
    block_size: *u32,
    override_uniforms: ?[]const UniformDecl,
    emit_filter: ?[]const UniformDecl,
) !void {
    if (source.len > shader.MaxShaderSourceBytes) return error.TooLarge;
    uniform_count.* = 0;
    sampler_count.* = 0;
    block_size.* = 0;
    const use_override = override_uniforms != null;

    var body_buf: [MaxTranslatedShaderBytes]u8 = undefined;
    var body_len: usize = 0;

    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        if (line.len > MaxShaderLineBytes) return error.LineTooLong;
        const trimmed = std.mem.trimLeft(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "#version")) continue;
        if (std.mem.startsWith(u8, trimmed, "precision")) continue;

        if (try parseUniformDecl(trimmed)) |parsed| {
            switch (parsed) {
                .block => |decl| {
                    const count: usize = @intCast(uniform_count.*);
                    if (count >= MaxProgramUniforms) return error.TooManyUniforms;
                    if (!use_override) {
                        if (hasUniformName(uniforms[0..count], decl.name)) continue;
                        uniforms[count] = decl;
                        uniform_count.* += 1;
                    }
                },
                .sampler => |decl| {
                    const count: usize = @intCast(sampler_count.*);
                    if (count >= MaxProgramSamplers) return error.TooManySamplers;
                    if (hasSamplerName(samplers[0..count], decl.name)) continue;
                    samplers[count] = decl;
                    sampler_count.* += 1;
                },
            }
            continue;
        }

        var scratch_a: [MaxShaderLineBytes]u8 = undefined;
        var scratch_b: [MaxShaderLineBytes]u8 = undefined;
        var len_a = try replaceWord(line, "texture2D", "texture", scratch_a[0..]);
        if (stage == .vertex) {
            const len_b = try replaceWord(scratch_a[0..len_a], "attribute", "in", scratch_b[0..]);
            len_a = try replaceWord(scratch_b[0..len_b], "varying", "out", scratch_a[0..]);
        } else {
            len_a = try replaceWord(scratch_a[0..len_a], "varying", "in", scratch_b[0..]);
            @memcpy(scratch_a[0..len_a], scratch_b[0..len_a]);
        }
        const len_final = try replaceWord(scratch_a[0..len_a], "gl_FragColor", "fragColor", scratch_b[0..]);
        try appendBytes(body_buf[0..], &body_len, scratch_b[0..len_final]);
        try appendByte(body_buf[0..], &body_len, '\n');
    }

    if (use_override) {
        const list = override_uniforms.?;
        if (list.len > MaxProgramUniforms) return error.TooManyUniforms;
        @memcpy(uniforms[0..list.len], list);
        uniform_count.* = @intCast(list.len);
    }

    if (uniform_count.* > 0) {
        const count: usize = @intCast(uniform_count.*);
        block_size.* = try layoutUniforms(uniforms[0..count]);
    }

    var header_buf: [MaxTranslatedShaderBytes]u8 = undefined;
    var header_len: usize = 0;
    try appendBytes(header_buf[0..], &header_len, "#version 330\n");
    // Only add fragColor output if the shader uses gl_FragColor AND doesn't already
    // have its own output declaration (Three.js shaders declare pc_fragColor)
    const has_gl_frag_color = std.mem.indexOf(u8, source, "gl_FragColor") != null;
    const has_own_output = std.mem.indexOf(u8, source, "pc_fragColor") != null or
        std.mem.indexOf(u8, source, "layout(location") != null;
    const needs_frag_color = stage == .fragment and has_gl_frag_color and !has_own_output;
    if (needs_frag_color) {
        try appendBytes(header_buf[0..], &header_len, "out vec4 fragColor;\n");
    }
    if (uniform_count.* > 0) {
        // Emit individual uniform declarations instead of a uniform block.
        // Sokol's GL backend uses glGetUniformLocation for each uniform,
        // which doesn't work with GLSL uniform blocks.
        // Only emit uniforms that pass the filter AND are actually used.
        const count: usize = @intCast(uniform_count.*);
        for (uniforms[0..count]) |u| {
            if (emit_filter) |filter| {
                if (!hasUniformName(filter, u.name)) continue;
                if (!isUniformUsedInShader(source, u.name)) continue;
            }
            try appendBytes(header_buf[0..], &header_len, "uniform ");
            try appendBytes(header_buf[0..], &header_len, glslType(u.utype));
            try appendBytes(header_buf[0..], &header_len, " ");
            try appendBytes(header_buf[0..], &header_len, u.name);
            if (u.array_count > 1) {
                var buf: [16]u8 = undefined;
                const len = try std.fmt.bufPrint(&buf, "[{}]", .{u.array_count});
                try appendBytes(header_buf[0..], &header_len, len);
            }
            try appendBytes(header_buf[0..], &header_len, ";\n");
        }
    }

    if (sampler_count.* > 0) {
        const count: usize = @intCast(sampler_count.*);
        for (samplers[0..count]) |s| {
            try appendBytes(header_buf[0..], &header_len, "uniform ");
            try appendBytes(header_buf[0..], &header_len, samplerGlslType(s.kind));
            try appendBytes(header_buf[0..], &header_len, " ");
            try appendBytes(header_buf[0..], &header_len, s.name);
            if (s.array_count > 1) {
                var buf: [16]u8 = undefined;
                const len = try std.fmt.bufPrint(&buf, "[{}]", .{s.array_count});
                try appendBytes(header_buf[0..], &header_len, len);
            }
            try appendBytes(header_buf[0..], &header_len, ";\n");
        }
    }

    var total_len: usize = 0;
    try appendBytes(out[0..], &total_len, header_buf[0..header_len]);
    try appendBytes(out[0..], &total_len, body_buf[0..body_len]);
    if (total_len + 1 > out.len) return error.TooLarge;
    out[total_len] = 0;
    out_len.* = @intCast(total_len);
}

fn parseUniformDecl(line: []const u8) !?UniformParse {
    if (!std.mem.startsWith(u8, line, "uniform ")) return null;
    const rest = line["uniform ".len..];
    var tokens = std.mem.tokenizeAny(u8, rest, " \t");
    const first = tokens.next() orelse return null;
    const precision = if (isPrecision(first)) (tokens.next() orelse return null) else first;
    const type_token = precision;
    const name_token = tokens.next() orelse return null;
    const parsed = parseUniformName(name_token) orelse return null;
    if (parsed.count > MaxUniformArrayCount) return error.UniformArrayTooLarge;
    if (samplerKindFromGlsl(type_token)) |kind| {
        return .{ .sampler = .{
            .name = parsed.name,
            .kind = kind,
            .array_count = parsed.count,
        } };
    }
    const utype = uniformTypeFromGlsl(type_token) orelse return null;
    return .{ .block = .{
        .name = parsed.name,
        .utype = utype,
        .array_count = parsed.count,
        .offset = 0,
        .stride = 0,
        .size = 0,
    } };
}

const UniformName = struct {
    name: []const u8,
    count: u16,
};

fn parseUniformName(token: []const u8) ?UniformName {
    var name = std.mem.trimRight(u8, token, " \t\r;");
    var count: u16 = 1;
    if (std.mem.indexOfScalar(u8, name, '[')) |idx| {
        const end = std.mem.indexOfScalar(u8, name, ']') orelse return null;
        const num_slice = name[idx + 1 .. end];
        const parsed = std.fmt.parseInt(u16, num_slice, 10) catch return null;
        count = parsed;
        name = name[0..idx];
    }
    if (name.len == 0) return null;
    return .{ .name = name, .count = count };
}

fn hasUniformName(uniforms: []const UniformDecl, name: []const u8) bool {
    for (uniforms) |u| {
        if (u.name.len == 0) continue;
        if (std.mem.eql(u8, u.name, name)) return true;
    }
    return false;
}

/// Check if a uniform name is actually used in the shader body (not just declared).
/// Uses preprocessor-aware scanning to skip code inside false #ifdef/#ifndef blocks.
fn isUniformUsedInShader(source: []const u8, name: []const u8) bool {
    if (name.len == 0) return false;

    // Simple preprocessor state
    const MaxDefines: usize = 32;
    const MaxIfdefDepth: usize = 16;
    var defines: [MaxDefines][MaxAttrNameBytes]u8 = undefined;
    var define_lens: [MaxDefines]u8 = undefined;
    @memset(&define_lens, 0);
    var define_count: usize = 0;
    var ifdef_stack: [MaxIfdefDepth]bool = undefined;
    var ifdef_depth: usize = 0;

    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t\r");

        // Handle preprocessor directives
        if (std.mem.startsWith(u8, trimmed, "#define ")) {
            if (ifdef_depth == 0 or ifdef_stack[ifdef_depth - 1]) {
                const rest = trimmed["#define ".len..];
                var tokens = std.mem.tokenizeAny(u8, rest, " \t\r\n");
                if (tokens.next()) |def_name| {
                    if (define_count < MaxDefines and def_name.len < MaxAttrNameBytes) {
                        @memcpy(defines[define_count][0..def_name.len], def_name);
                        define_lens[define_count] = @intCast(def_name.len);
                        define_count += 1;
                    }
                }
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "#ifdef ")) {
            const rest = trimmed["#ifdef ".len..];
            var tokens = std.mem.tokenizeAny(u8, rest, " \t\r\n");
            const def_name = tokens.next() orelse "";
            const defined = isDefined(defines[0..define_count], define_lens[0..define_count], def_name);
            const parent_active = ifdef_depth == 0 or ifdef_stack[ifdef_depth - 1];
            if (ifdef_depth < MaxIfdefDepth) {
                ifdef_stack[ifdef_depth] = parent_active and defined;
                ifdef_depth += 1;
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "#ifndef ")) {
            const rest = trimmed["#ifndef ".len..];
            var tokens = std.mem.tokenizeAny(u8, rest, " \t\r\n");
            const def_name = tokens.next() orelse "";
            const defined = isDefined(defines[0..define_count], define_lens[0..define_count], def_name);
            const parent_active = ifdef_depth == 0 or ifdef_stack[ifdef_depth - 1];
            if (ifdef_depth < MaxIfdefDepth) {
                ifdef_stack[ifdef_depth] = parent_active and !defined;
                ifdef_depth += 1;
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "#else")) {
            if (ifdef_depth > 0) {
                const parent_active = ifdef_depth <= 1 or ifdef_stack[ifdef_depth - 2];
                ifdef_stack[ifdef_depth - 1] = parent_active and !ifdef_stack[ifdef_depth - 1];
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "#endif")) {
            if (ifdef_depth > 0) {
                ifdef_depth -= 1;
            }
            continue;
        }

        // Skip if inside an inactive preprocessor block
        if (ifdef_depth > 0 and !ifdef_stack[ifdef_depth - 1]) continue;

        // Skip uniform declarations and other preprocessor directives
        if (std.mem.startsWith(u8, trimmed, "uniform ")) continue;
        if (std.mem.startsWith(u8, trimmed, "#")) continue;
        if (std.mem.startsWith(u8, trimmed, "precision ")) continue;

        // Search for the name as a word in this line
        var pos: usize = 0;
        while (pos < line.len) {
            if (std.mem.indexOfPos(u8, line, pos, name)) |idx| {
                const start_ok = idx == 0 or !isWordChar(line[idx - 1]);
                const end_idx = idx + name.len;
                const end_ok = end_idx >= line.len or !isWordChar(line[end_idx]);
                if (start_ok and end_ok) return true;
                pos = idx + 1;
            } else {
                break;
            }
        }
    }
    return false;
}

fn hasSamplerName(samplers: []const SamplerDecl, name: []const u8) bool {
    for (samplers) |s| {
        if (s.name.len == 0) continue;
        if (std.mem.eql(u8, s.name, name)) return true;
    }
    return false;
}

fn isPrecision(token: []const u8) bool {
    return std.mem.eql(u8, token, "lowp") or std.mem.eql(u8, token, "mediump") or std.mem.eql(u8, token, "highp");
}

fn uniformTypeFromGlsl(token: []const u8) ?UniformType {
    if (std.mem.eql(u8, token, "float")) return .FLOAT;
    if (std.mem.eql(u8, token, "vec2")) return .FLOAT2;
    if (std.mem.eql(u8, token, "vec3")) return .FLOAT3;
    if (std.mem.eql(u8, token, "vec4")) return .FLOAT4;
    if (std.mem.eql(u8, token, "int")) return .INT;
    if (std.mem.eql(u8, token, "ivec2")) return .INT2;
    if (std.mem.eql(u8, token, "ivec3")) return .INT3;
    if (std.mem.eql(u8, token, "ivec4")) return .INT4;
    if (std.mem.eql(u8, token, "mat2")) return .MAT2;
    if (std.mem.eql(u8, token, "mat3")) return .MAT3;
    if (std.mem.eql(u8, token, "mat4")) return .MAT4;
    return null;
}

fn samplerKindFromGlsl(token: []const u8) ?SamplerKind {
    if (std.mem.eql(u8, token, "sampler2D")) return .sampler2d;
    if (std.mem.eql(u8, token, "samplerCube")) return .samplerCube;
    return null;
}

fn glslType(utype: UniformType) []const u8 {
    return switch (utype) {
        .FLOAT => "float",
        .FLOAT2 => "vec2",
        .FLOAT3 => "vec3",
        .FLOAT4 => "vec4",
        .INT => "int",
        .INT2 => "ivec2",
        .INT3 => "ivec3",
        .INT4 => "ivec4",
        .MAT2 => "mat2",
        .MAT3 => "mat3",
        .MAT4 => "mat4",
        .INVALID => "float",
    };
}

fn samplerGlslType(kind: SamplerKind) []const u8 {
    return switch (kind) {
        .sampler2d => "sampler2D",
        .samplerCube => "samplerCube",
    };
}

fn layoutUniforms(uniforms: []UniformDecl) !u32 {
    var offset: u32 = 0;
    for (uniforms) |*u| {
        const elem_count: u32 = if (u.array_count == 0) 1 else u.array_count;
        if (elem_count > MaxUniformArrayCount) return error.UniformArrayTooLarge;
        if (u.array_count > 1) {
            // In std140, arrays of smaller types are padded to vec4 alignment
            // Only allow types that are vec4-sized or matrix types for arrays
            if (u.utype != .FLOAT4 and u.utype != .INT4 and
                u.utype != .MAT2 and u.utype != .MAT3 and u.utype != .MAT4)
            {
                return error.UnsupportedArrayType;
            }
        }
        const alignment = uniformAlign(u.utype, u.array_count);
        offset = alignUp(offset, alignment);
        u.offset = offset;
        u.size = uniformSize(u.utype);
        u.stride = uniformStride(u.utype, u.array_count);
        offset += u.stride * elem_count;
    }
    return alignUp(offset, 16);
}

fn computeUniformBlockSize(block: *const UniformBlock) u32 {
    var offset: u32 = 0;
    if (block.count == 0) return 0;
    for (block.items, 0..) |item, idx| {
        if (idx >= @as(usize, block.count)) break;
        if (item.name_len == 0) continue;
        const alignment = uniformAlign(item.utype, item.array_count);
        offset = alignUp(offset, alignment);
        offset += uniformMemberSize(item.utype, item.array_count);
    }
    return alignUp(offset, 16);
}

fn uniformMemberSize(utype: UniformType, array_count: u16) u32 {
    if (array_count <= 1) return uniformSize(utype);
    return switch (utype) {
        .FLOAT, .FLOAT2, .FLOAT3, .FLOAT4, .INT, .INT2, .INT3, .INT4 => 16 * @as(u32, array_count),
        .MAT2 => 32 * @as(u32, array_count), // 2 vec4 columns per matrix
        .MAT3 => 48 * @as(u32, array_count), // 3 vec4 columns per matrix
        .MAT4 => 64 * @as(u32, array_count), // 4 vec4 columns per matrix
        .INVALID => 0,
    };
}

fn uniformAlign(utype: UniformType, array_count: u16) u32 {
    if (array_count > 1) return 16;
    return switch (utype) {
        .FLOAT, .INT => 4,
        .FLOAT2, .INT2 => 8,
        // mat2/mat3/mat4 all have vec4-aligned columns in std140
        .FLOAT3, .FLOAT4, .INT3, .INT4, .MAT2, .MAT3, .MAT4 => 16,
        .INVALID => 4,
    };
}

fn uniformSize(utype: UniformType) u32 {
    return switch (utype) {
        .FLOAT, .INT => 4,
        .FLOAT2, .INT2 => 8,
        .FLOAT3, .INT3 => 12,
        .FLOAT4, .INT4 => 16,
        .MAT2 => 32, // 2 columns * 16 bytes (vec4-padded)
        .MAT3 => 48, // 3 columns * 16 bytes (vec4-padded)
        .MAT4 => 64, // 4 columns * 16 bytes
        .INVALID => 0,
    };
}

fn uniformStride(utype: UniformType, array_count: u16) u32 {
    const size = uniformSize(utype);
    const alignment = uniformAlign(utype, array_count);
    if (array_count > 1) {
        return alignUp(size, 16);
    }
    return alignUp(size, alignment);
}

fn alignUp(value: u32, alignment: u32) u32 {
    if (alignment == 0) return value;
    return (value + alignment - 1) & ~(alignment - 1);
}

fn isDefined(defines: [][MaxAttrNameBytes]u8, define_lens: []u8, name: []const u8) bool {
    for (defines, 0..) |def, idx| {
        const len = define_lens[idx];
        if (len == 0) continue;
        if (std.mem.eql(u8, def[0..len], name)) return true;
    }
    return false;
}

fn extractAttrDecl(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "attribute ")) {
        return line["attribute ".len..];
    }
    if (std.mem.startsWith(u8, line, "in ")) {
        return line["in ".len..];
    }
    if (std.mem.startsWith(u8, line, "layout")) {
        if (std.mem.indexOf(u8, line, " in ")) |idx| {
            return line[idx + " in ".len ..];
        }
    }
    return null;
}

fn appendBytes(dest: []u8, dest_len: *usize, bytes: []const u8) !void {
    if (dest_len.* + bytes.len > dest.len) return error.TooLarge;
    @memcpy(dest[dest_len.* .. dest_len.* + bytes.len], bytes);
    dest_len.* += bytes.len;
}

fn appendByte(dest: []u8, dest_len: *usize, value: u8) !void {
    if (dest_len.* + 1 > dest.len) return error.TooLarge;
    dest[dest_len.*] = value;
    dest_len.* += 1;
}

fn replaceWord(src: []const u8, needle: []const u8, replacement: []const u8, dest: []u8) !usize {
    if (needle.len == 0) return error.InvalidNeedle;
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (std.mem.startsWith(u8, src[i..], needle) and isWordBoundary(src, i, needle.len)) {
            if (out_len + replacement.len > dest.len) return error.LineTooLong;
            @memcpy(dest[out_len .. out_len + replacement.len], replacement);
            out_len += replacement.len;
            i += needle.len - 1;
            continue;
        }
        if (out_len + 1 > dest.len) return error.LineTooLong;
        dest[out_len] = src[i];
        out_len += 1;
    }
    return out_len;
}

fn isWordBoundary(src: []const u8, index: usize, len: usize) bool {
    const start_ok = index == 0 or !isWordChar(src[index - 1]);
    const end_index = index + len;
    const end_ok = end_index >= src.len or !isWordChar(src[end_index]);
    return start_ok and end_ok;
}

fn isWordChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or
        ch == '_';
}

var g_program_table: ProgramTable = undefined;
var g_program_table_init: bool = false;

pub fn globalProgramTable() *ProgramTable {
    if (!g_program_table_init) {
        g_program_table.initInPlace();
        g_program_table_init = true;
    }
    return &g_program_table;
}

// =============================================================================
// Tests
// =============================================================================

test "ProgramTable links with compiled shaders" {
    const shaders = shader.globalShaderTable();
    shaders.reset();
    defer shaders.reset();
    const programs = globalProgramTable();
    programs.reset();
    defer programs.reset();

    const vs = try shaders.alloc(.vertex);
    try shaders.setSource(vs, "void main() {}");
    try shaders.compile(vs);
    const fs = try shaders.alloc(.fragment);
    try shaders.setSource(fs, "void main() {}");
    try shaders.compile(fs);

    const pid = try programs.alloc();
    try programs.attachShader(pid, vs, shaders);
    try programs.attachShader(pid, fs, shaders);
    try programs.link(pid, shaders);

    const prog = programs.get(pid) orelse return error.UnexpectedNull;
    try testing.expect(prog.linked);
    try testing.expectEqual(@as(u32, 0), prog.info_log_len);
}

test "ProgramTable link fails without fragment shader" {
    const shaders = shader.globalShaderTable();
    shaders.reset();
    defer shaders.reset();
    const programs = globalProgramTable();
    programs.reset();
    defer programs.reset();

    const vs = try shaders.alloc(.vertex);
    try shaders.setSource(vs, "void main() {}");
    try shaders.compile(vs);

    const pid = try programs.alloc();
    try programs.attachShader(pid, vs, shaders);
    try programs.link(pid, shaders);

    const prog = programs.get(pid) orelse return error.UnexpectedNull;
    try testing.expect(!prog.linked);
    const info_log = programs.getInfoLog(pid) orelse return error.UnexpectedNull;
    try testing.expect(info_log.len > 0);
}

test "ProgramTable link fails when shader not compiled" {
    const shaders = shader.globalShaderTable();
    shaders.reset();
    defer shaders.reset();
    const programs = globalProgramTable();
    programs.reset();
    defer programs.reset();

    const vs = try shaders.alloc(.vertex);
    try shaders.setSource(vs, "void main() {}");
    const fs = try shaders.alloc(.fragment);
    try shaders.setSource(fs, "void main() {}");

    const pid = try programs.alloc();
    try programs.attachShader(pid, vs, shaders);
    try programs.attachShader(pid, fs, shaders);
    try programs.link(pid, shaders);

    const prog = programs.get(pid) orelse return error.UnexpectedNull;
    try testing.expect(!prog.linked);
    const info_log = programs.getInfoLog(pid) orelse return error.UnexpectedNull;
    try testing.expect(info_log.len > 0);
}

test "ProgramTable uniforms store data" {
    const shaders = shader.globalShaderTable();
    shaders.reset();
    defer shaders.reset();
    const programs = globalProgramTable();
    programs.reset();
    defer programs.reset();

    const vs = try shaders.alloc(.vertex);
    try shaders.setSource(vs,
        \\uniform mat4 u_mvp;
        \\attribute vec3 position;
        \\void main() {
        \\  gl_Position = u_mvp * vec4(position, 1.0);
        \\}
    );
    try shaders.compile(vs);

    const fs = try shaders.alloc(.fragment);
    try shaders.setSource(fs,
        \\void main() {
        \\  gl_FragColor = vec4(1.0);
        \\}
    );
    try shaders.compile(fs);

    const pid = try programs.alloc();
    try programs.attachShader(pid, vs, shaders);
    try programs.attachShader(pid, fs, shaders);
    try programs.link(pid, shaders);

    const loc = try programs.getUniformLocation(pid, "u_mvp");
    try testing.expect(loc >= 0);
    const data: [16]f32 = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
    try programs.setUniformFloats(pid, @intCast(loc), data[0..]);

    const prog = programs.get(pid) orelse return error.UnexpectedNull;
    const buf = prog.vs_uniforms.buffer[0..64];
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(data[0..]), buf);
}

test "ProgramTable tracks sampler uniforms" {
    const shaders = shader.globalShaderTable();
    shaders.reset();
    defer shaders.reset();
    const programs = globalProgramTable();
    programs.reset();
    defer programs.reset();

    const vs = try shaders.alloc(.vertex);
    try shaders.setSource(vs,
        \\attribute vec3 position;
        \\void main() {
        \\  gl_Position = vec4(position, 1.0);
        \\}
    );
    try shaders.compile(vs);

    const fs = try shaders.alloc(.fragment);
    try shaders.setSource(fs,
        \\precision mediump float;
        \\uniform sampler2D u_tex;
        \\void main() {
        \\  gl_FragColor = vec4(1.0);
        \\}
    );
    try shaders.compile(fs);

    const pid = try programs.alloc();
    try programs.attachShader(pid, vs, shaders);
    try programs.attachShader(pid, fs, shaders);
    try programs.link(pid, shaders);

    const prog = programs.get(pid) orelse return error.UnexpectedNull;
    try testing.expectEqual(@as(u8, 1), prog.sampler_count);
    const sampler = prog.samplers[0];
    const sampler_name = sampler.name_bytes[0..@as(usize, sampler.name_len)];
    try testing.expectEqualStrings("u_tex", sampler_name);

    const loc = try programs.getUniformLocation(pid, "u_tex");
    try testing.expect(loc >= 0);
    try programs.setUniformInts(pid, @intCast(loc), &[_]i32{2});
    try testing.expectEqual(@as(i32, 2), prog.samplers[0].units[0]);

    const fs_len: usize = @intCast(prog.fragment_source_len);
    const fs_src = prog.fragment_source[0..fs_len];
    try testing.expect(std.mem.indexOf(u8, fs_src, "uniform sampler2D u_tex") != null);
}

test "ProgramTable mat2 and mat3 uniforms" {
    const shaders = shader.globalShaderTable();
    shaders.reset();
    defer shaders.reset();
    const programs = globalProgramTable();
    programs.reset();
    defer programs.reset();

    // Vertex shader with mat2 uniform
    const vs = try shaders.alloc(.vertex);
    try shaders.setSource(vs,
        \\uniform mat2 u_mat2;
        \\uniform mat3 u_mat3;
        \\attribute vec3 position;
        \\void main() {
        \\  vec2 t = u_mat2 * position.xy;
        \\  vec3 n = u_mat3 * position;
        \\  gl_Position = vec4(t, n.z, 1.0);
        \\}
    );
    try shaders.compile(vs);

    const fs = try shaders.alloc(.fragment);
    try shaders.setSource(fs,
        \\void main() {
        \\  gl_FragColor = vec4(1.0);
        \\}
    );
    try shaders.compile(fs);

    const pid = try programs.alloc();
    try programs.attachShader(pid, vs, shaders);
    try programs.attachShader(pid, fs, shaders);
    try programs.link(pid, shaders);

    // Test mat2 uniform location and data
    const loc_mat2 = try programs.getUniformLocation(pid, "u_mat2");
    try testing.expect(loc_mat2 >= 0);

    // mat2 input: 4 floats (column-major) [m00, m10, m01, m11]
    const mat2_data: [4]f32 = .{ 1.0, 2.0, 3.0, 4.0 };
    try programs.setUniformFloats(pid, @intCast(loc_mat2), mat2_data[0..]);

    const prog = programs.get(pid) orelse return error.UnexpectedNull;

    // Helper to read a f32 from buffer at byte offset
    const readF32 = struct {
        fn read(buf: []const u8, offset: usize) f32 {
            const bytes = buf[offset..][0..4];
            return @bitCast(bytes.*);
        }
    }.read;

    // In std140, mat2 is 32 bytes: 2 columns of vec4 (16 bytes each)
    // Column 0: [1.0, 2.0, 0.0, 0.0] at offset 0
    // Column 1: [3.0, 4.0, 0.0, 0.0] at offset 16
    const mat2_buf = prog.vs_uniforms.buffer[0..];
    try testing.expectEqual(@as(f32, 1.0), readF32(mat2_buf, 0)); // m00
    try testing.expectEqual(@as(f32, 2.0), readF32(mat2_buf, 4)); // m10
    try testing.expectEqual(@as(f32, 0.0), readF32(mat2_buf, 8)); // padding
    try testing.expectEqual(@as(f32, 0.0), readF32(mat2_buf, 12)); // padding
    try testing.expectEqual(@as(f32, 3.0), readF32(mat2_buf, 16)); // m01
    try testing.expectEqual(@as(f32, 4.0), readF32(mat2_buf, 20)); // m11
    try testing.expectEqual(@as(f32, 0.0), readF32(mat2_buf, 24)); // padding
    try testing.expectEqual(@as(f32, 0.0), readF32(mat2_buf, 28)); // padding

    // Test mat3 uniform location and data
    const loc_mat3 = try programs.getUniformLocation(pid, "u_mat3");
    try testing.expect(loc_mat3 >= 0);

    // mat3 input: 9 floats (column-major)
    const mat3_data: [9]f32 = .{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0 };
    try programs.setUniformFloats(pid, @intCast(loc_mat3), mat3_data[0..]);

    // In std140, mat3 is 48 bytes: 3 columns of vec4 (16 bytes each)
    // Column 0: [1.0, 2.0, 3.0, 0.0] at offset 32 (after mat2)
    // Column 1: [4.0, 5.0, 6.0, 0.0] at offset 48
    // Column 2: [7.0, 8.0, 9.0, 0.0] at offset 64
    const mat3_buf = prog.vs_uniforms.buffer[32..];
    try testing.expectEqual(@as(f32, 1.0), readF32(mat3_buf, 0)); // m00
    try testing.expectEqual(@as(f32, 2.0), readF32(mat3_buf, 4)); // m10
    try testing.expectEqual(@as(f32, 3.0), readF32(mat3_buf, 8)); // m20
    try testing.expectEqual(@as(f32, 0.0), readF32(mat3_buf, 12)); // padding
    try testing.expectEqual(@as(f32, 4.0), readF32(mat3_buf, 16)); // m01
    try testing.expectEqual(@as(f32, 5.0), readF32(mat3_buf, 20)); // m11
    try testing.expectEqual(@as(f32, 6.0), readF32(mat3_buf, 24)); // m21
    try testing.expectEqual(@as(f32, 0.0), readF32(mat3_buf, 28)); // padding
    try testing.expectEqual(@as(f32, 7.0), readF32(mat3_buf, 32)); // m02
    try testing.expectEqual(@as(f32, 8.0), readF32(mat3_buf, 36)); // m12
    try testing.expectEqual(@as(f32, 9.0), readF32(mat3_buf, 40)); // m22
    try testing.expectEqual(@as(f32, 0.0), readF32(mat3_buf, 44)); // padding
}
