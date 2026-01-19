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
pub const MaxBufferBytes: usize = 16 * 1024 * 1024;
// CPU backfill pool: 4096 * 4 KiB = 16 MiB total.
// Napkin: enough for ~4 buffers at 4 MiB each before backend is live.
pub const CpuBlockSizeBytes: usize = 4096;
pub const CpuBlockCount: usize = 4096;
pub const CpuPoolBytes: usize = CpuBlockSizeBytes * CpuBlockCount;

pub const BufferBackend = struct {
    pub const Handle = u32;

    ctx: ?*anyopaque,
    create: *const fn (ctx: ?*anyopaque, size: usize, usage: BufferUsage) Handle,
    update: *const fn (ctx: ?*anyopaque, handle: Handle, data: []const u8) void,
    destroy: *const fn (ctx: ?*anyopaque, handle: Handle) void,
};

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
    data_len: u32,
    update_count: u32,
    backend: BufferBackend.Handle,
    cpu_block_start: u16,
    cpu_block_count: u16,
};

const CpuSlice = struct {
    block_start: u16,
    block_count: u16,
    size: u32,
};

const CpuBufferPool = struct {
    data: [CpuPoolBytes]u8 = undefined,
    used: [CpuBlockCount]bool = [_]bool{false} ** CpuBlockCount,

    const Self = @This();

    fn reset(self: *Self) void {
        @memset(self.used[0..], false);
    }

    fn alloc(self: *Self, size: usize) !CpuSlice {
        if (size == 0) return error.InvalidSize;
        const blocks_needed = @as(usize, (size + CpuBlockSizeBytes - 1) / CpuBlockSizeBytes);
        if (blocks_needed > CpuBlockCount) return error.TooLarge;
        var run_len: usize = 0;
        var run_start: usize = 0;
        for (0..CpuBlockCount) |idx| {
            if (!self.used[idx]) {
                if (run_len == 0) run_start = idx;
                run_len += 1;
                if (run_len >= blocks_needed) {
                    for (run_start..run_start + blocks_needed) |block_idx| {
                        self.used[block_idx] = true;
                    }
                    return .{
                        .block_start = @intCast(run_start),
                        .block_count = @intCast(blocks_needed),
                        .size = @intCast(size),
                    };
                }
            } else {
                run_len = 0;
            }
        }
        return error.OutOfMemory;
    }

    fn free(self: *Self, cpu_slice: CpuSlice) void {
        if (cpu_slice.block_count == 0) return;
        const start: usize = @intCast(cpu_slice.block_start);
        const count: usize = @intCast(cpu_slice.block_count);
        for (start..start + count) |idx| {
            self.used[idx] = false;
        }
    }

    fn slice(self: *Self, cpu_slice: CpuSlice) []u8 {
        const start = @as(usize, cpu_slice.block_start) * CpuBlockSizeBytes;
        return self.data[start .. start + @as(usize, cpu_slice.size)];
    }
};

var g_cpu_pool: CpuBufferPool = CpuBufferPool{};

