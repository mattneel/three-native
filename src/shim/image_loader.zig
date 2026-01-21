//! Image loading via Zignal
//!
//! Provides PNG/JPEG decoding for texture loading.

const std = @import("std");
const testing = std.testing;
const zignal = @import("zignal");

pub const MaxImageFileSize: usize = 64 * 1024 * 1024; // 64 MB max file size

pub const ImageData = struct {
    width: u32,
    height: u32,
    channels: u32,
    pixels: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ImageData) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn bytesPerPixel(self: *const ImageData) u32 {
        return self.channels;
    }

    pub fn dataSize(self: *const ImageData) usize {
        return @as(usize, self.width) * @as(usize, self.height) * @as(usize, self.channels);
    }
};

pub const ImageError = error{
    FileNotFound,
    ReadError,
    FileTooLarge,
    DecodeError,
    OutOfMemory,
    InvalidPath,
};

/// Load an image from a file path
/// Returns RGBA pixel data (4 channels)
/// Note: GIF files are transparently loaded as PNG (same path with .png extension)
pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) ImageError!ImageData {
    // Substitute .gif extension with .png (GIF not supported, load pre-converted PNG)
    const actual_path = substituteGifExtension(allocator, path) catch return ImageError.OutOfMemory;
    defer if (actual_path.ptr != path.ptr) allocator.free(actual_path);

    // Read file into memory
    const file_data = std.fs.cwd().readFileAlloc(allocator, actual_path, MaxImageFileSize) catch |err| {
        return switch (err) {
            error.FileNotFound => ImageError.FileNotFound,
            error.FileTooBig => ImageError.FileTooLarge,
            else => ImageError.ReadError,
        };
    };
    defer allocator.free(file_data);

    return loadFromMemory(allocator, file_data);
}

/// Substitute .gif extension with .png for transparent GIF->PNG loading
fn substituteGifExtension(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len >= 4 and std.mem.eql(u8, path[path.len - 4 ..], ".gif")) {
        const new_path = try allocator.alloc(u8, path.len);
        @memcpy(new_path[0 .. path.len - 4], path[0 .. path.len - 4]);
        @memcpy(new_path[path.len - 4 ..], ".png");
        return new_path;
    }
    return path;
}

/// Load an image from memory buffer
/// Returns RGBA pixel data (4 channels)
/// Currently supports PNG format only.
pub fn loadFromMemory(allocator: std.mem.Allocator, data: []const u8) ImageError!ImageData {
    // Try PNG decoding
    return tryDecodePng(allocator, data);
}

fn tryDecodePng(allocator: std.mem.Allocator, data: []const u8) ImageError!ImageData {
    // Decode PNG
    var png_image = zignal.png.decode(allocator, data) catch {
        return ImageError.DecodeError;
    };
    defer png_image.deinit(allocator);

    // Convert to native image format
    const native = zignal.png.toNativeImage(allocator, png_image) catch {
        return ImageError.DecodeError;
    };

    // Convert to RGBA based on source format
    return switch (native) {
        .grayscale => |img| blk: {
            defer {
                var mutable_img = img;
                mutable_img.deinit(allocator);
            }
            break :blk convertGrayscaleToRgba(allocator, img);
        },
        .rgb => |img| blk: {
            defer {
                var mutable_img = img;
                mutable_img.deinit(allocator);
            }
            break :blk convertRgbToRgba(allocator, img);
        },
        .rgba => |img| blk: {
            defer {
                var mutable_img = img;
                mutable_img.deinit(allocator);
            }
            break :blk convertRgbaToOutput(allocator, img);
        },
    };
}

fn convertGrayscaleToRgba(allocator: std.mem.Allocator, img: zignal.Image(u8)) ImageError!ImageData {
    const w: u32 = @intCast(img.cols);
    const h: u32 = @intCast(img.rows);
    const size = @as(usize, w) * @as(usize, h) * 4;

    const pixels = allocator.alloc(u8, size) catch return ImageError.OutOfMemory;

    var dst_idx: usize = 0;
    for (0..h) |y| {
        for (0..w) |x| {
            const gray = img.at(y, x).*;
            pixels[dst_idx + 0] = gray;
            pixels[dst_idx + 1] = gray;
            pixels[dst_idx + 2] = gray;
            pixels[dst_idx + 3] = 255;
            dst_idx += 4;
        }
    }

    return ImageData{
        .width = w,
        .height = h,
        .channels = 4,
        .pixels = pixels,
        .allocator = allocator,
    };
}

fn convertRgbToRgba(allocator: std.mem.Allocator, img: zignal.Image(zignal.Rgb)) ImageError!ImageData {
    const w: u32 = @intCast(img.cols);
    const h: u32 = @intCast(img.rows);
    const size = @as(usize, w) * @as(usize, h) * 4;

    const pixels = allocator.alloc(u8, size) catch return ImageError.OutOfMemory;

    var dst_idx: usize = 0;
    for (0..h) |y| {
        for (0..w) |x| {
            const pixel = img.at(y, x).*;
            pixels[dst_idx + 0] = pixel.r;
            pixels[dst_idx + 1] = pixel.g;
            pixels[dst_idx + 2] = pixel.b;
            pixels[dst_idx + 3] = 255;
            dst_idx += 4;
        }
    }

    return ImageData{
        .width = w,
        .height = h,
        .channels = 4,
        .pixels = pixels,
        .allocator = allocator,
    };
}

fn convertRgbaToOutput(allocator: std.mem.Allocator, img: zignal.Image(zignal.Rgba)) ImageError!ImageData {
    const w: u32 = @intCast(img.cols);
    const h: u32 = @intCast(img.rows);
    const size = @as(usize, w) * @as(usize, h) * 4;

    const pixels = allocator.alloc(u8, size) catch return ImageError.OutOfMemory;

    var dst_idx: usize = 0;
    for (0..h) |y| {
        for (0..w) |x| {
            const pixel = img.at(y, x).*;
            pixels[dst_idx + 0] = pixel.r;
            pixels[dst_idx + 1] = pixel.g;
            pixels[dst_idx + 2] = pixel.b;
            pixels[dst_idx + 3] = pixel.a;
            dst_idx += 4;
        }
    }

    return ImageData{
        .width = w,
        .height = h,
        .channels = 4,
        .pixels = pixels,
        .allocator = allocator,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "ImageData size calculation" {
    var img = ImageData{
        .width = 16,
        .height = 8,
        .channels = 4,
        .pixels = undefined,
        .allocator = testing.allocator,
    };
    try testing.expectEqual(@as(usize, 16 * 8 * 4), img.dataSize());
    try testing.expectEqual(@as(u32, 4), img.bytesPerPixel());
}

test "loadFromMemory with invalid data returns DecodeError" {
    const invalid_data = [_]u8{ 0, 1, 2, 3, 4, 5 };
    const result = loadFromMemory(testing.allocator, &invalid_data);
    try testing.expectError(ImageError.DecodeError, result);
}

test "loadFromFile with missing file returns FileNotFound" {
    const result = loadFromFile(testing.allocator, "nonexistent_file_12345.png");
    try testing.expectError(ImageError.FileNotFound, result);
}
