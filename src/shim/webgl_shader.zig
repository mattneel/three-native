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
    source: ?[]u8,
    compiled: bool,
    info_len: u32,
    info_log: ?[]u8,
};

pub const ShaderTable = struct {
    entries: [MaxShaders]Entry,
    count: u16,
    allocator: std.mem.Allocator,

    const Self = @This();

    const Entry = struct {
        active: bool,
        generation: u16,
        shader: Shader,
    };

    pub fn init() Self {
        return initWithAllocator(std.heap.page_allocator);
    }

    pub fn initWithAllocator(allocator: std.mem.Allocator) Self {
        var entries: [MaxShaders]Entry = undefined;
        for (&entries, 0..) |*entry, idx| {
            entry.* = .{
                .active = false,
                .generation = 1,
                .shader = .{
                    .id = .{
                        .index = @intCast(idx),
                        .generation = 0,
                    },
                    .kind = .vertex,
                    .source_len = 0,
                    .source = null,
                    .compiled = false,
                    .info_len = 0,
                    .info_log = null,
                },
            };
        }
        return .{
            .entries = entries,
            .count = 0,
            .allocator = allocator,
        };
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
                if (entry.shader.source) |buf| {
                    self.allocator.free(buf);
                }
                entry.shader = .{
                    .id = id,
                    .kind = kind,
                    .source_len = 0,
                    .source = null,
                    .compiled = false,
                    .info_len = 0,
                    .info_log = null,
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
        if (entry.shader.source) |buf| {
            self.allocator.free(buf);
        }
        if (entry.shader.info_log) |buf| {
            self.allocator.free(buf);
        }
        if (source.len == 0) {
            entry.shader.source = null;
            entry.shader.source_len = 0;
            entry.shader.compiled = false;
            entry.shader.info_log = null;
            entry.shader.info_len = 0;
            return;
        }
        const copy = try self.allocator.alloc(u8, source.len);
        @memcpy(copy, source);
        entry.shader.source = copy;
        entry.shader.source_len = @intCast(source.len);
        entry.shader.compiled = false;
        entry.shader.info_log = null;
        entry.shader.info_len = 0;
    }

    pub fn getSource(self: *Self, id: ShaderId) ?[]const u8 {
        if (!self.isValid(id)) return null;
        return self.entries[id.index].shader.source;
    }

    pub fn compile(self: *Self, id: ShaderId) !void {
        if (!self.isValid(id)) return error.InvalidHandle;
        var entry = &self.entries[id.index];
        if (entry.shader.info_log) |buf| {
            self.allocator.free(buf);
            entry.shader.info_log = null;
            entry.shader.info_len = 0;
        }
        if (entry.shader.source == null or entry.shader.source_len == 0) {
            entry.shader.compiled = false;
            try self.setInfoLog(entry, "shader source missing");
            return;
        }
        entry.shader.compiled = true;
    }

    pub fn getInfoLog(self: *Self, id: ShaderId) ?[]const u8 {
        if (!self.isValid(id)) return null;
        return self.entries[id.index].shader.info_log;
    }

    pub fn free(self: *Self, id: ShaderId) bool {
        if (!self.isValid(id)) return false;
        var entry = &self.entries[id.index];
        if (entry.shader.source) |buf| {
            self.allocator.free(buf);
        }
        if (entry.shader.info_log) |buf| {
            self.allocator.free(buf);
        }
        entry.active = false;
        entry.generation +%= 1;
        entry.shader = .{
            .id = .{
                .index = id.index,
                .generation = 0,
            },
            .kind = .vertex,
            .source_len = 0,
            .source = null,
            .compiled = false,
            .info_len = 0,
            .info_log = null,
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
        self.deinit();
        self.* = Self.initWithAllocator(self.allocator);
    }

    pub fn deinit(self: *Self) void {
        for (&self.entries) |*entry| {
            if (entry.active) {
                if (entry.shader.source) |buf| {
                    self.allocator.free(buf);
                    entry.shader.source = null;
                }
                if (entry.shader.info_log) |buf| {
                    self.allocator.free(buf);
                    entry.shader.info_log = null;
                }
                entry.active = false;
            }
        }
        self.count = 0;
    }

    fn setInfoLog(self: *Self, entry: *Entry, log: []const u8) !void {
        if (log.len > MaxShaderInfoLogBytes) return error.TooLarge;
        if (entry.shader.info_log) |buf| {
            self.allocator.free(buf);
        }
        if (log.len == 0) {
            entry.shader.info_log = null;
            entry.shader.info_len = 0;
            return;
        }
        const copy = try self.allocator.alloc(u8, log.len);
        @memcpy(copy, log);
        entry.shader.info_log = copy;
        entry.shader.info_len = @intCast(log.len);
    }
};

var g_shader_table: ShaderTable = ShaderTable.init();

pub fn globalShaderTable() *ShaderTable {
    return &g_shader_table;
}

// =============================================================================
// Tests
// =============================================================================

test "ShaderTable allocates and frees" {
    var table = ShaderTable.initWithAllocator(testing.allocator);
    defer table.deinit();
    const id = try table.alloc(.vertex);
    try testing.expect(table.isValid(id));
    const sh = table.get(id) orelse return error.UnexpectedNull;
    try testing.expectEqual(ShaderKind.vertex, sh.kind);
    try testing.expectEqual(@as(u32, 0), sh.source_len);
    try testing.expect(sh.source == null);
    try testing.expect(!sh.compiled);

    try testing.expect(table.free(id));
    try testing.expect(!table.isValid(id));
}

test "ShaderTable rejects allocation when full" {
    var table = ShaderTable.initWithAllocator(testing.allocator);
    defer table.deinit();
    for (0..MaxShaders) |_| {
        _ = try table.alloc(.fragment);
    }
    try testing.expectError(error.AtCapacity, table.alloc(.vertex));
}

test "ShaderTable invalidates stale handles" {
    var table = ShaderTable.initWithAllocator(testing.allocator);
    defer table.deinit();
    const id1 = try table.alloc(.vertex);
    try testing.expect(table.free(id1));

    const id2 = try table.alloc(.vertex);
    try testing.expectEqual(id1.index, id2.index);
    try testing.expect(id1.generation != id2.generation);
    try testing.expect(!table.isValid(id1));
}

test "ShaderTable free rejects invalid handles" {
    var table = ShaderTable.initWithAllocator(testing.allocator);
    defer table.deinit();
    const bogus = ShaderId{ .index = @intCast(MaxShaders + 1), .generation = 1 };
    try testing.expect(!table.free(bogus));
}

test "ShaderTable setSource stores a copy" {
    var table = ShaderTable.initWithAllocator(testing.allocator);
    defer table.deinit();
    const id = try table.alloc(.vertex);
    const src = "void main() {}";
    try table.setSource(id, src);

    const view = table.getSource(id) orelse return error.UnexpectedNull;
    try testing.expectEqual(@as(usize, src.len), view.len);
    try testing.expectEqualSlices(u8, src, view);

    const sh = table.get(id) orelse return error.UnexpectedNull;
    try testing.expectEqual(@as(u32, src.len), sh.source_len);
    try testing.expect(!sh.compiled);
    try testing.expect(sh.info_log == null);

    try testing.expect(table.free(id));
}

test "ShaderTable setSource rejects oversize" {
    var table = ShaderTable.initWithAllocator(testing.allocator);
    defer table.deinit();
    const id = try table.alloc(.vertex);
    const data = try testing.allocator.alloc(u8, MaxShaderSourceBytes + 1);
    defer testing.allocator.free(data);
    try testing.expectError(error.TooLarge, table.setSource(id, data));
}

test "ShaderTable compile fails without source" {
    var table = ShaderTable.initWithAllocator(testing.allocator);
    defer table.deinit();
    const id = try table.alloc(.fragment);
    try table.compile(id);
    const sh = table.get(id) orelse return error.UnexpectedNull;
    try testing.expect(!sh.compiled);
    const log = table.getInfoLog(id) orelse return error.UnexpectedNull;
    try testing.expect(log.len > 0);
}

test "ShaderTable compile succeeds with source" {
    var table = ShaderTable.initWithAllocator(testing.allocator);
    defer table.deinit();
    const id = try table.alloc(.vertex);
    try table.setSource(id, "void main() {}");
    try table.compile(id);
    const sh = table.get(id) orelse return error.UnexpectedNull;
    try testing.expect(sh.compiled);
    try testing.expect(sh.info_log == null);
}
