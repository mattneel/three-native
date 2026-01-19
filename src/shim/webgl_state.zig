//! WebGL bind state tracking (Phase 2.2)
//!
//! First slice: track array/element array buffer bindings with validation.

const std = @import("std");
const testing = std.testing;
const webgl = @import("webgl.zig");

pub const BufferTarget = enum {
    array,
    element_array,
};

pub const BindState = struct {
    array_buffer: ?webgl.BufferId = null,
    element_array_buffer: ?webgl.BufferId = null,

    const Self = @This();

    pub fn bindBuffer(self: *Self, table: *webgl.BufferTable, target: BufferTarget, id: webgl.BufferId) !void {
        if (!table.isValid(id)) {
            return error.InvalidHandle;
        }
        switch (target) {
            .array => self.array_buffer = id,
            .element_array => self.element_array_buffer = id,
        }
    }

    pub fn unbindBuffer(self: *Self, target: BufferTarget) void {
        switch (target) {
            .array => self.array_buffer = null,
            .element_array => self.element_array_buffer = null,
        }
    }

    pub fn isBound(self: *const Self, target: BufferTarget, id: webgl.BufferId) bool {
        return switch (target) {
            .array => self.array_buffer != null and self.array_buffer.? == id,
            .element_array => self.element_array_buffer != null and self.element_array_buffer.? == id,
        };
    }

    pub fn bufferData(
        self: *Self,
        table: *webgl.BufferTable,
        target: BufferTarget,
        data: []const u8,
        backend: ?*const webgl.BufferBackend,
    ) !void {
        const id = switch (target) {
            .array => self.array_buffer orelse return error.NoBufferBound,
            .element_array => self.element_array_buffer orelse return error.NoBufferBound,
        };

        const buf = table.get(id) orelse return error.InvalidHandle;
        switch (target) {
            .array => if (buf.usage == .index) return error.WrongTarget,
            .element_array => if (buf.usage != .index) return error.WrongTarget,
        }

        if (backend) |b| {
            try table.uploadData(id, data, b);
        } else {
            try table.updateData(id, data);
        }
    }

    pub fn onBufferDeleted(self: *Self, id: webgl.BufferId) void {
        if (self.array_buffer != null and self.array_buffer.? == id) {
            self.array_buffer = null;
        }
        if (self.element_array_buffer != null and self.element_array_buffer.? == id) {
            self.element_array_buffer = null;
        }
    }
};

pub const BufferManager = struct {
    buffers: webgl.BufferTable,
    binds: BindState,
    backend: ?*const webgl.BufferBackend,

    const Self = @This();

    pub fn init() Self {
        return .{
            .buffers = webgl.BufferTable.init(),
            .binds = BindState{},
            .backend = null,
        };
    }

    pub fn initWithBackend(backend: *const webgl.BufferBackend) Self {
        return .{
            .buffers = webgl.BufferTable.init(),
            .binds = BindState{},
            .backend = backend,
        };
    }

    pub fn setBackend(self: *Self, backend: *const webgl.BufferBackend) void {
        self.backend = backend;
    }

    pub fn reset(self: *Self) void {
        self.* = Self.init();
    }

    pub fn createBuffer(self: *Self, desc: webgl.BufferDesc) !webgl.BufferId {
        return self.buffers.alloc(desc);
    }

    pub fn deleteBuffer(self: *Self, id: webgl.BufferId) bool {
        self.binds.onBufferDeleted(id);
        if (self.backend) |b| {
            return self.buffers.freeWithBackend(id, b);
        }
        return self.buffers.free(id);
    }

    pub fn bindBuffer(self: *Self, target: BufferTarget, id: webgl.BufferId) !void {
        try self.binds.bindBuffer(&self.buffers, target, id);
    }

    pub fn unbindBuffer(self: *Self, target: BufferTarget) void {
        self.binds.unbindBuffer(target);
    }

    pub fn bufferData(self: *Self, target: BufferTarget, data: []const u8) !void {
        try self.binds.bufferData(&self.buffers, target, data, self.backend);
    }
};

