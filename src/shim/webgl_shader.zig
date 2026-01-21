//! WebGL shader handle tables (Phase 2.3)
//!
//! First TDD slice: allocate/free shader handles with generation checks.

const std = @import("std");
const testing = std.testing;

pub const MaxShaders: usize = 128;
pub const MaxShaderSourceBytes: usize = 64 * 1024;
pub const MaxShaderInfoLogBytes: usize = 4 * 1024;

pub const ShaderId = packed struct(u32) {
    index: u16,
    generation: u16,
};

pub const ShaderKind = enum {
    vertex,
    fragment,
};

pub const Shader = struct {
    id: ShaderId,
    kind: ShaderKind,
    source_len: u32,
    compiled: bool,
    info_len: u32,
};

pub const ShaderTable = struct {
    entries: [MaxShaders]Entry,
    count: u16,

    const Self = @This();

    const Entry = struct {
        active: bool,
        generation: u16,
        shader: Shader,
        source_bytes: [MaxShaderSourceBytes]u8,
        info_bytes: [MaxShaderInfoLogBytes]u8,
    };

    /// Initialize table - zeros memory at runtime, no comptime cost
    pub fn initInPlace(self: *Self) void {
        @memset(std.mem.asBytes(self), 0);
        // Set non-zero defaults (generation = 1)
        for (&self.entries, 0..) |*entry, idx| {
            entry.generation = 1;
            entry.shader.id.index = @intCast(idx);
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

    pub fn alloc(self: *Self, kind: ShaderKind) !ShaderId {
        if (self.count >= MaxShaders) return error.AtCapacity;
        for (&self.entries, 0..) |*entry, idx| {
            if (!entry.active) {
                if (entry.generation == 0) entry.generation = 1;
                const id = ShaderId{
                    .index = @intCast(idx),
                    .generation = entry.generation,
                };
                entry.shader = .{
                    .id = id,
                    .kind = kind,
                    .source_len = 0,
                    .compiled = false,
                    .info_len = 0,
                };
                entry.active = true;
                self.count += 1;
                return id;
            }
        }
        return error.AtCapacity;
    }

    pub fn get(self: *Self, id: ShaderId) ?*Shader {
        if (!self.isValid(id)) return null;
        return &self.entries[id.index].shader;
    }

    pub fn setSource(self: *Self, id: ShaderId, source: []const u8) !void {
        if (!self.isValid(id)) return error.InvalidHandle;
        if (source.len > MaxShaderSourceBytes) return error.TooLarge;
        var entry = &self.entries[id.index];
        if (source.len == 0) {
            entry.shader.source_len = 0;
            entry.shader.compiled = false;
            entry.shader.info_len = 0;
            return;
        }
        @memcpy(entry.source_bytes[0..source.len], source);
        entry.shader.source_len = @intCast(source.len);
        entry.shader.compiled = false;
        entry.shader.info_len = 0;
    }

    pub fn getSource(self: *Self, id: ShaderId) ?[]const u8 {
        if (!self.isValid(id)) return null;
        const entry = &self.entries[id.index];
        if (entry.shader.source_len == 0) return null;
        return entry.source_bytes[0..@as(usize, entry.shader.source_len)];
    }

    pub fn compile(self: *Self, id: ShaderId) !void {
        if (!self.isValid(id)) return error.InvalidHandle;
        var entry = &self.entries[id.index];
        entry.shader.info_len = 0;
        if (entry.shader.source_len == 0) {
            entry.shader.compiled = false;
            try self.setInfoLog(entry, "shader source missing");
            return;
        }
        entry.shader.compiled = true;
    }

    pub fn getInfoLog(self: *Self, id: ShaderId) ?[]const u8 {
        if (!self.isValid(id)) return null;
        const entry = &self.entries[id.index];
        if (entry.shader.info_len == 0) return null;
        return entry.info_bytes[0..@as(usize, entry.shader.info_len)];
    }

    pub fn free(self: *Self, id: ShaderId) bool {
        if (!self.isValid(id)) return false;
        var entry = &self.entries[id.index];
        entry.active = false;
        entry.generation +%= 1;
        entry.shader = .{
            .id = .{
                .index = id.index,
                .generation = 0,
            },
            .kind = .vertex,
            .source_len = 0,
            .compiled = false,
            .info_len = 0,
        };
        self.count -= 1;
        return true;
    }

    pub fn isValid(self: *Self, id: ShaderId) bool {
        if (id.index >= MaxShaders) return false;
        const entry = &self.entries[id.index];
        return entry.active and entry.generation == id.generation;
    }

    pub fn reset(self: *Self) void {
        self.initInPlace();
    }

    pub fn deinit(self: *Self) void {
        self.initInPlace();
    }

    fn setInfoLog(self: *Self, entry: *Entry, log: []const u8) !void {
        if (log.len > MaxShaderInfoLogBytes) return error.TooLarge;
        _ = self;
        if (log.len == 0) {
            entry.shader.info_len = 0;
            return;
        }
        @memcpy(entry.info_bytes[0..log.len], log);
        entry.shader.info_len = @intCast(log.len);
    }
};

var g_shader_table: ShaderTable = undefined;
var g_shader_table_init: bool = false;

pub fn globalShaderTable() *ShaderTable {
    if (!g_shader_table_init) {
        g_shader_table.initInPlace();
        g_shader_table_init = true;
    }
    return &g_shader_table;
}

// =============================================================================
// Tests
// =============================================================================

test "ShaderTable allocates and frees" {
    const table = globalShaderTable();
    table.reset();
    defer table.reset();
    const id = try table.alloc(.vertex);
    try testing.expect(table.isValid(id));
    const sh = table.get(id) orelse return error.UnexpectedNull;
    try testing.expectEqual(ShaderKind.vertex, sh.kind);
    try testing.expectEqual(@as(u32, 0), sh.source_len);
    try testing.expectEqual(@as(u32, 0), sh.info_len);
    try testing.expect(!sh.compiled);

    try testing.expect(table.free(id));
    try testing.expect(!table.isValid(id));
}

test "ShaderTable rejects allocation when full" {
    const table = globalShaderTable();
    table.reset();
    defer table.reset();
    for (0..MaxShaders) |_| {
        _ = try table.alloc(.fragment);
    }
    try testing.expectError(error.AtCapacity, table.alloc(.vertex));
}

test "ShaderTable invalidates stale handles" {
    const table = globalShaderTable();
    table.reset();
    defer table.reset();
    const id1 = try table.alloc(.vertex);
    try testing.expect(table.free(id1));

    const id2 = try table.alloc(.vertex);
    try testing.expectEqual(id1.index, id2.index);
    try testing.expect(id1.generation != id2.generation);
    try testing.expect(!table.isValid(id1));
}

test "ShaderTable free rejects invalid handles" {
    const table = globalShaderTable();
    table.reset();
    defer table.reset();
    const bogus = ShaderId{ .index = @intCast(MaxShaders + 1), .generation = 1 };
    try testing.expect(!table.free(bogus));
}

test "ShaderTable setSource stores a copy" {
    const table = globalShaderTable();
    table.reset();
    defer table.reset();
    const id = try table.alloc(.vertex);
    const src = "void main() {}";
    try table.setSource(id, src);

    const view = table.getSource(id) orelse return error.UnexpectedNull;
    try testing.expectEqual(@as(usize, src.len), view.len);
    try testing.expectEqualSlices(u8, src, view);

    const sh = table.get(id) orelse return error.UnexpectedNull;
    try testing.expectEqual(@as(u32, src.len), sh.source_len);
    try testing.expect(!sh.compiled);
    try testing.expectEqual(@as(u32, 0), sh.info_len);

    try testing.expect(table.free(id));
}

test "ShaderTable setSource rejects oversize" {
    const table = globalShaderTable();
    table.reset();
    defer table.reset();
    const id = try table.alloc(.vertex);
    const data = try testing.allocator.alloc(u8, MaxShaderSourceBytes + 1);
    defer testing.allocator.free(data);
    try testing.expectError(error.TooLarge, table.setSource(id, data));
}

test "ShaderTable compile fails without source" {
    const table = globalShaderTable();
    table.reset();
    defer table.reset();
    const id = try table.alloc(.fragment);
    try table.compile(id);
    const sh = table.get(id) orelse return error.UnexpectedNull;
    try testing.expect(!sh.compiled);
    const log = table.getInfoLog(id) orelse return error.UnexpectedNull;
    try testing.expect(log.len > 0);
}

test "ShaderTable compile succeeds with source" {
    const table = globalShaderTable();
    table.reset();
    defer table.reset();
    const id = try table.alloc(.vertex);
    try table.setSource(id, "void main() {}");
    try table.compile(id);
    const sh = table.get(id) orelse return error.UnexpectedNull;
    try testing.expect(sh.compiled);
    try testing.expectEqual(@as(u32, 0), sh.info_len);
}
