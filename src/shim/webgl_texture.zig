//! WebGL texture management (M3)
//!
//! Handle table with generation checks for texture lifecycle management,
//! CPU-side pixel data pool, and texture binding state tracking.

const std = @import("std");
const testing = std.testing;
const sokol = @import("sokol");
const sg = sokol.gfx;

// =============================================================================
// Constants
// =============================================================================

pub const MaxTextures: usize = 256;
pub const MaxTextureUnits: usize = 8;

// CPU texture data pool: 64 MB total
// Block size of 16 KiB is reasonable for texture data (4K x 1 row of RGBA)
pub const CpuBlockSizeBytes: usize = 16 * 1024;
pub const CpuBlockCount: usize = 4096; // 4096 * 16 KiB = 64 MiB
pub const CpuPoolBytes: usize = CpuBlockSizeBytes * CpuBlockCount;

// =============================================================================
// Types
// =============================================================================

pub const TextureId = packed struct(u32) {
    index: u16,
    generation: u16,

    pub fn toU32(self: TextureId) u32 {
        return @bitCast(self);
    }

    pub fn fromU32(value: u32) TextureId {
        return @bitCast(value);
    }
};

pub const TextureTarget = enum(u32) {
    texture_2d = 0x0DE1,
    texture_cube_map = 0x8513,
};

pub const TextureFormat = enum(u32) {
    rgba = 0x1908,
    rgb = 0x1907,
    luminance_alpha = 0x190A,
    luminance = 0x1909,
    alpha = 0x1906,
};

pub const TextureFilter = enum(u32) {
    nearest = 0x2600,
    linear = 0x2601,
    nearest_mipmap_nearest = 0x2700,
    linear_mipmap_nearest = 0x2701,
    nearest_mipmap_linear = 0x2702,
    linear_mipmap_linear = 0x2703,
};

pub const TextureWrap = enum(u32) {
    repeat = 0x2901,
    clamp_to_edge = 0x812F,
    mirrored_repeat = 0x8370,
};

pub const TextureParams = struct {
    min_filter: TextureFilter = .nearest_mipmap_linear,
    mag_filter: TextureFilter = .linear,
    wrap_s: TextureWrap = .repeat,
    wrap_t: TextureWrap = .repeat,
};

pub const Texture = struct {
    id: TextureId,
    target: TextureTarget,
    width: u32,
    height: u32,
    format: TextureFormat,
    internal_format: u32,
    pixel_type: u32,
    data_len: u32,
    params: TextureParams,
    backend: sg.Image, // Sokol image handle (set in T3)
    backend_view: sg.View, // Sokol view for binding (set in T3)
    cpu_block_start: u16,
    cpu_block_count: u16,
    dirty: bool, // True if CPU data needs upload to GPU
};

// =============================================================================
// CPU Data Pool
// =============================================================================

const CpuSlice = struct {
    block_start: u16,
    block_count: u16,
    size: u32,
};

