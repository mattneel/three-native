//! Direct GL uniform calls for types not supported by Sokol (mat2, mat3).
//!
//! Sokol's uniform system only supports MAT4, not MAT2/MAT3. For these types,
//! we bypass Sokol and call GL directly. This module provides the necessary
//! GL function bindings.

const std = @import("std");
const builtin = @import("builtin");

// GL types
pub const GLint = c_int;
pub const GLuint = c_uint;
pub const GLsizei = c_int;
pub const GLfloat = f32;
pub const GLboolean = u8;
pub const GLchar = u8;

pub const GL_FALSE: GLboolean = 0;
pub const GL_TRUE: GLboolean = 1;

// GL function pointers - loaded at runtime from the GL library
var glGetUniformLocation_ptr: ?*const fn (GLuint, [*c]const GLchar) callconv(.c) GLint = null;
var glUniformMatrix2fv_ptr: ?*const fn (GLint, GLsizei, GLboolean, [*c]const GLfloat) callconv(.c) void = null;
var glUniformMatrix3fv_ptr: ?*const fn (GLint, GLsizei, GLboolean, [*c]const GLfloat) callconv(.c) void = null;
var glUseProgram_ptr: ?*const fn (GLuint) callconv(.c) void = null;
var glGetIntegerv_ptr: ?*const fn (c_uint, [*c]GLint) callconv(.c) void = null;
var glActiveTexture_ptr: ?*const fn (c_uint) callconv(.c) void = null;
var glBindTexture_ptr: ?*const fn (c_uint, GLuint) callconv(.c) void = null;
var glBindSampler_ptr: ?*const fn (GLuint, GLuint) callconv(.c) void = null;
var glUniform1i_ptr: ?*const fn (GLint, GLint) callconv(.c) void = null;
var glUniform1f_ptr: ?*const fn (GLint, GLfloat) callconv(.c) void = null;
var glUniform3fv_ptr: ?*const fn (GLint, GLsizei, [*c]const GLfloat) callconv(.c) void = null;
var glGetError_ptr: ?*const fn () callconv(.c) c_uint = null;

const GL_CURRENT_PROGRAM: c_uint = 0x8B8D;
pub const GL_NO_ERROR: c_uint = 0;
pub const GL_TEXTURE0: c_uint = 0x84C0;
pub const GL_TEXTURE_2D: c_uint = 0x0DE1;
pub const GL_TEXTURE_CUBE_MAP: c_uint = 0x8513;

var initialized = false;

// Platform-specific dynamic loading
const is_windows = builtin.os.tag == .windows;

const windows = if (is_windows) @cImport({
    @cInclude("windows.h");
}) else struct {};

const posix = if (!is_windows) @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("dlfcn.h");
}) else struct {};

fn getProcAddress(comptime name: [:0]const u8) ?*anyopaque {
    if (is_windows) {
        // On Windows, use wglGetProcAddress for GL extensions, GetProcAddress for core GL
        const wglGetProcAddress_ptr = @as(?*const fn ([*c]const u8) callconv(.c) ?*anyopaque, @ptrCast(windows.GetProcAddress(windows.GetModuleHandleA("opengl32.dll"), "wglGetProcAddress")));
        if (wglGetProcAddress_ptr) |wglGetProcAddress| {
            const addr = wglGetProcAddress(name.ptr);
            if (addr != null) return addr;
        }
        // Fall back to GetProcAddress for core GL 1.1 functions
        return windows.GetProcAddress(windows.GetModuleHandleA("opengl32.dll"), name.ptr);
    } else {
        const handle = posix.dlopen(null, posix.RTLD_LAZY);
        if (handle == null) return null;
        return posix.dlsym(handle, name.ptr);
    }
}

