//! WebGL shim types (Phase 2.0)
//!
//! First TDD slice: Context handle table with generation checks.

const std = @import("std");
const testing = std.testing;

pub const MaxContexts: usize = 4;

pub const ContextId = packed struct(u32) {
    index: u16,
    generation: u16,
};

pub const ContextDesc = struct {
    width: u32 = 800,
    height: u32 = 600,
};

pub const Context = struct {
    id: ContextId,
    width: u32,
    height: u32,
};

pub const ContextTable = struct {
    entries: [MaxContexts]Entry,
    count: u16,

    const Self = @This();

    const Entry = struct {
        active: bool,
        generation: u16,
        context: Context,
    };

    pub fn init() Self {
        var entries: [MaxContexts]Entry = undefined;
        for (&entries, 0..) |*entry, idx| {
            entry.* = .{
                .active = false,
                .generation = 1,
                .context = .{
                    .id = .{
                        .index = @intCast(idx),
                        .generation = 0,
                    },
                    .width = 0,
                    .height = 0,
                },
            };
        }
        return .{
            .entries = entries,
            .count = 0,
        };
    }

    pub fn alloc(self: *Self, desc: ContextDesc) !ContextId {
        if (self.count >= MaxContexts) {
            return error.AtCapacity;
        }

        for (&self.entries, 0..) |*entry, idx| {
            if (!entry.active) {
                if (entry.generation == 0) {
                    entry.generation = 1;
                }
                const id = ContextId{
                    .index = @intCast(idx),
                    .generation = entry.generation,
                };
                entry.context = .{
                    .id = id,
                    .width = desc.width,
                    .height = desc.height,
                };
                entry.active = true;
                self.count += 1;
                return id;
            }
        }
        return error.AtCapacity;
    }

    pub fn get(self: *Self, id: ContextId) ?*Context {
        if (!self.isValid(id)) return null;
        return &self.entries[id.index].context;
    }

    pub fn free(self: *Self, id: ContextId) bool {
        if (!self.isValid(id)) return false;
        var entry = &self.entries[id.index];
        entry.active = false;
        entry.generation +%= 1;
        self.count -= 1;
        return true;
    }

    pub fn isValid(self: *Self, id: ContextId) bool {
        if (id.index >= MaxContexts) return false;
        const entry = &self.entries[id.index];
        return entry.active and entry.generation == id.generation;
    }
};

// =============================================================================
// WebGL buffer handles (Phase 2.2, first TDD slice)
// =============================================================================

pub const MaxBuffers: usize = 256;

pub const BufferId = packed struct(u32) {
    index: u16,
    generation: u16,
};

pub const BufferUsage = enum {
    vertex,
    index,
    uniform,
};

pub const BufferDesc = struct {
    size: u32 = 0,
    usage: BufferUsage = .vertex,
};

pub const Buffer = struct {
    id: BufferId,
    size: u32,
    usage: BufferUsage,
};

