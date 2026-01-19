//! WebGL program handle tables (Phase 2.3)
//!
//! TDD slice: program creation, attachment, and link status tracking.

const std = @import("std");
const testing = std.testing;
const shader = @import("webgl_shader.zig");
const sokol = @import("sokol");
const sg = sokol.gfx;

pub const MaxPrograms: usize = 64;
pub const MaxProgramInfoLogBytes: usize = 4 * 1024;
pub const MaxProgramAttrs: usize = 16;
pub const MaxProgramUniforms: usize = 16;
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
    utype: sg.UniformType,
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
};

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
};

fn emptyUniformBlock() UniformBlock {
    const empty_entry = UniformEntry{
        .name_len = 0,
        .name_bytes = [_]u8{0} ** MaxUniformNameBytes,
        .utype = .INVALID,
        .array_count = 0,
        .offset = 0,
        .stride = 0,
        .size = 0,
    };
    return .{
        .size = 0,
        .count = 0,
        .items = [_]UniformEntry{empty_entry} ** MaxProgramUniforms,
        .buffer = [_]u8{0} ** MaxUniformBlockBytes,
    };
}

fn emptySamplerEntry() SamplerEntry {
    return .{
        .name_len = 0,
        .name_bytes = [_]u8{0} ** MaxUniformNameBytes,
        .kind = .sampler2d,
        .stage = .vertex,
        .array_count = 1,
        .units = [_]i32{0} ** MaxUniformArrayCount,
    };
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

    pub fn init() Self {
        return initWithAllocator(std.heap.page_allocator);
    }

    pub fn initWithAllocator(_: std.mem.Allocator) Self {
        var entries: [MaxPrograms]Entry = undefined;
        for (&entries, 0..) |*entry, idx| {
            entry.* = .{
                .active = false,
                .generation = 1,
                .program = .{
                    .id = .{
                        .index = @intCast(idx),
                        .generation = 0,
                    },
                    .linked = false,
                    .vertex_shader = null,
                    .fragment_shader = null,
                    .info_log_len = 0,
                    .info_log_bytes = [_]u8{0} ** MaxProgramInfoLogBytes,
                    .backend_shader = .{},
                    .vertex_source_len = 0,
                    .vertex_source = [_]u8{0} ** MaxTranslatedShaderBytes,
                    .fragment_source_len = 0,
                    .fragment_source = [_]u8{0} ** MaxTranslatedShaderBytes,
                    .attr_count = 0,
                    .attr_name_lens = [_]u8{0} ** MaxProgramAttrs,
                    .attr_names = [_][MaxAttrNameBytes]u8{[_]u8{0} ** MaxAttrNameBytes} ** MaxProgramAttrs,
                    .vs_uniforms = emptyUniformBlock(),
                    .fs_uniforms = emptyUniformBlock(),
                    .sampler_count = 0,
                    .samplers = [_]SamplerEntry{emptySamplerEntry()} ** MaxProgramSamplers,
                    .link_version = 0,
                },
            };
        }
        return .{
            .entries = entries,
            .count = 0,
        };
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
                entry.program = .{
                    .id = id,
                    .linked = false,
                    .vertex_shader = null,
                    .fragment_shader = null,
                    .info_log_len = 0,
                    .info_log_bytes = [_]u8{0} ** MaxProgramInfoLogBytes,
                    .backend_shader = .{},
                    .vertex_source_len = 0,
                    .vertex_source = [_]u8{0} ** MaxTranslatedShaderBytes,
                    .fragment_source_len = 0,
                    .fragment_source = [_]u8{0} ** MaxTranslatedShaderBytes,
                    .attr_count = 0,
                    .attr_name_lens = [_]u8{0} ** MaxProgramAttrs,
                    .attr_names = [_][MaxAttrNameBytes]u8{[_]u8{0} ** MaxAttrNameBytes} ** MaxProgramAttrs,
                    .vs_uniforms = emptyUniformBlock(),
                    .fs_uniforms = emptyUniformBlock(),
                    .sampler_count = 0,
                    .samplers = [_]SamplerEntry{emptySamplerEntry()} ** MaxProgramSamplers,
                    .link_version = 0,
                };
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

        var vs_uniforms: [MaxProgramUniforms]UniformDecl = undefined;
        var vs_uniform_count: u8 = 0;
        var vs_samplers: [MaxProgramSamplers]SamplerDecl = undefined;
        var vs_sampler_count: u8 = 0;
        var vs_block_size: u32 = 0;
        var vs_len: u32 = 0;
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
        var fs_len: u32 = 0;
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
        ) catch {
            try self.setInfoLog(entry, "fragment shader translate failed");
            return;
        };
        entry.program.fragment_source_len = fs_len;

        const vs_count: usize = @intCast(vs_uniform_count);
        self.storeUniforms(entry, .vertex, vs_uniforms[0..vs_count], vs_block_size) catch {
            try self.setInfoLog(entry, "vertex uniforms rejected");
            return;
        };
        const fs_count: usize = @intCast(fs_uniform_count);
        self.storeUniforms(entry, .fragment, fs_uniforms[0..fs_count], fs_block_size) catch {
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

        const desc = buildShaderDesc(entry);
        const shd = sg.makeShader(desc);
        entry.program.backend_shader = shd;
        if (sg.queryShaderState(shd) != .VALID) {
            sg.destroyShader(shd);
            entry.program.backend_shader = .{};
            try self.setInfoLog(entry, "backend shader compile failed");
            return;
        }

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
        const entry = self.get(id) orelse return error.InvalidHandle;
        const info = decodeUniformLocation(loc);
        if (info.kind != .block) return error.InvalidLocation;
        const block = if (info.stage == .vertex) &entry.vs_uniforms else &entry.fs_uniforms;
        if (info.index >= block.count) return error.InvalidLocation;
        const uniform = block.items[@as(usize, info.index)];
        if (block.size == 0) return error.NoUniformBuffer;
        const size = @as(usize, block.size);
        try writeUniformFloats(uniform, block.buffer[0..size], values);
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
        entry.program = .{
            .id = .{
                .index = id.index,
                .generation = 0,
            },
            .linked = false,
            .vertex_shader = null,
            .fragment_shader = null,
            .info_log_len = 0,
            .info_log_bytes = [_]u8{0} ** MaxProgramInfoLogBytes,
            .backend_shader = .{},
            .vertex_source_len = 0,
            .vertex_source = [_]u8{0} ** MaxTranslatedShaderBytes,
            .fragment_source_len = 0,
            .fragment_source = [_]u8{0} ** MaxTranslatedShaderBytes,
            .attr_count = 0,
            .attr_name_lens = [_]u8{0} ** MaxProgramAttrs,
            .attr_names = [_][MaxAttrNameBytes]u8{[_]u8{0} ** MaxAttrNameBytes} ** MaxProgramAttrs,
            .vs_uniforms = emptyUniformBlock(),
            .fs_uniforms = emptyUniformBlock(),
            .sampler_count = 0,
            .samplers = [_]SamplerEntry{emptySamplerEntry()} ** MaxProgramSamplers,
            .link_version = 0,
        };
        self.count -= 1;
        return true;
    }

    pub fn isValid(self: *Self, id: ProgramId) bool {
        if (id.index >= MaxPrograms) return false;
        const entry = &self.entries[id.index];
        return entry.active and entry.generation == id.generation;
    }

    pub fn reset(self: *Self) void {
        self.* = Self.init();
    }

    pub fn deinit(self: *Self) void {
        self.* = Self.init();
    }

    fn setInfoLog(self: *Self, entry: *Entry, log: []const u8) !void {
        if (log.len > MaxProgramInfoLogBytes) return error.TooLarge;
        self.clearInfoLog(entry);
        if (log.len == 0) return;
        @memcpy(entry.program.info_log_bytes[0..log.len], log);
        entry.program.info_log_len = @intCast(log.len);
    }

    fn clearInfoLog(self: *Self, entry: *Entry) void {
        _ = self;
        entry.program.info_log_len = 0;
    }

    fn clearUniformBlock(self: *Self, block: *UniformBlock) void {
        _ = self;
        block.* = emptyUniformBlock();
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
        entry.program.attr_name_lens = [_]u8{0} ** MaxProgramAttrs;
        entry.program.attr_names = [_][MaxAttrNameBytes]u8{[_]u8{0} ** MaxAttrNameBytes} ** MaxProgramAttrs;
        entry.program.attr_count = 0;
        entry.program.sampler_count = 0;
        entry.program.samplers = [_]SamplerEntry{emptySamplerEntry()} ** MaxProgramSamplers;
        self.clearUniforms(entry);
    }

    fn collectAttrNames(self: *Self, entry: *Entry, source: []const u8) !void {
        _ = self;
        entry.program.attr_name_lens = [_]u8{0} ** MaxProgramAttrs;
        entry.program.attr_names = [_][MaxAttrNameBytes]u8{[_]u8{0} ** MaxAttrNameBytes} ** MaxProgramAttrs;
        entry.program.attr_count = 0;
        var it = std.mem.splitScalar(u8, source, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trimLeft(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "#version")) continue;
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

    fn storeUniforms(self: *Self, entry: *Entry, stage: UniformStage, decls: []UniformDecl, block_size: u32) !void {
        _ = self;
        const block = if (stage == .vertex) &entry.program.vs_uniforms else &entry.program.fs_uniforms;
        block.* = emptyUniformBlock();
        if (decls.len == 0) return;
        if (decls.len > MaxProgramUniforms) return error.TooManyUniforms;
        if (block_size > MaxUniformBlockBytes) return error.UniformBlockTooLarge;
        block.size = block_size;
        block.count = @intCast(decls.len);
        for (decls, 0..) |decl, idx| {
            if (decl.name.len >= MaxUniformNameBytes) return error.UniformNameTooLong;
            @memcpy(block.items[idx].name_bytes[0..decl.name.len], decl.name);
            block.items[idx].name_bytes[decl.name.len] = 0;
            block.items[idx].name_len = @intCast(decl.name.len);
            block.items[idx].utype = decl.utype;
            block.items[idx].array_count = decl.array_count;
            block.items[idx].offset = decl.offset;
            block.items[idx].stride = decl.stride;
            block.items[idx].size = decl.size;
        }
        if (block_size > 0) {
            const size: usize = @intCast(block_size);
            @memset(block.buffer[0..size], 0);
        }
    }

    fn storeSamplers(self: *Self, entry: *Entry, stage: UniformStage, decls: []SamplerDecl) !void {
        _ = self;
        if (decls.len == 0) return;
        for (decls) |decl| {
            if (entry.program.sampler_count >= MaxProgramSamplers) return error.TooManySamplers;
            if (decl.name.len >= MaxUniformNameBytes) return error.UniformNameTooLong;
            const index: usize = @intCast(entry.program.sampler_count);
            entry.program.samplers[index] = emptySamplerEntry();
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
        return desc;
    }
};

fn applyUniformBlock(desc: *sg.ShaderDesc, index: usize, stage: sg.ShaderStage, block: *const UniformBlock) void {
    if (block.count == 0 or block.size == 0) return;
    if (index >= desc.uniform_blocks.len) return;
    desc.uniform_blocks[index].stage = stage;
    desc.uniform_blocks[index].size = block.size;
    desc.uniform_blocks[index].layout = .STD140;
    for (block.items, 0..) |item, idx| {
        if (idx >= @as(usize, block.count)) break;
        if (item.name_len == 0) continue;
        desc.uniform_blocks[index].glsl_uniforms[idx] = .{
            .type = item.utype,
            .array_count = item.array_count,
            .glsl_name = item.name_bytes[0..].ptr,
        };
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

fn uniformComponents(utype: sg.UniformType) u32 {
    return switch (utype) {
        .FLOAT, .INT => 1,
        .FLOAT2, .INT2 => 2,
        .FLOAT3, .INT3 => 3,
        .FLOAT4, .INT4 => 4,
        .MAT4 => 16,
        else => 0,
    };
}

fn writeUniformFloats(uniform: UniformEntry, buffer: []u8, values: []const f32) !void {
    switch (uniform.utype) {
        .FLOAT, .FLOAT2, .FLOAT3, .FLOAT4, .MAT4 => {},
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
}

const ShaderStage = enum { vertex, fragment };

const UniformStage = enum(u8) { vertex = 0, fragment = 1 };

const UniformDecl = struct {
    name: []const u8,
    utype: sg.UniformType,
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
) !void {
    if (source.len > shader.MaxShaderSourceBytes) return error.TooLarge;
    uniform_count.* = 0;
    sampler_count.* = 0;
    block_size.* = 0;

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
                    uniforms[count] = decl;
                    uniform_count.* += 1;
                },
                .sampler => |decl| {
                    const count: usize = @intCast(sampler_count.*);
                    if (count >= MaxProgramSamplers) return error.TooManySamplers;
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

    if (uniform_count.* > 0) {
        const count: usize = @intCast(uniform_count.*);
        block_size.* = try layoutUniforms(uniforms[0..count]);
    }

    var header_buf: [MaxTranslatedShaderBytes]u8 = undefined;
    var header_len: usize = 0;
    try appendBytes(header_buf[0..], &header_len, "#version 330\n");
    const needs_frag_color = stage == .fragment and std.mem.indexOf(u8, source, "gl_FragColor") != null;
    if (needs_frag_color) {
        try appendBytes(header_buf[0..], &header_len, "out vec4 fragColor;\n");
    }
    if (uniform_count.* > 0) {
        const count: usize = @intCast(uniform_count.*);
        const block_name = if (stage == .vertex) "vs_params" else "fs_params";
        try appendBytes(header_buf[0..], &header_len, "layout(std140) uniform ");
        try appendBytes(header_buf[0..], &header_len, block_name);
        try appendBytes(header_buf[0..], &header_len, " {\n");
        for (uniforms[0..count]) |u| {
            try appendBytes(header_buf[0..], &header_len, "  ");
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
        try appendBytes(header_buf[0..], &header_len, "};\n");
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

fn isPrecision(token: []const u8) bool {
    return std.mem.eql(u8, token, "lowp") or std.mem.eql(u8, token, "mediump") or std.mem.eql(u8, token, "highp");
}

fn uniformTypeFromGlsl(token: []const u8) ?sg.UniformType {
    if (std.mem.eql(u8, token, "float")) return .FLOAT;
    if (std.mem.eql(u8, token, "vec2")) return .FLOAT2;
    if (std.mem.eql(u8, token, "vec3")) return .FLOAT3;
    if (std.mem.eql(u8, token, "vec4")) return .FLOAT4;
    if (std.mem.eql(u8, token, "int")) return .INT;
    if (std.mem.eql(u8, token, "ivec2")) return .INT2;
    if (std.mem.eql(u8, token, "ivec3")) return .INT3;
    if (std.mem.eql(u8, token, "ivec4")) return .INT4;
    if (std.mem.eql(u8, token, "mat4")) return .MAT4;
    return null;
}

fn samplerKindFromGlsl(token: []const u8) ?SamplerKind {
    if (std.mem.eql(u8, token, "sampler2D")) return .sampler2d;
    if (std.mem.eql(u8, token, "samplerCube")) return .samplerCube;
    return null;
}

fn glslType(utype: sg.UniformType) []const u8 {
    return switch (utype) {
        .FLOAT => "float",
        .FLOAT2 => "vec2",
        .FLOAT3 => "vec3",
        .FLOAT4 => "vec4",
        .INT => "int",
        .INT2 => "ivec2",
        .INT3 => "ivec3",
        .INT4 => "ivec4",
        .MAT4 => "mat4",
        else => "float",
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
            if (u.utype != .FLOAT4 and u.utype != .INT4 and u.utype != .MAT4) {
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

fn uniformAlign(utype: sg.UniformType, array_count: u16) u32 {
    if (array_count > 1) return 16;
    return switch (utype) {
        .FLOAT, .INT => 4,
        .FLOAT2, .INT2 => 8,
        .FLOAT3, .FLOAT4, .INT3, .INT4, .MAT4 => 16,
        else => 4,
    };
}

fn uniformSize(utype: sg.UniformType) u32 {
    return switch (utype) {
        .FLOAT, .INT => 4,
        .FLOAT2, .INT2 => 8,
        .FLOAT3, .INT3 => 12,
        .FLOAT4, .INT4 => 16,
        .MAT4 => 64,
        else => 0,
    };
}

fn uniformStride(utype: sg.UniformType, array_count: u16) u32 {
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

var g_program_table: ProgramTable = ProgramTable.init();

pub fn globalProgramTable() *ProgramTable {
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
    const log = programs.getInfoLog(pid) orelse return error.UnexpectedNull;
    try testing.expect(log.len > 0);
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
    const log = programs.getInfoLog(pid) orelse return error.UnexpectedNull;
    try testing.expect(log.len > 0);
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