var g_buffer_manager: BufferManager = BufferManager.init();

pub fn globalBufferManager() *BufferManager {
    return &g_buffer_manager;
}

// =============================================================================
// Tests
// =============================================================================

test "BindState binds array buffer" {
    var table = webgl.BufferTable.init();
    var state = BindState{};

    const id = try table.alloc(.{ .size = 64, .usage = .vertex });
    try state.bindBuffer(&table, .array, id);
    try testing.expect(state.isBound(.array, id));
}

test "BindState binds element array buffer" {
    var table = webgl.BufferTable.init();
    var state = BindState{};

    const id = try table.alloc(.{ .size = 64, .usage = .index });
    try state.bindBuffer(&table, .element_array, id);
    try testing.expect(state.isBound(.element_array, id));
}

test "BindState rejects invalid handles" {
    var table = webgl.BufferTable.init();
    var state = BindState{};

    const bogus = webgl.BufferId{ .index = @intCast(webgl.MaxBuffers + 1), .generation = 1 };
    try testing.expectError(error.InvalidHandle, state.bindBuffer(&table, .array, bogus));
    try testing.expect(state.array_buffer == null);
}

test "BindState unbind clears state" {
    var table = webgl.BufferTable.init();
    var state = BindState{};

    const id = try table.alloc(.{});
    try state.bindBuffer(&table, .array, id);
    state.unbindBuffer(.array);
    try testing.expect(state.array_buffer == null);
}

test "BindState rejects stale handles" {
    var table = webgl.BufferTable.init();
    var state = BindState{};

    const id = try table.alloc(.{});
    try testing.expect(table.free(id));
    try testing.expectError(error.InvalidHandle, state.bindBuffer(&table, .array, id));
}

test "BindState bufferData updates bound buffer" {
    var table = webgl.BufferTable.init();
    var state = BindState{};

    const id = try table.alloc(.{ .usage = .vertex });
    try state.bindBuffer(&table, .array, id);
    const data = [_]u8{0} ** 64;
    try state.bufferData(&table, .array, data[0..], null);

    const buf = table.get(id) orelse return error.UnexpectedNull;
    try testing.expectEqual(@as(u32, 64), buf.data_len);
    try testing.expectEqual(@as(u32, 1), buf.update_count);
}

test "BindState bufferData rejects missing bind" {
    var table = webgl.BufferTable.init();
    var state = BindState{};

    _ = try table.alloc(.{});
    const data = [_]u8{0} ** 16;
    try testing.expectError(error.NoBufferBound, state.bufferData(&table, .array, data[0..], null));
}

test "BindState bufferData rejects wrong target" {
    var table = webgl.BufferTable.init();
    var state = BindState{};

    const id = try table.alloc(.{ .usage = .index });
    try state.bindBuffer(&table, .array, id);
    const data = [_]u8{0} ** 16;
    try testing.expectError(error.WrongTarget, state.bufferData(&table, .array, data[0..], null));
}

test "BindState bufferData rejects oversize" {
    var table = webgl.BufferTable.init();
    var state = BindState{};

    const id = try table.alloc(.{ .usage = .vertex });
    try state.bindBuffer(&table, .array, id);
    const data = try testing.allocator.alloc(u8, webgl.MaxBufferBytes + 1);
    defer testing.allocator.free(data);
    try testing.expectError(error.TooLarge, state.bufferData(&table, .array, data, null));
}

test "BindState onBufferDeleted clears bindings" {
    var table = webgl.BufferTable.init();
    var state = BindState{};

    const a = try table.alloc(.{ .usage = .vertex });
    const e = try table.alloc(.{ .usage = .index });
    try state.bindBuffer(&table, .array, a);
    try state.bindBuffer(&table, .element_array, e);

    state.onBufferDeleted(a);
    try testing.expect(state.array_buffer == null);
    try testing.expect(state.element_array_buffer != null);

    state.onBufferDeleted(e);
    try testing.expect(state.element_array_buffer == null);
}