const CpuTexturePool = struct {
    data: [CpuPoolBytes]u8 = undefined,
    used: [CpuBlockCount]bool = [_]bool{false} ** CpuBlockCount,

    const Self = @This();

    fn reset(self: *Self) void {
        @memset(self.used[0..], false);
    }

    fn alloc(self: *Self, size: usize) !CpuSlice {
        if (size == 0) return error.InvalidSize;
        const blocks_needed = (size + CpuBlockSizeBytes - 1) / CpuBlockSizeBytes;
        if (blocks_needed > CpuBlockCount) return error.TooLarge;

        // Find contiguous free blocks
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

    fn constSlice(self: *const Self, cpu_slice: CpuSlice) []const u8 {
        const start = @as(usize, cpu_slice.block_start) * CpuBlockSizeBytes;
        return self.data[start .. start + @as(usize, cpu_slice.size)];
    }
};

var g_cpu_pool: CpuTexturePool = CpuTexturePool{};

// =============================================================================
// Texture Table
// =============================================================================

pub const TextureTable = struct {
    entries: [MaxTextures]Entry,
    count: u16,
    cpu_pool: *CpuTexturePool,

    const Self = @This();

    const Entry = struct {
        active: bool,
        generation: u16,
        texture: Texture,
    };

    pub fn init() Self {
        var entries: [MaxTextures]Entry = undefined;
        for (&entries, 0..) |*entry, idx| {
            entry.* = .{
                .active = false,
                .generation = 1,
                .texture = .{
                    .id = .{ .index = @intCast(idx), .generation = 0 },
                    .target = .texture_2d,
                    .width = 0,
                    .height = 0,
                    .format = .rgba,
                    .internal_format = 0x1908, // GL_RGBA
                    .pixel_type = 0x1401, // GL_UNSIGNED_BYTE
                    .data_len = 0,
                    .params = .{},
                    .backend = .{},
                    .backend_view = .{},
                    .cpu_block_start = 0,
                    .cpu_block_count = 0,
                    .dirty = false,
                },
            };
        }
        return .{
            .entries = entries,
            .count = 0,
            .cpu_pool = &g_cpu_pool,
        };
    }

    pub fn reset(self: *Self) void {
        for (&self.entries) |*entry| {
            if (entry.active) {
                // Free CPU pool blocks
                if (entry.texture.cpu_block_count > 0) {
                    self.cpu_pool.free(.{
                        .block_start = entry.texture.cpu_block_start,
                        .block_count = entry.texture.cpu_block_count,
                        .size = entry.texture.data_len,
                    });
                }
                // Destroy backend resources if valid
                if (entry.texture.backend_view.id != 0) {
                    sg.destroyView(entry.texture.backend_view);
                }
                if (entry.texture.backend.id != 0) {
                    sg.destroyImage(entry.texture.backend);
                }
            }
            entry.active = false;
            entry.generation = 1;
            entry.texture.cpu_block_start = 0;
            entry.texture.cpu_block_count = 0;
            entry.texture.data_len = 0;
            entry.texture.backend = .{};
            entry.texture.backend_view = .{};
            entry.texture.dirty = false;
        }
        self.count = 0;
        self.cpu_pool.reset();
    }

    pub fn alloc(self: *Self) !TextureId {
        if (self.count >= MaxTextures) {
            return error.AtCapacity;
        }

        for (&self.entries, 0..) |*entry, idx| {
            if (!entry.active) {
                if (entry.generation == 0) {
                    entry.generation = 1;
                }
                const id = TextureId{
                    .index = @intCast(idx),
                    .generation = entry.generation,
                };
                entry.texture = .{
                    .id = id,
                    .target = .texture_2d,
                    .width = 0,
                    .height = 0,
                    .format = .rgba,
                    .internal_format = 0x1908,
                    .pixel_type = 0x1401,
                    .data_len = 0,
                    .params = .{},
                    .backend = .{},
                    .backend_view = .{},
                    .cpu_block_start = 0,
                    .cpu_block_count = 0,
                    .dirty = false,
                };
                entry.active = true;
                self.count += 1;
                return id;
            }
        }
        return error.AtCapacity;
    }

    pub fn get(self: *Self, id: TextureId) ?*Texture {
        if (!self.isValid(id)) return null;
        return &self.entries[id.index].texture;
    }

    pub fn getConst(self: *const Self, id: TextureId) ?*const Texture {
        if (!self.isValidConst(id)) return null;
        return &self.entries[id.index].texture;
    }

    pub fn free(self: *Self, id: TextureId) bool {
        if (!self.isValid(id)) return false;
        var entry = &self.entries[id.index];

        // Free CPU pool blocks
        if (entry.texture.cpu_block_count > 0) {
            self.cpu_pool.free(.{
                .block_start = entry.texture.cpu_block_start,
                .block_count = entry.texture.cpu_block_count,
                .size = entry.texture.data_len,
            });
        }

        // Destroy backend resources if valid
        if (entry.texture.backend_view.id != 0) {
            sg.destroyView(entry.texture.backend_view);
        }
        if (entry.texture.backend.id != 0) {
            sg.destroyImage(entry.texture.backend);
        }

        entry.active = false;
        entry.generation +%= 1;
        entry.texture.cpu_block_start = 0;
        entry.texture.cpu_block_count = 0;
        entry.texture.data_len = 0;
        entry.texture.backend = .{};
        entry.texture.backend_view = .{};
        entry.texture.dirty = false;
        self.count -= 1;
        return true;
    }

    pub fn isValid(self: *Self, id: TextureId) bool {
        if (id.index >= MaxTextures) return false;
        const entry = &self.entries[id.index];
        return entry.active and entry.generation == id.generation;
    }

    pub fn isValidConst(self: *const Self, id: TextureId) bool {
        if (id.index >= MaxTextures) return false;
        const entry = &self.entries[id.index];
        return entry.active and entry.generation == id.generation;
    }

    /// Upload pixel data to CPU pool for later GPU upload
    pub fn texImage2D(
        self: *Self,
        id: TextureId,
        target: TextureTarget,
        width: u32,
        height: u32,
        format: TextureFormat,
        internal_format: u32,
        pixel_type: u32,
        data: ?[]const u8,
    ) !void {
        const tex = self.get(id) orelse return error.InvalidHandle;

        // Calculate required size based on format
        const bytes_per_pixel: u32 = switch (format) {
            .rgba => 4,
            .rgb => 3,
            .luminance_alpha => 2,
            .luminance, .alpha => 1,
        };
        const data_size = width * height * bytes_per_pixel;

        // Free existing CPU data if dimensions/format changed
        if (tex.cpu_block_count > 0 and
            (tex.width != width or tex.height != height or tex.format != format))
        {
            self.cpu_pool.free(.{
                .block_start = tex.cpu_block_start,
                .block_count = tex.cpu_block_count,
                .size = tex.data_len,
            });
            tex.cpu_block_start = 0;
            tex.cpu_block_count = 0;
            tex.data_len = 0;
        }

        // Update texture metadata
        tex.target = target;
        tex.width = width;
        tex.height = height;
        tex.format = format;
        tex.internal_format = internal_format;
        tex.pixel_type = pixel_type;

        // Allocate CPU storage and copy data if provided
        if (data) |pixels| {
            if (pixels.len < data_size) return error.InsufficientData;

            // Allocate new CPU block if needed
            if (tex.cpu_block_count == 0 or tex.data_len < data_size) {
                if (tex.cpu_block_count > 0) {
                    self.cpu_pool.free(.{
                        .block_start = tex.cpu_block_start,
                        .block_count = tex.cpu_block_count,
                        .size = tex.data_len,
                    });
                }
                const cpu_slice = try self.cpu_pool.alloc(data_size);
                tex.cpu_block_start = cpu_slice.block_start;
                tex.cpu_block_count = cpu_slice.block_count;
            }

            tex.data_len = data_size;

            // Copy pixel data to CPU pool
            const dst = self.cpu_pool.slice(.{
                .block_start = tex.cpu_block_start,
                .block_count = tex.cpu_block_count,
                .size = data_size,
            });
            @memcpy(dst[0..data_size], pixels[0..data_size]);
            tex.dirty = true;
        } else {
            // No data provided - just update dimensions (reserve space)
            if (data_size > 0 and tex.cpu_block_count == 0) {
                const cpu_slice = try self.cpu_pool.alloc(data_size);
                tex.cpu_block_start = cpu_slice.block_start;
                tex.cpu_block_count = cpu_slice.block_count;
                tex.data_len = data_size;
                // Zero-fill the allocated space
                const dst = self.cpu_pool.slice(.{
                    .block_start = tex.cpu_block_start,
                    .block_count = tex.cpu_block_count,
                    .size = data_size,
                });
                @memset(dst, 0);
                tex.dirty = true;
            }
        }
    }

    /// Get CPU pixel data for a texture
    pub fn getPixelData(self: *Self, id: TextureId) ?[]const u8 {
        const tex = self.get(id) orelse return null;
        if (tex.cpu_block_count == 0 or tex.data_len == 0) return null;
        return self.cpu_pool.constSlice(.{
            .block_start = tex.cpu_block_start,
            .block_count = tex.cpu_block_count,
            .size = tex.data_len,
        });
    }
};

// =============================================================================
// Texture State (binding tracking)
// =============================================================================

pub const TextureState = struct {
    active_unit: u32 = 0,
    bound_2d: [MaxTextureUnits]?TextureId = [_]?TextureId{null} ** MaxTextureUnits,
    bound_cube: [MaxTextureUnits]?TextureId = [_]?TextureId{null} ** MaxTextureUnits,

    const Self = @This();

    pub fn setActiveUnit(self: *Self, unit: u32) !void {
        if (unit >= MaxTextureUnits) return error.InvalidUnit;
        self.active_unit = unit;
    }

    pub fn bindTexture(self: *Self, table: *TextureTable, target: TextureTarget, id: ?TextureId) !void {
        if (id) |tex_id| {
            if (!table.isValid(tex_id)) return error.InvalidHandle;
        }

        switch (target) {
            .texture_2d => self.bound_2d[self.active_unit] = id,
            .texture_cube_map => self.bound_cube[self.active_unit] = id,
        }
    }

    pub fn getBound(self: *const Self, target: TextureTarget) ?TextureId {
        return switch (target) {
            .texture_2d => self.bound_2d[self.active_unit],
            .texture_cube_map => self.bound_cube[self.active_unit],
        };
    }

    pub fn getBoundAtUnit(self: *const Self, unit: u32, target: TextureTarget) ?TextureId {
        if (unit >= MaxTextureUnits) return null;
        return switch (target) {
            .texture_2d => self.bound_2d[unit],
            .texture_cube_map => self.bound_cube[unit],
        };
    }

    pub fn onTextureDeleted(self: *Self, id: TextureId) void {
        for (&self.bound_2d) |*bound| {
            if (bound.* != null and bound.*.?.index == id.index and bound.*.?.generation == id.generation) {
                bound.* = null;
            }
        }
        for (&self.bound_cube) |*bound| {
            if (bound.* != null and bound.*.?.index == id.index and bound.*.?.generation == id.generation) {
                bound.* = null;
            }
        }
    }

    pub fn reset(self: *Self) void {
        self.active_unit = 0;
        self.bound_2d = [_]?TextureId{null} ** MaxTextureUnits;
        self.bound_cube = [_]?TextureId{null} ** MaxTextureUnits;
    }
};

// =============================================================================
// Texture Manager (combines table + state)
// =============================================================================

pub const TextureManager = struct {
    textures: TextureTable,
    state: TextureState,

    const Self = @This();

    pub fn init() Self {
        return .{
            .textures = TextureTable.init(),
            .state = TextureState{},
        };
    }

    pub fn reset(self: *Self) void {
        self.state.reset();
        self.textures.reset();
    }

    pub fn createTexture(self: *Self) !TextureId {
        return self.textures.alloc();
    }

    pub fn deleteTexture(self: *Self, id: TextureId) bool {
        self.state.onTextureDeleted(id);
        return self.textures.free(id);
    }

    pub fn activeTexture(self: *Self, unit: u32) !void {
        try self.state.setActiveUnit(unit);
    }

    pub fn bindTexture(self: *Self, target: TextureTarget, id: ?TextureId) !void {
        try self.state.bindTexture(&self.textures, target, id);
    }

    pub fn texImage2D(
        self: *Self,
        target: TextureTarget,
        width: u32,
        height: u32,
        format: TextureFormat,
        internal_format: u32,
        pixel_type: u32,
        data: ?[]const u8,
    ) !void {
        const id = self.state.getBound(target) orelse return error.NoTextureBound;
        try self.textures.texImage2D(id, target, width, height, format, internal_format, pixel_type, data);
    }

    pub fn texParameteri(self: *Self, target: TextureTarget, pname: u32, param: u32) !void {
        const id = self.state.getBound(target) orelse return error.NoTextureBound;
        const tex = self.textures.get(id) orelse return error.InvalidHandle;

        const GL_TEXTURE_MIN_FILTER: u32 = 0x2801;
        const GL_TEXTURE_MAG_FILTER: u32 = 0x2800;
        const GL_TEXTURE_WRAP_S: u32 = 0x2802;
        const GL_TEXTURE_WRAP_T: u32 = 0x2803;

        switch (pname) {
            GL_TEXTURE_MIN_FILTER => {
                tex.params.min_filter = std.meta.intToEnum(TextureFilter, param) catch return error.InvalidEnum;
            },
            GL_TEXTURE_MAG_FILTER => {
                tex.params.mag_filter = std.meta.intToEnum(TextureFilter, param) catch return error.InvalidEnum;
            },
            GL_TEXTURE_WRAP_S => {
                tex.params.wrap_s = std.meta.intToEnum(TextureWrap, param) catch return error.InvalidEnum;
            },
            GL_TEXTURE_WRAP_T => {
                tex.params.wrap_t = std.meta.intToEnum(TextureWrap, param) catch return error.InvalidEnum;
            },
            else => {}, // Ignore unknown parameters
        }
    }

    pub fn getTexture(self: *Self, id: TextureId) ?*Texture {
        return self.textures.get(id);
    }

    pub fn isValid(self: *Self, id: TextureId) bool {
        return self.textures.isValid(id);
    }
};

// =============================================================================
// Global instance
// =============================================================================

var g_texture_manager: TextureManager = TextureManager.init();

pub fn globalTextureManager() *TextureManager {
    return &g_texture_manager;
}

// =============================================================================
// Tests
// =============================================================================

test "TextureTable alloc and free" {
    var table = TextureTable.init();
    defer table.reset();

    const id1 = try table.alloc();
    try testing.expect(table.isValid(id1));
    try testing.expectEqual(@as(u16, 1), table.count);

    const id2 = try table.alloc();
    try testing.expect(table.isValid(id2));
    try testing.expectEqual(@as(u16, 2), table.count);

    try testing.expect(table.free(id1));
    try testing.expect(!table.isValid(id1));
    try testing.expectEqual(@as(u16, 1), table.count);

    // id1's slot should be reused with new generation
    const id3 = try table.alloc();
    try testing.expectEqual(id1.index, id3.index);
    try testing.expect(id3.generation != id1.generation);
}

test "TextureTable generation check prevents use-after-free" {
    var table = TextureTable.init();
    defer table.reset();

    const id = try table.alloc();
    try testing.expect(table.isValid(id));

    try testing.expect(table.free(id));
    try testing.expect(!table.isValid(id));

    // Reallocate same slot
    const new_id = try table.alloc();
    try testing.expectEqual(id.index, new_id.index);

    // Old id should still be invalid
    try testing.expect(!table.isValid(id));
    try testing.expect(table.isValid(new_id));
}

test "TextureTable texImage2D stores pixel data" {
    var table = TextureTable.init();
    defer table.reset();

    const id = try table.alloc();
    const pixels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 }; // 2 RGBA pixels

    try table.texImage2D(id, .texture_2d, 2, 1, .rgba, 0x1908, 0x1401, pixels[0..]);

    const tex = table.get(id).?;
    try testing.expectEqual(@as(u32, 2), tex.width);
    try testing.expectEqual(@as(u32, 1), tex.height);
    try testing.expectEqual(TextureFormat.rgba, tex.format);
    try testing.expectEqual(@as(u32, 8), tex.data_len);
    try testing.expect(tex.dirty);

    const data = table.getPixelData(id).?;
    try testing.expectEqualSlices(u8, pixels[0..], data);
}