/// Initialize GL function pointers. Call this after GL context is created.
pub fn init() void {
    if (initialized) return;

    glGetUniformLocation_ptr = @ptrCast(getProcAddress("glGetUniformLocation"));
    glUniformMatrix2fv_ptr = @ptrCast(getProcAddress("glUniformMatrix2fv"));
    glUniformMatrix3fv_ptr = @ptrCast(getProcAddress("glUniformMatrix3fv"));
    glUseProgram_ptr = @ptrCast(getProcAddress("glUseProgram"));
    glGetIntegerv_ptr = @ptrCast(getProcAddress("glGetIntegerv"));
    glActiveTexture_ptr = @ptrCast(getProcAddress("glActiveTexture"));
    glBindTexture_ptr = @ptrCast(getProcAddress("glBindTexture"));
    glBindSampler_ptr = @ptrCast(getProcAddress("glBindSampler"));
    glUniform1i_ptr = @ptrCast(getProcAddress("glUniform1i"));
    glUniform1f_ptr = @ptrCast(getProcAddress("glUniform1f"));
    glUniform3fv_ptr = @ptrCast(getProcAddress("glUniform3fv"));
    glGetError_ptr = @ptrCast(getProcAddress("glGetError"));

    if (glGetUniformLocation_ptr != null and glUniformMatrix3fv_ptr != null) {
        initialized = true;
        std.log.info("gl_uniforms: initialized direct GL calls", .{});
    } else {
        std.log.err("gl_uniforms: failed to load GL functions", .{});
    }
}

/// Check if direct GL calls are available
pub fn isAvailable() bool {
    return initialized;
}

/// Get the location of a uniform in a GL program
pub fn getUniformLocation(program: GLuint, name: [*:0]const u8) GLint {
    if (glGetUniformLocation_ptr) |func| {
        return func(program, name);
    }
    return -1;
}

/// Set a mat2 uniform (4 floats, column-major)
pub fn uniformMatrix2fv(location: GLint, count: GLsizei, transpose: bool, value: [*]const GLfloat) void {
    if (glUniformMatrix2fv_ptr) |func| {
        func(location, count, if (transpose) GL_TRUE else GL_FALSE, value);
    }
}

/// Set a mat3 uniform (9 floats, column-major)
pub fn uniformMatrix3fv(location: GLint, count: GLsizei, transpose: bool, value: [*]const GLfloat) void {
    if (glUniformMatrix3fv_ptr) |func| {
        func(location, count, if (transpose) GL_TRUE else GL_FALSE, value);
    }
}

/// Get the currently bound program
pub fn getCurrentProgram() GLuint {
    if (glGetIntegerv_ptr) |func| {
        var prog: GLint = 0;
        func(GL_CURRENT_PROGRAM, &prog);
        return @intCast(prog);
    }
    return 0;
}

/// Use a specific program
pub fn useProgram(program: GLuint) void {
    if (glUseProgram_ptr) |func| {
        func(program);
    }
}

/// Activate a texture unit (unit 0 = GL_TEXTURE0, etc.)
pub fn activeTexture(unit: u32) void {
    if (glActiveTexture_ptr) |func| {
        func(GL_TEXTURE0 + unit);
    }
}

/// Bind a texture to the currently active texture unit
pub fn bindTexture(target: c_uint, texture: GLuint) void {
    if (glBindTexture_ptr) |func| {
        func(target, texture);
    }
}

/// Bind a sampler to a texture unit
pub fn bindSampler(unit: GLuint, sampler: GLuint) void {
    if (glBindSampler_ptr) |func| {
        func(unit, sampler);
    }
}

/// Set an integer uniform (used for sampler uniforms)
pub fn uniform1i(location: GLint, value: GLint) void {
    if (glUniform1i_ptr) |func| {
        func(location, value);
    }
}

/// Set a float uniform
pub fn uniform1f(location: GLint, value: GLfloat) void {
    if (glUniform1f_ptr) |func| {
        func(location, value);
    }
}

/// Set a vec3 uniform
pub fn uniform3fv(location: GLint, count: GLsizei, value: [*]const GLfloat) void {
    if (glUniform3fv_ptr) |func| {
        func(location, count, value);
    }
}

/// Get the last GL error
pub fn getError() c_uint {
    if (glGetError_ptr) |func| {
        return func();
    }
    return GL_NO_ERROR;
}
