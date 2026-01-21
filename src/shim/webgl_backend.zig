//! Sokol backend adapter for WebGL buffer and texture operations.

const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const webgl = @import("webgl.zig");
const webgl_texture = @import("webgl_texture.zig");

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

// =============================================================================
// Texture Backend
// =============================================================================

pub const TextureBackendError = error{
    InvalidDimensions,
    CreateFailed,
    ViewCreateFailed,
};

/// Create a Sokol image for a texture
const log = std.log.scoped(.webgl_backend);

pub fn createTextureImage(
    width: u32,
    height: u32,
    format: webgl_texture.TextureFormat,
    params: webgl_texture.TextureParams,
    pixels: ?[]const u8,
) TextureBackendError!sg.Image {
    if (width == 0 or height == 0) return TextureBackendError.InvalidDimensions;

    const pixel_format = mapTextureFormat(format);
    const min_filter = mapFilter(params.min_filter);
    const mag_filter = mapMagFilter(params.mag_filter);
    const wrap_u = mapWrap(params.wrap_s);
    const wrap_v = mapWrap(params.wrap_t);

    log.info("createTextureImage: {d}x{d} format={s} pixel_format={s} min={s} mag={s}", .{
        width,
        height,
        @tagName(format),
        @tagName(pixel_format),
        @tagName(min_filter),
        @tagName(mag_filter),
    });

    const is_immutable = pixels != null;
    var desc = sg.ImageDesc{
        .width = @intCast(width),
        .height = @intCast(height),
        .pixel_format = pixel_format,
        .num_mipmaps = 1, // Explicitly set to 1 for single mip level
        .usage = .{ .immutable = is_immutable },
    };

    // Note: wrap_u/wrap_v not used currently but kept for future use
    _ = wrap_u;
    _ = wrap_v;

    // If we have initial pixel data and texture is immutable, provide it
    if (is_immutable) {
        if (pixels) |px| {
            desc.data.mip_levels[0] = .{
                .ptr = px.ptr,
                .size = px.len,
            };
        }
    }

    const img = sg.makeImage(desc);
    const state = sg.queryImageState(img);
    log.info("createTextureImage: makeImage returned id={d} state={s}", .{ img.id, @tagName(state) });
    if (img.id == 0 or state != .VALID) {
        return TextureBackendError.CreateFailed;
    }

    return img;
}

/// Create a texture view for binding
pub fn createTextureView(image: sg.Image) TextureBackendError!sg.View {
    if (image.id == 0) return TextureBackendError.CreateFailed;

    const view = sg.makeView(.{
        .texture = .{ .image = image },
    });

    log.info("createTextureView: for image_id={d} returned view_id={d}", .{ image.id, view.id });

    if (view.id == 0) {
        return TextureBackendError.ViewCreateFailed;
    }

    return view;
}

/// Create a sampler with the given parameters
pub fn createTextureSampler(params: webgl_texture.TextureParams) sg.Sampler {
    return sg.makeSampler(.{
        .min_filter = mapFilter(params.min_filter),
        .mag_filter = mapMagFilter(params.mag_filter),
        .wrap_u = mapWrap(params.wrap_s),
        .wrap_v = mapWrap(params.wrap_t),
    });
}

/// Destroy a texture image
pub fn destroyTextureImage(image: sg.Image) void {
    if (image.id != 0) {
        sg.destroyImage(image);
    }
}

/// Destroy a texture view
pub fn destroyTextureView(view: sg.View) void {
    if (view.id != 0) {
        sg.destroyView(view);
    }
}

/// Destroy a sampler
pub fn destroyTextureSampler(sampler: sg.Sampler) void {
    if (sampler.id != 0) {
        sg.destroySampler(sampler);
    }
}

fn mapTextureFormat(format: webgl_texture.TextureFormat) sg.PixelFormat {
    return switch (format) {
        .rgba => .RGBA8,
        .rgb => .RGBA8, // Sokol doesn't have RGB8, use RGBA8
        .luminance_alpha => .RG8,
        .luminance => .R8,
        .alpha => .R8,
    };
}

fn mapFilter(filter: webgl_texture.TextureFilter) sg.Filter {
    return switch (filter) {
        .nearest => .NEAREST,
        .linear => .LINEAR,
        .nearest_mipmap_nearest => .NEAREST,
        .linear_mipmap_nearest => .LINEAR,
        .nearest_mipmap_linear => .NEAREST,
        .linear_mipmap_linear => .LINEAR,
    };
}

fn mapMagFilter(filter: webgl_texture.TextureFilter) sg.Filter {
    // Mag filter doesn't support mipmap modes
    return switch (filter) {
        .nearest, .nearest_mipmap_nearest, .nearest_mipmap_linear => .NEAREST,
        .linear, .linear_mipmap_nearest, .linear_mipmap_linear => .LINEAR,
    };
}

fn mapWrap(wrap: webgl_texture.TextureWrap) sg.Wrap {
    return switch (wrap) {
        .repeat => .REPEAT,
        .clamp_to_edge => .CLAMP_TO_EDGE,
        .mirrored_repeat => .MIRRORED_REPEAT,
    };
}