pub const BufferTable = struct {
    entries: [MaxBuffers]Entry,
    count: u16,
    cpu_pool: *CpuBufferPool,

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
                    .data_len = 0,
                    .update_count = 0,
                    .backend = 0,
                    .cpu_block_start = 0,
                    .cpu_block_count = 0,
                },
            };
        }
        return .{
            .entries = entries,
            .count = 0,
            .cpu_pool = &g_cpu_pool,
        };
    }

    pub fn initWithAllocator(_: std.mem.Allocator) Self {
        return init();
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
                    .data_len = 0,
                    .update_count = 0,
                    .backend = 0,
                    .cpu_block_start = 0,
                    .cpu_block_count = 0,
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
        if (entry.buffer.cpu_block_count != 0) {
            const slice = CpuSlice{
                .block_start = entry.buffer.cpu_block_start,
                .block_count = entry.buffer.cpu_block_count,
                .size = entry.buffer.data_len,
            };
            self.cpu_pool.free(slice);
        }
        entry.active = false;
        entry.generation +%= 1;
        entry.buffer = .{
            .id = .{
                .index = id.index,
                .generation = 0,
            },
            .size = 0,
            .usage = .vertex,
            .data_len = 0,
            .update_count = 0,
            .backend = 0,
            .cpu_block_start = 0,
            .cpu_block_count = 0,
        };
        self.count -= 1;
        return true;
    }

    pub fn isValid(self: *Self, id: BufferId) bool {
        if (id.index >= MaxBuffers) return false;
        const entry = &self.entries[id.index];
        return entry.active and entry.generation == id.generation;
    }

    pub fn updateData(self: *Self, id: BufferId, data: []const u8) !void {
        if (!self.isValid(id)) return error.InvalidHandle;
        if (data.len > MaxBufferBytes) return error.TooLarge;
        var buffer = &self.entries[id.index].buffer;
        if (buffer.cpu_block_count != 0) {
            self.cpu_pool.free(.{
                .block_start = buffer.cpu_block_start,
                .block_count = buffer.cpu_block_count,
                .size = buffer.data_len,
            });
            buffer.cpu_block_count = 0;
            buffer.cpu_block_start = 0;
        }
        if (data.len > 0) {
            const slice = try self.cpu_pool.alloc(data.len);
            const dst = self.cpu_pool.slice(slice);
            @memcpy(dst, data);
            buffer.cpu_block_start = slice.block_start;
            buffer.cpu_block_count = slice.block_count;
        }
        buffer.size = @intCast(data.len);
        buffer.data_len = @intCast(data.len);
        buffer.update_count +%= 1;
    }

    pub fn uploadData(self: *Self, id: BufferId, data: []const u8, backend: *const BufferBackend) !void {
        if (!self.isValid(id)) return error.InvalidHandle;
        if (data.len > MaxBufferBytes) return error.TooLarge;

        var buffer = &self.entries[id.index].buffer;
        if (buffer.backend == 0) {
            const handle = backend.create(backend.ctx, data.len, buffer.usage);
            if (handle == 0) return error.BackendFailed;
            buffer.backend = handle;
        }
        backend.update(backend.ctx, buffer.backend, data);
        if (buffer.cpu_block_count != 0) {
            self.cpu_pool.free(.{
                .block_start = buffer.cpu_block_start,
                .block_count = buffer.cpu_block_count,
                .size = buffer.data_len,
            });
            buffer.cpu_block_count = 0;
            buffer.cpu_block_start = 0;
        }

        buffer.size = @intCast(data.len);
        buffer.data_len = @intCast(data.len);
        buffer.update_count +%= 1;
    }

    pub fn freeWithBackend(self: *Self, id: BufferId, backend: *const BufferBackend) bool {
        if (!self.isValid(id)) return false;
        const entry = &self.entries[id.index];
        if (entry.buffer.backend != 0) {
            backend.destroy(backend.ctx, entry.buffer.backend);
        }
        return self.free(id);
    }

    pub fn backfill(self: *Self, backend: *const BufferBackend) !void {
        for (&self.entries) |*entry| {
            if (!entry.active) continue;
            var buffer = &entry.buffer;
            if (buffer.backend != 0) continue;
            if (buffer.cpu_block_count != 0) {
                const data = self.cpu_pool.slice(.{
                    .block_start = buffer.cpu_block_start,
                    .block_count = buffer.cpu_block_count,
                    .size = buffer.data_len,
                });
                if (data.len == 0) continue;
                const handle = backend.create(backend.ctx, data.len, buffer.usage);
                if (handle == 0) return error.BackendFailed;
                buffer.backend = handle;
                backend.update(backend.ctx, buffer.backend, data);
                self.cpu_pool.free(.{
                    .block_start = buffer.cpu_block_start,
                    .block_count = buffer.cpu_block_count,
                    .size = buffer.data_len,
                });
                buffer.cpu_block_count = 0;
                buffer.cpu_block_start = 0;
            }
        }
    }

    pub fn deinit(self: *Self) void {
        self.* = Self.init();
        self.cpu_pool.reset();
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
    var table = BufferTable.initWithAllocator(testing.allocator);
    defer table.deinit();
    try testing.expectEqual(@as(u16, 0), table.count);

    const id = try table.alloc(.{ .size = 1024, .usage = .vertex });
    try testing.expect(table.isValid(id));
    try testing.expectEqual(@as(u16, 1), table.count);

    const buf = table.get(id) orelse return error.UnexpectedNull;
    try testing.expectEqual(@as(u32, 1024), buf.size);
    try testing.expectEqual(BufferUsage.vertex, buf.usage);
    try testing.expectEqual(@as(u32, 0), buf.data_len);
    try testing.expectEqual(@as(u32, 0), buf.update_count);

    try testing.expect(table.free(id));
    try testing.expectEqual(@as(u16, 0), table.count);
    try testing.expect(!table.isValid(id));
}

test "BufferTable rejects allocation when full" {
    var table = BufferTable.initWithAllocator(testing.allocator);
    defer table.deinit();
    for (0..MaxBuffers) |_| {
        _ = try table.alloc(.{});
    }
    try testing.expectError(error.AtCapacity, table.alloc(.{}));
}

test "BufferTable invalidates stale handles" {
    var table = BufferTable.initWithAllocator(testing.allocator);
    defer table.deinit();
    const id1 = try table.alloc(.{});
    try testing.expect(table.free(id1));

    const id2 = try table.alloc(.{});
    try testing.expectEqual(id1.index, id2.index);
    try testing.expect(id1.generation != id2.generation);
    try testing.expect(!table.isValid(id1));
}