test "BufferManager create/bind/data/delete works" {
    var mgr = BufferManager.init();

    const id = try mgr.createBuffer(.{ .usage = .vertex });
    try mgr.bindBuffer(.array, id);

    const data = [_]u8{0} ** 32;
    try mgr.bufferData(.array, data[0..]);

    const buf = mgr.buffers.get(id) orelse return error.UnexpectedNull;
    try testing.expectEqual(@as(u32, 32), buf.data_len);

    try testing.expect(mgr.deleteBuffer(id));
    try testing.expect(mgr.binds.array_buffer == null);
}

test "BufferManager uses backend when provided" {
    const BackendStub = struct {
        create_calls: u32 = 0,
        update_calls: u32 = 0,
        destroy_calls: u32 = 0,
        next_handle: webgl.BufferBackend.Handle = 1,

        const Self = @This();

        fn create(ctx: ?*anyopaque, size: usize, usage: webgl.BufferUsage) webgl.BufferBackend.Handle {
            _ = size;
            _ = usage;
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.create_calls += 1;
            const h = self.next_handle;
            self.next_handle += 1;
            return h;
        }

        fn update(ctx: ?*anyopaque, handle: webgl.BufferBackend.Handle, data: []const u8) void {
            _ = handle;
            _ = data;
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.update_calls += 1;
        }

        fn destroy(ctx: ?*anyopaque, handle: webgl.BufferBackend.Handle) void {
            _ = handle;
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.destroy_calls += 1;
        }
    };

    var stub = BackendStub{};
    const backend = webgl.BufferBackend{
        .ctx = &stub,
        .create = BackendStub.create,
        .update = BackendStub.update,
        .destroy = BackendStub.destroy,
    };

    var mgr = BufferManager.initWithBackend(&backend);
    const id = try mgr.createBuffer(.{ .usage = .vertex });
    try mgr.bindBuffer(.array, id);

    const data = [_]u8{0} ** 16;
    try mgr.bufferData(.array, data[0..]);
    try testing.expectEqual(@as(u32, 1), stub.create_calls);
    try testing.expectEqual(@as(u32, 1), stub.update_calls);

    try testing.expect(mgr.deleteBuffer(id));
    try testing.expectEqual(@as(u32, 1), stub.destroy_calls);
}

test "globalBufferManager wires backend" {
    const BackendStub = struct {
        create_calls: u32 = 0,
        update_calls: u32 = 0,
        destroy_calls: u32 = 0,
        next_handle: webgl.BufferBackend.Handle = 1,

        const Self = @This();

        fn create(ctx: ?*anyopaque, size: usize, usage: webgl.BufferUsage) webgl.BufferBackend.Handle {
            _ = size;
            _ = usage;
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.create_calls += 1;
            const h = self.next_handle;
            self.next_handle += 1;
            return h;
        }

        fn update(ctx: ?*anyopaque, handle: webgl.BufferBackend.Handle, data: []const u8) void {
            _ = handle;
            _ = data;
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.update_calls += 1;
        }

        fn destroy(ctx: ?*anyopaque, handle: webgl.BufferBackend.Handle) void {
            _ = handle;
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.destroy_calls += 1;
        }
    };

    var stub = BackendStub{};
    const backend = webgl.BufferBackend{
        .ctx = &stub,
        .create = BackendStub.create,
        .update = BackendStub.update,
        .destroy = BackendStub.destroy,
    };

    const mgr = globalBufferManager();
    mgr.reset();
    mgr.setBackend(&backend);

    const id = try mgr.createBuffer(.{ .usage = .vertex });
    try mgr.bindBuffer(.array, id);
    const data = [_]u8{0} ** 8;
    try mgr.bufferData(.array, data[0..]);

    try testing.expectEqual(@as(u32, 1), stub.create_calls);
    try testing.expectEqual(@as(u32, 1), stub.update_calls);
    try testing.expect(mgr.deleteBuffer(id));
    try testing.expectEqual(@as(u32, 1), stub.destroy_calls);

    mgr.reset();
}
