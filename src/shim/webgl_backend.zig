//! Sokol backend adapter for WebGL buffer uploads.

const sokol = @import("sokol");
const sg = sokol.gfx;
const webgl = @import("webgl.zig");

pub fn sokolBufferBackend() webgl.BufferBackend {
    return .{
        .ctx = null,
        .create = create,
        .update = update,
        .destroy = destroy,
    };
}

pub const sokol_backend: webgl.BufferBackend = sokolBufferBackend();

pub fn getSokolBackend() *const webgl.BufferBackend {
    return &sokol_backend;
}

fn create(_: ?*anyopaque, size: usize, usage: webgl.BufferUsage) webgl.BufferBackend.Handle {
    const desc = sg.BufferDesc{
        .size = size,
        .usage = toUsage(usage),
    };
    const buf = sg.makeBuffer(desc);
    return buf.id;
}

fn update(_: ?*anyopaque, handle: webgl.BufferBackend.Handle, data: []const u8) void {
    if (handle == 0) return;
    sg.updateBuffer(.{ .id = handle }, .{ .ptr = data.ptr, .size = data.len });
}

fn destroy(_: ?*anyopaque, handle: webgl.BufferBackend.Handle) void {
    if (handle == 0) return;
    sg.destroyBuffer(.{ .id = handle });
}

fn toUsage(usage: webgl.BufferUsage) sg.BufferUsage {
    return switch (usage) {
        .vertex => .{
            .vertex_buffer = true,
            .dynamic_update = true,
        },
        .index => .{
            .index_buffer = true,
            .dynamic_update = true,
        },
        .uniform => .{
            .storage_buffer = true,
            .dynamic_update = true,
        },
    };
}
