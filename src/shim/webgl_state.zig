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
};

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