test "BufferTable free rejects invalid handles" {
    var table = BufferTable.initWithAllocator(testing.allocator);
    defer table.deinit();
    const bogus = BufferId{ .index = @intCast(MaxBuffers + 1), .generation = 1 };
    try testing.expect(!table.free(bogus));

    const id = try table.alloc(.{});
    try testing.expect(table.free(id));
    try testing.expect(!table.free(id));
}

test "BufferTable free resets buffer state" {
    var table = BufferTable.initWithAllocator(testing.allocator);
    defer table.deinit();
    const id = try table.alloc(.{ .size = 128, .usage = .vertex });
    const data = [_]u8{0} ** 64;
    try table.updateData(id, data[0..]);

    try testing.expect(table.free(id));
    const entry = table.entries[id.index];
    try testing.expect(!entry.active);
    try testing.expectEqual(@as(u32, 0), entry.buffer.size);
    try testing.expectEqual(@as(u32, 0), entry.buffer.data_len);
    try testing.expectEqual(@as(u32, 0), entry.buffer.update_count);
}

test "BufferTable updateData updates size and count" {
    var table = BufferTable.initWithAllocator(testing.allocator);
    defer table.deinit();
    const id = try table.alloc(.{});

    const data_a = [_]u8{0} ** 128;
    try table.updateData(id, data_a[0..]);
    const buf = table.get(id) orelse return error.UnexpectedNull;
    try testing.expectEqual(@as(u32, 128), buf.size);
    try testing.expectEqual(@as(u32, 128), buf.data_len);
    try testing.expectEqual(@as(u32, 1), buf.update_count);

    const data_b = [_]u8{0} ** 256;
    try table.updateData(id, data_b[0..]);
    try testing.expectEqual(@as(u32, 256), buf.size);
    try testing.expectEqual(@as(u32, 256), buf.data_len);
    try testing.expectEqual(@as(u32, 2), buf.update_count);
}

test "BufferTable updateData rejects oversize" {
    var table = BufferTable.initWithAllocator(testing.allocator);
    defer table.deinit();
    const id = try table.alloc(.{});
    const data = try testing.allocator.alloc(u8, MaxBufferBytes + 1);
    defer testing.allocator.free(data);
    try testing.expectError(error.TooLarge, table.updateData(id, data));
}

test "BufferTable uploadData uses backend once" {
    const BackendStub = struct {
        create_calls: u32 = 0,
        update_calls: u32 = 0,
        destroy_calls: u32 = 0,
        last_size: usize = 0,
        last_usage: BufferUsage = .vertex,
        last_handle: BufferBackend.Handle = 0,
        last_update_len: usize = 0,
        next_handle: BufferBackend.Handle = 1,

        const Self = @This();

        fn create(ctx: ?*anyopaque, size: usize, usage: BufferUsage) BufferBackend.Handle {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.create_calls += 1;
            self.last_size = size;
            self.last_usage = usage;
            const handle = self.next_handle;
            self.next_handle += 1;
            self.last_handle = handle;
            return handle;
        }

        fn update(ctx: ?*anyopaque, handle: BufferBackend.Handle, data: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.update_calls += 1;
            self.last_handle = handle;
            self.last_update_len = data.len;
        }

        fn destroy(ctx: ?*anyopaque, handle: BufferBackend.Handle) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.destroy_calls += 1;
            self.last_handle = handle;
        }
    };

    var table = BufferTable.initWithAllocator(testing.allocator);
    defer table.deinit();
    var stub = BackendStub{};
    const backend = BufferBackend{
        .ctx = &stub,
        .create = BackendStub.create,
        .update = BackendStub.update,
        .destroy = BackendStub.destroy,
    };

    const id = try table.alloc(.{ .usage = .vertex });
    const data_a = [_]u8{0} ** 32;
    try table.uploadData(id, data_a[0..], &backend);
    try testing.expectEqual(@as(u32, 1), stub.create_calls);
    try testing.expectEqual(@as(u32, 1), stub.update_calls);
    try testing.expectEqual(@as(usize, 32), stub.last_update_len);

    const buf = table.get(id) orelse return error.UnexpectedNull;
    try testing.expect(buf.backend != 0);

    const data_b = [_]u8{0} ** 64;
    try table.uploadData(id, data_b[0..], &backend);
    try testing.expectEqual(@as(u32, 1), stub.create_calls);
    try testing.expectEqual(@as(u32, 2), stub.update_calls);

    try testing.expect(table.freeWithBackend(id, &backend));
    try testing.expectEqual(@as(u32, 1), stub.destroy_calls);
}