test "CpuTexturePool alloc and free" {
    // Use global pool to avoid 64 MB stack allocation
    var pool = &g_cpu_pool;
    pool.reset();

    const slice1 = try pool.alloc(1024);
    try testing.expectEqual(@as(u16, 0), slice1.block_start);
    try testing.expectEqual(@as(u16, 1), slice1.block_count);

    const slice2 = try pool.alloc(32 * 1024); // 2 blocks
    try testing.expectEqual(@as(u16, 1), slice2.block_start);
    try testing.expectEqual(@as(u16, 2), slice2.block_count);

    pool.free(slice1);

    // First block should be reused
    const slice3 = try pool.alloc(100);
    try testing.expectEqual(@as(u16, 0), slice3.block_start);

    pool.reset();
}

test "TextureState binding" {
    var table = TextureTable.init();
    defer table.reset();
    var state = TextureState{};

    const id = try table.alloc();

    try state.setActiveUnit(0);
    try state.bindTexture(&table, .texture_2d, id);
    try testing.expectEqual(id, state.getBound(.texture_2d).?);

    try state.setActiveUnit(1);
    try testing.expectEqual(@as(?TextureId, null), state.getBound(.texture_2d));

    try state.bindTexture(&table, .texture_2d, id);
    try testing.expectEqual(id, state.getBoundAtUnit(1, .texture_2d).?);
}

test "TextureManager full workflow" {
    var mgr = TextureManager.init();
    defer mgr.reset();

    const id = try mgr.createTexture();
    try testing.expect(mgr.isValid(id));

    try mgr.activeTexture(0);
    try mgr.bindTexture(.texture_2d, id);

    const pixels = [_]u8{ 255, 128, 64, 255 }; // 1 RGBA pixel
    try mgr.texImage2D(.texture_2d, 1, 1, .rgba, 0x1908, 0x1401, pixels[0..]);

    try mgr.texParameteri(.texture_2d, 0x2801, 0x2600); // MIN_FILTER = NEAREST

    const tex = mgr.getTexture(id).?;
    try testing.expectEqual(TextureFilter.nearest, tex.params.min_filter);

    try testing.expect(mgr.deleteTexture(id));
    try testing.expect(!mgr.isValid(id));
}