pub const BufferTable = struct {
    entries: [MaxBuffers]Entry,
    count: u16,

    const Self = @This();

    const Entry = struct {
        active: bool,
        generation: u16,
        buffer: Buffer,
    };

    pub fn init() Self {
        var entries: [MaxBuffers]Entry = undefined;
        for (&entries, 0..) |*entry, idx| {
            entry.* = .{
                .active = false,
                .generation = 1,
                .buffer = .{
                    .id = .{
                        .index = @intCast(idx),
                        .generation = 0,
                    },
                    .size = 0,
                    .usage = .vertex,
                },
            };
        }
        return .{
            .entries = entries,
            .count = 0,
        };
    }

    pub fn alloc(self: *Self, desc: BufferDesc) !BufferId {
        if (self.count >= MaxBuffers) {
            return error.AtCapacity;
        }

        for (&self.entries, 0..) |*entry, idx| {
            if (!entry.active) {
                if (entry.generation == 0) {
                    entry.generation = 1;
                }
                const id = BufferId{
                    .index = @intCast(idx),
                    .generation = entry.generation,
                };
                entry.buffer = .{
                    .id = id,
                    .size = desc.size,
                    .usage = desc.usage,
                };
                entry.active = true;
                self.count += 1;
                return id;
            }
        }
        return error.AtCapacity;
    }

    pub fn get(self: *Self, id: BufferId) ?*Buffer {
        if (!self.isValid(id)) return null;
        return &self.entries[id.index].buffer;
    }

    pub fn free(self: *Self, id: BufferId) bool {
        if (!self.isValid(id)) return false;
        var entry = &self.entries[id.index];
        entry.active = false;
        entry.generation +%= 1;
        self.count -= 1;
        return true;
    }

    pub fn isValid(self: *Self, id: BufferId) bool {
        if (id.index >= MaxBuffers) return false;
        const entry = &self.entries[id.index];
        return entry.active and entry.generation == id.generation;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ContextTable allocates and frees" {
    var table = ContextTable.init();
    try testing.expectEqual(@as(u16, 0), table.count);

    const id = try table.alloc(.{ .width = 320, .height = 240 });
    try testing.expect(table.isValid(id));
    try testing.expectEqual(@as(u16, 1), table.count);

    const ctx = table.get(id) orelse return error.UnexpectedNull;
    try testing.expectEqual(@as(u32, 320), ctx.width);
    try testing.expectEqual(@as(u32, 240), ctx.height);

    try testing.expect(table.free(id));
    try testing.expectEqual(@as(u16, 0), table.count);
    try testing.expect(!table.isValid(id));
    try testing.expect(table.get(id) == null);
}

test "ContextTable rejects allocation when full" {
    var table = ContextTable.init();
    for (0..MaxContexts) |_| {
        _ = try table.alloc(.{});
    }
    try testing.expectError(error.AtCapacity, table.alloc(.{}));
}

test "ContextTable invalidates stale handles" {
    var table = ContextTable.init();
    const id1 = try table.alloc(.{});
    try testing.expect(table.free(id1));

    const id2 = try table.alloc(.{});
    try testing.expectEqual(id1.index, id2.index);
    try testing.expect(id1.generation != id2.generation);
    try testing.expect(!table.isValid(id1));
}

test "ContextTable free rejects invalid handles" {
    var table = ContextTable.init();
    const bogus = ContextId{ .index = @intCast(MaxContexts + 1), .generation = 1 };
    try testing.expect(!table.free(bogus));

    const id = try table.alloc(.{});
    try testing.expect(table.free(id));
    try testing.expect(!table.free(id));
}

test "BufferTable allocates and frees" {
    var table = BufferTable.init();
    try testing.expectEqual(@as(u16, 0), table.count);

    const id = try table.alloc(.{ .size = 1024, .usage = .vertex });
    try testing.expect(table.isValid(id));
    try testing.expectEqual(@as(u16, 1), table.count);

    const buf = table.get(id) orelse return error.UnexpectedNull;
    try testing.expectEqual(@as(u32, 1024), buf.size);
    try testing.expectEqual(BufferUsage.vertex, buf.usage);

    try testing.expect(table.free(id));
    try testing.expectEqual(@as(u16, 0), table.count);
    try testing.expect(!table.isValid(id));
}

test "BufferTable rejects allocation when full" {
    var table = BufferTable.init();
    for (0..MaxBuffers) |_| {
        _ = try table.alloc(.{});
    }
    try testing.expectError(error.AtCapacity, table.alloc(.{}));
}

test "BufferTable invalidates stale handles" {
    var table = BufferTable.init();
    const id1 = try table.alloc(.{});
    try testing.expect(table.free(id1));

    const id2 = try table.alloc(.{});
    try testing.expectEqual(id1.index, id2.index);
    try testing.expect(id1.generation != id2.generation);
    try testing.expect(!table.isValid(id1));
}

test "BufferTable free rejects invalid handles" {
    var table = BufferTable.init();
    const bogus = BufferId{ .index = @intCast(MaxBuffers + 1), .generation = 1 };
    try testing.expect(!table.free(bogus));

    const id = try table.alloc(.{});
    try testing.expect(table.free(id));
    try testing.expect(!table.free(id));
}
