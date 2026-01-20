//! Pure Zig runtime bindings for mquickjs.
//!
//! The mquickjs engine stays in C, but all stdlib bindings and runtime glue
//! are implemented in Zig and provided through the stdlib table.

const std = @import("std");
const sg = @import("sokol").gfx;
const webgl_state = @import("../shim/webgl_state.zig");
const webgl = @import("../shim/webgl.zig");
const webgl_shader = @import("../shim/webgl_shader.zig");
const webgl_program = @import("../shim/webgl_program.zig");
const webgl_draw = @import("../shim/webgl_draw.zig");

const c = @cImport({
    @cInclude("mquickjs_bindings.h");
});

extern const js_stdlib: c.JSSTDLibraryDef;

pub const SharedState = struct {
    clear_color: [3]f32 = .{ 0.0, 0.0, 0.0 },
    time_ms: f64 = 0,
};

const MaxTimers = 16;
const MaxRaf = 16;

const Timer = struct {
    allocated: bool = false,
    timeout_ms: f64 = 0,
    func: c.JSGCRef = .{ .val = c.JS_UNDEFINED, .prev = null },
};

const RafEntry = struct {
    active: bool = false,
    id: i32 = 0,
    func: c.JSGCRef = .{ .val = c.JS_UNDEFINED, .prev = null },
};

pub const Runtime = struct {
    ctx: *c.JSContext,
    mem_buf: []u8,
    allocator: std.mem.Allocator,
    shared: SharedState,
    timers: [MaxTimers]Timer,
    raf: [MaxRaf]RafEntry,
    next_raf_id: i32,
    dom_installed: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, mem_size: usize) !Self {
        const mem_buf = try allocator.alloc(u8, mem_size);
        errdefer allocator.free(mem_buf);

        g_js_mutex.lock();
        defer g_js_mutex.unlock();
        const ctx = c.JS_NewContext(mem_buf.ptr, mem_size, &js_stdlib) orelse {
            return error.ContextCreationFailed;
        };

        c.JS_SetLogFunc(ctx, logFunc);

        return .{
            .ctx = ctx,
            .mem_buf = mem_buf,
            .allocator = allocator,
            .shared = .{},
            .timers = [_]Timer{.{}} ** MaxTimers,
            .raf = [_]RafEntry{.{}} ** MaxRaf,
            .next_raf_id = 1,
            .dom_installed = false,
        };
    }

    pub fn deinit(self: *Self) void {
        if (g_runtime == self) {
            g_runtime = null;
        }
        g_js_mutex.lock();
        c.JS_FreeContext(self.ctx);
        g_js_mutex.unlock();
        self.allocator.free(self.mem_buf);
    }

    pub fn makeCurrent(self: *Self) void {
        g_js_mutex.lock();
        defer g_js_mutex.unlock();
        g_runtime = self;
        c.JS_SetContextOpaque(self.ctx, self);
        g_start_time_ms = std.time.milliTimestamp();
    }

    pub fn eval(self: *Self, code: []const u8, filename: [:0]const u8) !void {
        g_js_mutex.lock();
        defer g_js_mutex.unlock();
        const val = c.JS_Eval(self.ctx, code.ptr, code.len, filename.ptr, 0);
        if (val == c.JS_EXCEPTION) {
            dumpException(self.ctx);
            return error.EvalFailed;
        }
    }

    pub fn evalInt(self: *Self, code: []const u8, filename: [:0]const u8) !i32 {
        g_js_mutex.lock();
        defer g_js_mutex.unlock();
        const val = c.JS_Eval(self.ctx, code.ptr, code.len, filename.ptr, c.JS_EVAL_RETVAL);
        if (val == c.JS_EXCEPTION) {
            dumpException(self.ctx);
            return error.EvalFailed;
        }
        var out: i32 = 0;
        if (c.JS_ToInt32(self.ctx, &out, val) != 0) {
            return error.BadReturnType;
        }
        return out;
    }

    pub fn tick(self: *Self, timestamp_ms: f64) void {
        g_js_mutex.lock();
        defer g_js_mutex.unlock();
        self.shared.time_ms = timestamp_ms;
        self.runTimers(timestamp_ms);
        self.runRaf(timestamp_ms);
    }

    pub fn installDomStubs(self: *Self) !void {
        if (self.dom_installed) return;
        g_js_mutex.lock();
        defer g_js_mutex.unlock();
        try createDomStubs(self.ctx);
        self.dom_installed = true;
    }


    pub fn getSharedState(self: *Self) *SharedState {
        return &self.shared;
    }

    fn runTimers(self: *Self, now_ms: f64) void {
        for (&self.timers) |*timer| {
            if (!timer.allocated) continue;
            if (timer.timeout_ms > now_ms) continue;

            if (c.JS_StackCheck(self.ctx, 2) != 0) {
                dumpException(self.ctx);
                return;
            }

            c.JS_PushArg(self.ctx, timer.func.val);
            c.JS_PushArg(self.ctx, c.JS_NULL);
            const ret = c.JS_Call(self.ctx, 0);
            if (c.JS_IsException(ret) != 0) {
                dumpException(self.ctx);
            }

            c.JS_DeleteGCRef(self.ctx, &timer.func);
            timer.allocated = false;
        }
    }

    fn runRaf(self: *Self, now_ms: f64) void {
        for (&self.raf) |*entry| {
            if (!entry.active) continue;

            if (c.JS_StackCheck(self.ctx, 3) != 0) {
                dumpException(self.ctx);
                return;
            }

            const time_val = c.JS_NewFloat64(self.ctx, now_ms);
            c.JS_PushArg(self.ctx, time_val);
            c.JS_PushArg(self.ctx, entry.func.val);
            c.JS_PushArg(self.ctx, c.JS_NULL);
            const ret = c.JS_Call(self.ctx, 1);
            if (c.JS_IsException(ret) != 0) {
                dumpException(self.ctx);
            }

            c.JS_DeleteGCRef(self.ctx, &entry.func);
            entry.active = false;
        }
    }
};

// =============================================================================
// Global runtime pointer for C callbacks
// =============================================================================

var g_runtime: ?*Runtime = null;
var g_start_time_ms: i64 = 0;
var g_js_mutex: std.Thread.Mutex = .{};

const MaxTextureUnits: usize = 8;
const MaxTextures: usize = 256;
const MaxFramebuffers: usize = 64;
const MaxRenderbuffers: usize = 64;
const MaxVertexArrays: usize = 64;

const GlState = struct {
    viewport: [4]i32 = .{ 0, 0, 0, 0 },
    scissor: [4]i32 = .{ 0, 0, 0, 0 },
    clear_color: [4]f32 = .{ 0, 0, 0, 0 },
    clear_depth: f32 = 1.0,
    clear_stencil: i32 = 0,
    line_width: f32 = 1.0,
    depth_mask: bool = true,
    color_mask: [4]bool = .{ true, true, true, true },
    depth_func: u32 = GL_LESS,
    cull_face: u32 = GL_BACK,
    front_face: u32 = GL_CCW,
    blend_src: u32 = GL_ONE,
    blend_dst: u32 = GL_ZERO,
    blend_src_alpha: u32 = GL_ONE,
    blend_dst_alpha: u32 = GL_ZERO,
    blend_eq: u32 = GL_FUNC_ADD,
    blend_eq_alpha: u32 = GL_FUNC_ADD,
    active_texture_unit: u32 = 0,
    bound_textures_2d: [MaxTextureUnits]u32 = [_]u32{0} ** MaxTextureUnits,
    bound_textures_cube: [MaxTextureUnits]u32 = [_]u32{0} ** MaxTextureUnits,
    stencil_func_front: u32 = GL_ALWAYS,
    stencil_func_back: u32 = GL_ALWAYS,
    stencil_ref_front: u8 = 0,
    stencil_ref_back: u8 = 0,
    stencil_value_mask_front: u8 = 0xFF,
    stencil_value_mask_back: u8 = 0xFF,
    stencil_write_mask_front: u8 = 0xFF,
    stencil_write_mask_back: u8 = 0xFF,
    stencil_fail_front: u32 = GL_KEEP,
    stencil_zfail_front: u32 = GL_KEEP,
    stencil_zpass_front: u32 = GL_KEEP,
    stencil_fail_back: u32 = GL_KEEP,
    stencil_zfail_back: u32 = GL_KEEP,
    stencil_zpass_back: u32 = GL_KEEP,
    polygon_offset: [2]f32 = .{ 0, 0 },
    unpack_alignment: i32 = 4,
    unpack_row_length: i32 = 0,
    unpack_skip_pixels: i32 = 0,
    unpack_skip_rows: i32 = 0,
    unpack_flip_y: bool = false,
    unpack_premultiply_alpha: bool = false,
    unpack_colorspace_conversion: i32 = 0,
    enabled_depth_test: bool = false,
    enabled_stencil_test: bool = false,
    enabled_blend: bool = false,
    enabled_cull_face: bool = false,
    enabled_polygon_offset: bool = false,
    enabled_scissor_test: bool = false,
    enabled_sample_alpha_to_coverage: bool = false,
};

var g_gl_state: GlState = .{};
var g_texture_live: [MaxTextures]bool = [_]bool{false} ** MaxTextures;
var g_next_texture_id: u32 = 1;
var g_framebuffer_live: [MaxFramebuffers]bool = [_]bool{false} ** MaxFramebuffers;
var g_next_framebuffer_id: u32 = 1;
var g_bound_framebuffer: u32 = 0;
var g_renderbuffer_live: [MaxRenderbuffers]bool = [_]bool{false} ** MaxRenderbuffers;
var g_next_renderbuffer_id: u32 = 1;
var g_bound_renderbuffer: u32 = 0;
var g_vao_live: [MaxVertexArrays]bool = [_]bool{false} ** MaxVertexArrays;
var g_next_vao_id: u32 = 1;
var g_bound_vao: u32 = 0;

fn getRuntime(ctx: *c.JSContext) ?*Runtime {
    const ctx_opaque = c.JS_GetContextOpaque(ctx);
    if (ctx_opaque != null) {
        return @ptrCast(@alignCast(ctx_opaque));
    }
    return g_runtime;
}

fn clampU8(value: i32) u8 {
    if (value < 0) return 0;
    if (value > 255) return 255;
    return @intCast(value);
}

fn jsArray2(ctx: *c.JSContext, a: i32, b: i32) c.JSValue {
    const arr = c.JS_NewArray(ctx, 2);
    _ = c.JS_SetPropertyUint32(ctx, arr, 0, c.JS_NewInt32(ctx, a));
    _ = c.JS_SetPropertyUint32(ctx, arr, 1, c.JS_NewInt32(ctx, b));
    return arr;
}

fn jsArray4(ctx: *c.JSContext, a: i32, b: i32, c_val: i32, d: i32) c.JSValue {
    const arr = c.JS_NewArray(ctx, 4);
    _ = c.JS_SetPropertyUint32(ctx, arr, 0, c.JS_NewInt32(ctx, a));
    _ = c.JS_SetPropertyUint32(ctx, arr, 1, c.JS_NewInt32(ctx, b));
    _ = c.JS_SetPropertyUint32(ctx, arr, 2, c.JS_NewInt32(ctx, c_val));
    _ = c.JS_SetPropertyUint32(ctx, arr, 3, c.JS_NewInt32(ctx, d));
    return arr;
}

fn dumpException(ctx: *c.JSContext) void {
    const obj = c.JS_GetException(ctx);
    c.JS_PrintValueF(ctx, obj, c.JS_DUMP_LONG);
    std.debug.print("\n", .{});
}

fn throwTypeError(ctx: *c.JSContext, msg: [:0]const u8) c.JSValue {
    return c.JS_Throw(ctx, c.JS_NewString(ctx, msg.ptr));
}

fn throwInternalError(ctx: *c.JSContext, msg: [:0]const u8) c.JSValue {
    return c.JS_Throw(ctx, c.JS_NewString(ctx, msg.ptr));
}

fn createDomStubs(ctx: *c.JSContext) !void {
    const global = c.JS_GetGlobalObject(ctx);

    const document = c.JS_NewObject(ctx);
    const body = c.JS_NewObject(ctx);

    const noop = c.JS_GetPropertyStr(ctx, global, "__dom_noop");
    _ = c.JS_SetPropertyStr(ctx, body, "appendChild", noop);
    _ = c.JS_SetPropertyStr(ctx, document, "body", body);

    const create_elem = c.JS_GetPropertyStr(ctx, global, "__dom_createElement");
    _ = c.JS_SetPropertyStr(ctx, document, "createElement", create_elem);
    const create_elem_ns = c.JS_GetPropertyStr(ctx, global, "__dom_createElementNS");
    _ = c.JS_SetPropertyStr(ctx, document, "createElementNS", create_elem_ns);

    _ = c.JS_SetPropertyStr(ctx, global, "document", document);

    const window_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, window_obj, "document", document);
    _ = c.JS_SetPropertyStr(ctx, window_obj, "devicePixelRatio", c.JS_NewInt32(ctx, 1));
    const noop_evt = c.JS_GetPropertyStr(ctx, global, "__dom_noop");
    _ = c.JS_SetPropertyStr(ctx, window_obj, "addEventListener", noop_evt);
    const noop_evt2 = c.JS_GetPropertyStr(ctx, global, "__dom_noop");
    _ = c.JS_SetPropertyStr(ctx, window_obj, "removeEventListener", noop_evt2);
    const raf = c.JS_GetPropertyStr(ctx, global, "requestAnimationFrame");
    _ = c.JS_SetPropertyStr(ctx, window_obj, "requestAnimationFrame", raf);
    const caf = c.JS_GetPropertyStr(ctx, global, "cancelAnimationFrame");
    _ = c.JS_SetPropertyStr(ctx, window_obj, "cancelAnimationFrame", caf);
    _ = c.JS_SetPropertyStr(ctx, global, "window", window_obj);
    _ = c.JS_SetPropertyStr(ctx, global, "self", window_obj);
}

const GL_ARRAY_BUFFER: u32 = 34962;
const GL_ELEMENT_ARRAY_BUFFER: u32 = 34963;
const GL_VERTEX_SHADER: u32 = 35633;
const GL_FRAGMENT_SHADER: u32 = 35632;
const GL_COMPILE_STATUS: u32 = 35713;
const GL_LINK_STATUS: u32 = 35714;
const GL_VALIDATE_STATUS: u32 = 0x8B83;
const GL_ATTACHED_SHADERS: u32 = 0x8B85;
const GL_ACTIVE_UNIFORMS: u32 = 0x8B86;
const GL_ACTIVE_ATTRIBUTES: u32 = 0x8B89;
const GL_FLOAT_VEC2: u32 = 0x8B50;
const GL_FLOAT_VEC3: u32 = 0x8B51;
const GL_FLOAT_VEC4: u32 = 0x8B52;
const GL_INT_VEC2: u32 = 0x8B53;
const GL_INT_VEC3: u32 = 0x8B54;
const GL_INT_VEC4: u32 = 0x8B55;
const GL_FLOAT_MAT4: u32 = 0x8B5C;
const GL_SAMPLER_2D: u32 = 0x8B5E;
const GL_SAMPLER_CUBE: u32 = 0x8B60;
const GL_SAMPLER_2D_SHADOW: u32 = 0x8B62;
const GL_SAMPLER_2D_ARRAY: u32 = 0x8DC1;
const GL_SAMPLER_2D_ARRAY_SHADOW: u32 = 0x8DC4;
const GL_SAMPLER_CUBE_SHADOW: u32 = 0x8DC5;
const GL_FLOAT: u32 = 5126;
const GL_INT: u32 = 0x1404;
const GL_UNSIGNED_SHORT: u32 = 5123;
const GL_UNSIGNED_INT: u32 = 5125;
const GL_TRIANGLES: u32 = 0x0004;
const GL_TRIANGLE_STRIP: u32 = 0x0005;
const GL_LINES: u32 = 0x0001;
const GL_POINTS: u32 = 0x0000;
const GL_COLOR_BUFFER_BIT: u32 = 0x00004000;
const GL_DEPTH_BUFFER_BIT: u32 = 0x00000100;
const GL_STENCIL_BUFFER_BIT: u32 = 0x00000400;
const GL_DEPTH_TEST: u32 = 0x0B71;
const GL_STENCIL_TEST: u32 = 0x0B90;
const GL_STENCIL_FUNC: u32 = 0x0B92;
const GL_STENCIL_VALUE_MASK: u32 = 0x0B93;
const GL_STENCIL_FAIL: u32 = 0x0B94;
const GL_STENCIL_PASS_DEPTH_FAIL: u32 = 0x0B95;
const GL_STENCIL_PASS_DEPTH_PASS: u32 = 0x0B96;
const GL_STENCIL_REF: u32 = 0x0B97;
const GL_STENCIL_WRITEMASK: u32 = 0x0B98;
const GL_STENCIL_BACK_FUNC: u32 = 0x8800;
const GL_STENCIL_BACK_FAIL: u32 = 0x8801;
const GL_STENCIL_BACK_PASS_DEPTH_FAIL: u32 = 0x8802;
const GL_STENCIL_BACK_PASS_DEPTH_PASS: u32 = 0x8803;
const GL_STENCIL_BACK_REF: u32 = 0x8CA3;
const GL_STENCIL_BACK_VALUE_MASK: u32 = 0x8CA4;
const GL_STENCIL_BACK_WRITEMASK: u32 = 0x8CA5;
const GL_TEXTURE_2D: u32 = 0x0DE1;
const GL_TEXTURE_CUBE_MAP: u32 = 0x8513;
const GL_TEXTURE_3D: u32 = 0x806F;
const GL_TEXTURE_2D_ARRAY: u32 = 0x8C1A;
const GL_TEXTURE_CUBE_MAP_POSITIVE_X: u32 = 0x8515;
const GL_TEXTURE_CUBE_MAP_NEGATIVE_X: u32 = 0x8516;
const GL_TEXTURE_CUBE_MAP_POSITIVE_Y: u32 = 0x8517;
const GL_TEXTURE_CUBE_MAP_NEGATIVE_Y: u32 = 0x8518;
const GL_TEXTURE_CUBE_MAP_POSITIVE_Z: u32 = 0x8519;
const GL_TEXTURE_CUBE_MAP_NEGATIVE_Z: u32 = 0x851A;
const GL_TEXTURE_MIN_FILTER: u32 = 0x2801;
const GL_TEXTURE_MAG_FILTER: u32 = 0x2800;
const GL_TEXTURE_WRAP_S: u32 = 0x2802;
const GL_TEXTURE_WRAP_T: u32 = 0x2803;
const GL_CLAMP_TO_EDGE: u32 = 0x812F;
const GL_REPEAT: u32 = 0x2901;
const GL_MIRRORED_REPEAT: u32 = 0x8370;
const GL_NEAREST: u32 = 0x2600;
const GL_LINEAR: u32 = 0x2601;
const GL_TEXTURE0: u32 = 0x84C0;
const GL_FRAMEBUFFER: u32 = 0x8D40;
const GL_RENDERBUFFER: u32 = 0x8D41;
const GL_FRAMEBUFFER_COMPLETE: u32 = 0x8CD5;
const GL_COLOR_ATTACHMENT0: u32 = 0x8CE0;
const GL_DEPTH_ATTACHMENT: u32 = 0x8D00;
const GL_STENCIL_ATTACHMENT: u32 = 0x8D20;
const GL_DEPTH_STENCIL_ATTACHMENT: u32 = 0x821A;
const GL_DEPTH_STENCIL: u32 = 0x84F9;
const GL_BLEND: u32 = 0x0BE2;
const GL_CULL_FACE: u32 = 0x0B44;
const GL_POLYGON_OFFSET_FILL: u32 = 0x8037;
const GL_SCISSOR_TEST: u32 = 0x0C11;
const GL_SAMPLE_ALPHA_TO_COVERAGE: u32 = 0x809E;
const GL_FUNC_ADD: u32 = 0x8006;
const GL_FUNC_SUBTRACT: u32 = 0x800A;
const GL_FUNC_REVERSE_SUBTRACT: u32 = 0x800B;
const GL_ONE: u32 = 1;
const GL_ZERO: u32 = 0;
const GL_SRC_ALPHA: u32 = 0x0302;
const GL_ONE_MINUS_SRC_ALPHA: u32 = 0x0303;
const GL_SRC_COLOR: u32 = 0x0300;
const GL_ONE_MINUS_SRC_COLOR: u32 = 0x0301;
const GL_DST_ALPHA: u32 = 0x0304;
const GL_ONE_MINUS_DST_ALPHA: u32 = 0x0305;
const GL_DST_COLOR: u32 = 0x0306;
const GL_ONE_MINUS_DST_COLOR: u32 = 0x0307;
const GL_CONSTANT_ALPHA: u32 = 0x8003;
const GL_ONE_MINUS_CONSTANT_ALPHA: u32 = 0x8004;
const GL_CONSTANT_COLOR: u32 = 0x8001;
const GL_ONE_MINUS_CONSTANT_COLOR: u32 = 0x8002;
const GL_FRONT: u32 = 0x0404;
const GL_BACK: u32 = 0x0405;
const GL_FRONT_AND_BACK: u32 = 0x0408;
const GL_CW: u32 = 0x0900;
const GL_CCW: u32 = 0x0901;
const GL_NEVER: u32 = 0x0200;
const GL_LESS: u32 = 0x0201;
const GL_EQUAL: u32 = 0x0202;
const GL_LEQUAL: u32 = 0x0203;
const GL_GREATER: u32 = 0x0204;
const GL_NOTEQUAL: u32 = 0x0205;
const GL_GEQUAL: u32 = 0x0206;
const GL_ALWAYS: u32 = 0x0207;
const GL_KEEP: u32 = 0x1E00;
const GL_REPLACE: u32 = 0x1E01;
const GL_INCR: u32 = 0x1E02;
const GL_DECR: u32 = 0x1E03;
const GL_INVERT: u32 = 0x150A;
const GL_INCR_WRAP: u32 = 0x8507;
const GL_DECR_WRAP: u32 = 0x8508;
const GL_VIEWPORT: u32 = 0x0BA2;
const GL_SCISSOR_BOX: u32 = 0x0C10;
const GL_VERSION: u32 = 0x1F02;
const GL_SHADING_LANGUAGE_VERSION: u32 = 0x8B8C;
const GL_VENDOR: u32 = 0x1F00;
const GL_RENDERER: u32 = 0x1F01;
const GL_MAX_TEXTURE_IMAGE_UNITS: u32 = 0x8872;
const GL_MAX_VERTEX_ATTRIBS: u32 = 0x8869;
const GL_MAX_TEXTURE_SIZE: u32 = 0x0D33;
const GL_MAX_CUBE_MAP_TEXTURE_SIZE: u32 = 0x851C;
const GL_MAX_VERTEX_UNIFORM_VECTORS: u32 = 0x8DFB;
const GL_MAX_FRAGMENT_UNIFORM_VECTORS: u32 = 0x8DFD;
const GL_MAX_VARYING_VECTORS: u32 = 0x8DFC;
const GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS: u32 = 0x8B4C;
const GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS: u32 = 0x8B4D;
const GL_ALIASED_LINE_WIDTH_RANGE: u32 = 0x846E;
const GL_ALIASED_POINT_SIZE_RANGE: u32 = 0x846D;
const GL_MAX_VIEWPORT_DIMS: u32 = 0x0D3A;
const GL_SAMPLES: u32 = 0x80A9;
const GL_MAX_SAMPLES: u32 = 0x8D57;
const GL_IMPLEMENTATION_COLOR_READ_FORMAT: u32 = 0x8B9B;
const GL_IMPLEMENTATION_COLOR_READ_TYPE: u32 = 0x8B9A;
const GL_UNPACK_ALIGNMENT: u32 = 0x0CF5;
const GL_UNPACK_ROW_LENGTH: u32 = 0x0CF2;
const GL_UNPACK_SKIP_PIXELS: u32 = 0x0CF4;
const GL_UNPACK_SKIP_ROWS: u32 = 0x0CF3;
const GL_UNPACK_FLIP_Y_WEBGL: u32 = 0x9240;
const GL_UNPACK_PREMULTIPLY_ALPHA_WEBGL: u32 = 0x9241;
const GL_UNPACK_COLORSPACE_CONVERSION_WEBGL: u32 = 0x9243;
const GL_RGBA: u32 = 0x1908;
const GL_UNSIGNED_BYTE: u32 = 0x1401;
const GL_NO_ERROR: u32 = 0;
const MaxUniformFloatCount: usize = @as(usize, @intCast(webgl_program.MaxUniformArrayCount)) * 16;

fn bufferIdToU32(id: webgl.BufferId) u32 {
    return @bitCast(id);
}

fn bufferIdFromU32(value: u32) webgl.BufferId {
    return @bitCast(value);
}

fn shaderIdToU32(id: webgl_shader.ShaderId) u32 {
    return @bitCast(id);
}

fn shaderIdFromU32(value: u32) webgl_shader.ShaderId {
    return @bitCast(value);
}

fn programIdToU32(id: webgl_program.ProgramId) u32 {
    return @bitCast(id);
}

fn programIdFromU32(value: u32) webgl_program.ProgramId {
    return @bitCast(value);
}

fn parseBufferTarget(target: u32) !webgl_state.BufferTarget {
    return switch (target) {
        GL_ARRAY_BUFFER => .array,
        GL_ELEMENT_ARRAY_BUFFER => .element_array,
        else => error.InvalidTarget,
    };
}

fn parseShaderKind(kind: u32) !webgl_shader.ShaderKind {
    return switch (kind) {
        GL_VERTEX_SHADER => .vertex,
        GL_FRAGMENT_SHADER => .fragment,
        else => error.InvalidShaderType,
    };
}

fn readUniformLocation(ctx: *c.JSContext, value: c.JSValue) !?u32 {
    if (value == c.JS_NULL or value == c.JS_UNDEFINED) {
        return null;
    }
    var loc_i: c_int = 0;
    if (c.JS_ToInt32(ctx, &loc_i, value) != 0) {
        return error.JsException;
    }
    if (loc_i < 0) return null;
    return @intCast(loc_i);
}

fn readFloatValues(ctx: *c.JSContext, value: c.JSValue, out: []f32) !usize {
    var c_ptr: [*c]u8 = null;
    var len: usize = 0;
    if (c.JS_GetTypedArrayData(ctx, value, &c_ptr, &len) == 0) {
        return copyFloatBytes(out, c_ptr, len);
    }
    if (c.JS_GetArrayBufferData(ctx, value, &c_ptr, &len) == 0) {
        return copyFloatBytes(out, c_ptr, len);
    }
    return error.InvalidType;
}

fn copyFloatBytes(out: []f32, c_ptr: [*c]u8, len: usize) !usize {
    if (len % 4 != 0) return error.InvalidLength;
    const count = len / 4;
    if (count > out.len) return error.TooLarge;
    const bytes: [*]const u8 = @ptrCast(c_ptr);
    @memcpy(std.mem.sliceAsBytes(out[0..count]), bytes[0..len]);
    return count;
}

fn logFunc(_: ?*anyopaque, buf: ?*const anyopaque, len: usize) callconv(.c) void {
    if (buf) |ptr| {
        const bytes: [*]const u8 = @ptrCast(ptr);
        _ = std.fs.File.stdout().writeAll(bytes[0..len]) catch {};
    }
}

// =============================================================================
// Stdlib function implementations (exported to C)
// =============================================================================

export fn js_print(ctx: *c.JSContext, this_val: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        if (i != 0) {
            _ = std.fs.File.stdout().writeAll(" ") catch {};
        }
        const v = argv[@intCast(i)];
        if (c.JS_IsString(ctx, v) != 0) {
            var len: usize = 0;
            var buf: c.JSCStringBuf = undefined;
            const c_str = c.JS_ToCStringLen(ctx, &len, v, &buf);
            if (c_str == null) {
                return c.JS_EXCEPTION;
            }
            const slice: [*]const u8 = @ptrCast(c_str);
            _ = std.fs.File.stdout().writeAll(slice[0..len]) catch {};
        } else {
            c.JS_PrintValueF(ctx, v, c.JS_DUMP_LONG);
        }
    }
    _ = std.fs.File.stdout().writeAll("\n") catch {};
    return c.JS_UNDEFINED;
}

export fn js_date_now(ctx: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    const now_ms: i64 = std.time.milliTimestamp();
    return c.JS_NewInt64(ctx, now_ms);
}

export fn js_performance_now(ctx: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    const now_ms: i64 = std.time.milliTimestamp();
    const elapsed_ms: f64 = @floatFromInt(now_ms - g_start_time_ms);
    return c.JS_NewFloat64(ctx, elapsed_ms);
}

export fn js_gc(ctx: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    c.JS_GC(ctx);
    return c.JS_UNDEFINED;
}

const SanitizedScript = struct {
    bytes: []const u8,
    owned: bool,
};

fn sanitizeScriptBytes(allocator: std.mem.Allocator, input: []const u8) !SanitizedScript {
    var start: usize = 0;
    if (input.len >= 3 and input[0] == 0xEF and input[1] == 0xBB and input[2] == 0xBF) {
        start = 3;
    }

    var needs_copy = false;
    var idx: usize = start;
    while (idx < input.len) : (idx += 1) {
        const b = input[idx];
        if (b == '\r' or b == 0x1A or b == 0x00) {
            needs_copy = true;
            break;
        }
    }

    if (!needs_copy) {
        const slice = input[start..];
        if (!std.unicode.utf8ValidateSlice(slice)) {
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(allocator);
            for (slice) |b| {
                if (b == '\n' or b == '\t' or (b >= 0x20 and b <= 0x7E)) {
                    try out.append(allocator, b);
                }
            }
            return .{ .bytes = try out.toOwnedSlice(allocator), .owned = true };
        }
        return .{ .bytes = slice, .owned = false };
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    idx = start;
    while (idx < input.len) : (idx += 1) {
        const b = input[idx];
        if (b == '\r') {
            if (idx + 1 < input.len and input[idx + 1] == '\n') {
                idx += 1;
            }
            try out.append(allocator, '\n');
            continue;
        }
        if (b == 0x1A or b == 0x00) {
            continue;
        }
        try out.append(allocator, b);
    }

    var sanitized = SanitizedScript{ .bytes = try out.toOwnedSlice(allocator), .owned = true };
    if (!std.unicode.utf8ValidateSlice(sanitized.bytes)) {
        var ascii_out = std.ArrayList(u8).empty;
        errdefer ascii_out.deinit(allocator);
        for (sanitized.bytes) |b| {
            if (b == '\n' or b == '\t' or (b >= 0x20 and b <= 0x7E)) {
                try ascii_out.append(allocator, b);
            }
        }
        allocator.free(sanitized.bytes);
        sanitized.bytes = try ascii_out.toOwnedSlice(allocator);
    }
    return sanitized;
}

export fn js_load(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) {
        return throwTypeError(ctx, "load requires a filename");
    }
    const rt = getRuntime(ctx) orelse {
        return throwInternalError(ctx, "runtime not initialized");
    };

    var buf: c.JSCStringBuf = undefined;
    const filename = c.JS_ToCString(ctx, argv[0], &buf);
    if (filename == null) {
        return c.JS_EXCEPTION;
    }

    const path = std.mem.span(@as([*:0]const u8, @ptrCast(filename)));
    const max_bytes: usize = 16 * 1024 * 1024;
    const data = std.fs.cwd().readFileAlloc(rt.allocator, path, max_bytes) catch {
        return throwInternalError(ctx, "failed to read file");
    };
    defer rt.allocator.free(data);

    const sanitized = sanitizeScriptBytes(rt.allocator, data) catch {
        return throwInternalError(ctx, "failed to sanitize script");
    };
    defer if (sanitized.owned) rt.allocator.free(sanitized.bytes);

    // Ensure a NUL-terminated buffer in case the parser relies on it.
    const eval_buf = rt.allocator.alloc(u8, sanitized.bytes.len + 1) catch {
        return throwInternalError(ctx, "failed to allocate eval buffer");
    };
    defer rt.allocator.free(eval_buf);
    @memcpy(eval_buf[0..sanitized.bytes.len], sanitized.bytes);
    eval_buf[sanitized.bytes.len] = 0;

    return c.JS_Eval(ctx, eval_buf.ptr, sanitized.bytes.len, filename, 0);
}

export fn js_setTimeout(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) {
        return throwTypeError(ctx, "setTimeout requires (function, delay_ms)");
    }
    if (c.JS_IsFunction(ctx, argv[0]) == 0) {
        return throwTypeError(ctx, "setTimeout: first argument is not a function");
    }
    var delay_ms: c_int = 0;
    if (c.JS_ToInt32(ctx, &delay_ms, argv[1]) != 0) {
        return c.JS_EXCEPTION;
    }

    const rt = getRuntime(ctx) orelse {
        return throwInternalError(ctx, "runtime not initialized");
    };

    for (&rt.timers, 0..) |*timer, idx| {
        if (!timer.allocated) {
            const pfunc = c.JS_AddGCRef(ctx, &timer.func);
            pfunc.* = argv[0];
            timer.timeout_ms = rt.shared.time_ms + @as(f64, @floatFromInt(delay_ms));
            timer.allocated = true;
            return c.JS_NewInt32(ctx, @intCast(idx));
        }
    }
    return throwInternalError(ctx, "too many timers");
}

export fn js_clearTimeout(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) {
        return c.JS_UNDEFINED;
    }
    var timer_id: c_int = 0;
    if (c.JS_ToInt32(ctx, &timer_id, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    const rt = getRuntime(ctx) orelse {
        return throwInternalError(ctx, "runtime not initialized");
    };
    if (timer_id >= 0 and timer_id < MaxTimers) {
        const t = &rt.timers[@intCast(timer_id)];
        if (t.allocated) {
            c.JS_DeleteGCRef(ctx, &t.func);
            t.allocated = false;
        }
    }
    return c.JS_UNDEFINED;
}

export fn js_setClearColor(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 3) {
        return throwTypeError(ctx, "setClearColor requires (r, g, b)");
    }
    var r: f64 = 0;
    var g: f64 = 0;
    var b: f64 = 0;
    if (c.JS_ToNumber(ctx, &r, argv[0]) != 0) return c.JS_EXCEPTION;
    if (c.JS_ToNumber(ctx, &g, argv[1]) != 0) return c.JS_EXCEPTION;
    if (c.JS_ToNumber(ctx, &b, argv[2]) != 0) return c.JS_EXCEPTION;

    const rt = getRuntime(ctx) orelse {
        return throwInternalError(ctx, "runtime not initialized");
    };
    rt.shared.clear_color = .{ @floatCast(r), @floatCast(g), @floatCast(b) };
    return c.JS_UNDEFINED;
}

export fn js_requestAnimationFrame(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) {
        return throwTypeError(ctx, "requestAnimationFrame requires a callback");
    }
    if (c.JS_IsFunction(ctx, argv[0]) == 0) {
        return throwTypeError(ctx, "requestAnimationFrame: argument is not a function");
    }
    const rt = getRuntime(ctx) orelse {
        return throwInternalError(ctx, "runtime not initialized");
    };

    for (&rt.raf) |*entry| {
        if (!entry.active) {
            const pfunc = c.JS_AddGCRef(ctx, &entry.func);
            pfunc.* = argv[0];
            entry.id = rt.next_raf_id;
            rt.next_raf_id += 1;
            entry.active = true;
            return c.JS_NewInt32(ctx, entry.id);
        }
    }
    return throwInternalError(ctx, "too many animation frame callbacks");
}

export fn js_cancelAnimationFrame(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) {
        return c.JS_UNDEFINED;
    }
    var id: c_int = 0;
    if (c.JS_ToInt32(ctx, &id, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    const rt = getRuntime(ctx) orelse {
        return throwInternalError(ctx, "runtime not initialized");
    };
    for (&rt.raf) |*entry| {
        if (entry.active and entry.id == id) {
            c.JS_DeleteGCRef(ctx, &entry.func);
            entry.active = false;
            break;
        }
    }
    return c.JS_UNDEFINED;
}

export fn js_dom_noop(_: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    return c.JS_UNDEFINED;
}

fn createElementForTag(ctx: *c.JSContext, tag: []const u8) c.JSValue {
    const elem = c.JS_NewObject(ctx);
    const style = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, elem, "style", style);

    const global = c.JS_GetGlobalObject(ctx);
    const noop = c.JS_GetPropertyStr(ctx, global, "__dom_noop");
    _ = c.JS_SetPropertyStr(ctx, elem, "addEventListener", noop);
    const noop2 = c.JS_GetPropertyStr(ctx, global, "__dom_noop");
    _ = c.JS_SetPropertyStr(ctx, elem, "removeEventListener", noop2);

    if (std.mem.eql(u8, tag, "canvas")) {
        _ = c.JS_SetPropertyStr(ctx, elem, "width", c.JS_NewInt32(ctx, 800));
        _ = c.JS_SetPropertyStr(ctx, elem, "height", c.JS_NewInt32(ctx, 600));
        const get_ctx = c.JS_GetPropertyStr(ctx, global, "__dom_getContext");
        _ = c.JS_SetPropertyStr(ctx, elem, "getContext", get_ctx);
    }

    return elem;
}

export fn js_dom_createElement(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1 or c.JS_IsString(ctx, argv[0]) == 0) {
        return c.JS_UNDEFINED;
    }
    var len: usize = 0;
    var buf: c.JSCStringBuf = undefined;
    const c_str = c.JS_ToCStringLen(ctx, &len, argv[0], &buf);
    if (c_str == null) return c.JS_UNDEFINED;
    const tag = @as([*]const u8, @ptrCast(c_str))[0..len];
    return createElementForTag(ctx, tag);
}

export fn js_dom_createElementNS(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2 or c.JS_IsString(ctx, argv[1]) == 0) {
        return c.JS_UNDEFINED;
    }
    var len: usize = 0;
    var buf: c.JSCStringBuf = undefined;
    const c_str = c.JS_ToCStringLen(ctx, &len, argv[1], &buf);
    if (c_str == null) return c.JS_UNDEFINED;
    const tag = @as([*]const u8, @ptrCast(c_str))[0..len];
    return createElementForTag(ctx, tag);
}

export fn js_dom_getContext(ctx: *c.JSContext, this_val: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1 or c.JS_IsString(ctx, argv[0]) == 0) {
        return c.JS_NULL;
    }
    var len: usize = 0;
    var buf: c.JSCStringBuf = undefined;
    const c_str = c.JS_ToCStringLen(ctx, &len, argv[0], &buf);
    if (c_str == null) return c.JS_NULL;
    const kind = @as([*]const u8, @ptrCast(c_str))[0..len];
    if (!(std.mem.eql(u8, kind, "webgl") or std.mem.eql(u8, kind, "webgl2"))) {
        return c.JS_NULL;
    }

    const canvas = this_val.*;
    const existing = c.JS_GetPropertyStr(ctx, canvas, "_ctx");
    if (c.JS_IsUndefined(existing) == 0 and c.JS_IsNull(existing) == 0) {
        return existing;
    }

    const global = c.JS_GetGlobalObject(ctx);
    const gl_val = c.JS_GetPropertyStr(ctx, global, "gl");
    if (c.JS_IsUndefined(gl_val) != 0 or c.JS_IsNull(gl_val) != 0) {
        return c.JS_NULL;
    }

    var width: i32 = 0;
    var height: i32 = 0;
    const width_val = c.JS_GetPropertyStr(ctx, canvas, "width");
    _ = c.JS_ToInt32(ctx, &width, width_val);
    const height_val = c.JS_GetPropertyStr(ctx, canvas, "height");
    _ = c.JS_ToInt32(ctx, &height, height_val);
    _ = c.JS_SetPropertyStr(ctx, gl_val, "drawingBufferWidth", c.JS_NewInt32(ctx, width));
    _ = c.JS_SetPropertyStr(ctx, gl_val, "drawingBufferHeight", c.JS_NewInt32(ctx, height));
    _ = c.JS_SetPropertyStr(ctx, gl_val, "canvas", canvas);

    g_gl_state.viewport = .{ 0, 0, width, height };
    g_gl_state.scissor = .{ 0, 0, width, height };
    webgl_draw.setViewport(0, 0, width, height);
    webgl_draw.setScissor(0, 0, width, height);

    _ = c.JS_SetPropertyStr(ctx, canvas, "_ctx", gl_val);
    return gl_val;
}

fn setEnableState(cap: u32, enabled: bool) void {
    switch (cap) {
        GL_DEPTH_TEST => g_gl_state.enabled_depth_test = enabled,
        GL_STENCIL_TEST => g_gl_state.enabled_stencil_test = enabled,
        GL_BLEND => g_gl_state.enabled_blend = enabled,
        GL_CULL_FACE => g_gl_state.enabled_cull_face = enabled,
        GL_POLYGON_OFFSET_FILL => g_gl_state.enabled_polygon_offset = enabled,
        GL_SCISSOR_TEST => g_gl_state.enabled_scissor_test = enabled,
        GL_SAMPLE_ALPHA_TO_COVERAGE => g_gl_state.enabled_sample_alpha_to_coverage = enabled,
        else => {},
    }
}

fn applyStencilFaceU32(face: u32, front: *u32, back: *u32, value: u32) void {
    switch (face) {
        GL_FRONT => front.* = value,
        GL_BACK => back.* = value,
        GL_FRONT_AND_BACK => {
            front.* = value;
            back.* = value;
        },
        else => {},
    }
}

fn applyStencilFaceU8(face: u32, front: *u8, back: *u8, value: u8) void {
    switch (face) {
        GL_FRONT => front.* = value,
        GL_BACK => back.* = value,
        GL_FRONT_AND_BACK => {
            front.* = value;
            back.* = value;
        },
        else => {},
    }
}

fn allocTextureId() ?u32 {
    var idx: usize = @intCast((g_next_texture_id - 1) % MaxTextures);
    var tried: usize = 0;
    while (tried < MaxTextures) : (tried += 1) {
        if (!g_texture_live[idx]) {
            g_texture_live[idx] = true;
            g_next_texture_id = @intCast(idx + 2);
            return @intCast(idx + 1);
        }
        idx = (idx + 1) % MaxTextures;
    }
    return null;
}

fn isTextureId(id: u32) bool {
    if (id == 0 or id > MaxTextures) return false;
    return g_texture_live[id - 1];
}

fn freeTextureId(id: u32) bool {
    if (!isTextureId(id)) return false;
    g_texture_live[id - 1] = false;
    return true;
}

fn allocFramebufferId() ?u32 {
    var idx: usize = @intCast((g_next_framebuffer_id - 1) % MaxFramebuffers);
    var tried: usize = 0;
    while (tried < MaxFramebuffers) : (tried += 1) {
        if (!g_framebuffer_live[idx]) {
            g_framebuffer_live[idx] = true;
            g_next_framebuffer_id = @intCast(idx + 2);
            return @intCast(idx + 1);
        }
        idx = (idx + 1) % MaxFramebuffers;
    }
    return null;
}

fn isFramebufferId(id: u32) bool {
    if (id == 0 or id > MaxFramebuffers) return false;
    return g_framebuffer_live[id - 1];
}

fn freeFramebufferId(id: u32) bool {
    if (!isFramebufferId(id)) return false;
    g_framebuffer_live[id - 1] = false;
    return true;
}

fn allocRenderbufferId() ?u32 {
    var idx: usize = @intCast((g_next_renderbuffer_id - 1) % MaxRenderbuffers);
    var tried: usize = 0;
    while (tried < MaxRenderbuffers) : (tried += 1) {
        if (!g_renderbuffer_live[idx]) {
            g_renderbuffer_live[idx] = true;
            g_next_renderbuffer_id = @intCast(idx + 2);
            return @intCast(idx + 1);
        }
        idx = (idx + 1) % MaxRenderbuffers;
    }
    return null;
}

fn isRenderbufferId(id: u32) bool {
    if (id == 0 or id > MaxRenderbuffers) return false;
    return g_renderbuffer_live[id - 1];
}

fn freeRenderbufferId(id: u32) bool {
    if (!isRenderbufferId(id)) return false;
    g_renderbuffer_live[id - 1] = false;
    return true;
}

fn allocVaoId() ?u32 {
    var idx: usize = @intCast((g_next_vao_id - 1) % MaxVertexArrays);
    var tried: usize = 0;
    while (tried < MaxVertexArrays) : (tried += 1) {
        if (!g_vao_live[idx]) {
            g_vao_live[idx] = true;
            g_next_vao_id = @intCast(idx + 2);
            return @intCast(idx + 1);
        }
        idx = (idx + 1) % MaxVertexArrays;
    }
    return null;
}

fn isVaoId(id: u32) bool {
    if (id == 0 or id > MaxVertexArrays) return false;
    return g_vao_live[id - 1];
}

fn freeVaoId(id: u32) bool {
    if (!isVaoId(id)) return false;
    g_vao_live[id - 1] = false;
    return true;
}

fn uniformTypeToGlEnum(utype: sg.UniformType) u32 {
    return switch (utype) {
        .FLOAT => GL_FLOAT,
        .FLOAT2 => GL_FLOAT_VEC2,
        .FLOAT3 => GL_FLOAT_VEC3,
        .FLOAT4 => GL_FLOAT_VEC4,
        .INT => GL_INT,
        .INT2 => GL_INT_VEC2,
        .INT3 => GL_INT_VEC3,
        .INT4 => GL_INT_VEC4,
        .MAT4 => GL_FLOAT_MAT4,
        else => GL_FLOAT,
    };
}

fn samplerKindToGlEnum(kind: u8) u32 {
    return if (kind == 1) GL_SAMPLER_CUBE else GL_SAMPLER_2D;
}

export fn js_gl_getParameter(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    var pname: u32 = 0;
    if (c.JS_ToUint32(ctx, &pname, argv[0]) != 0) return c.JS_EXCEPTION;
    switch (pname) {
        GL_VERSION => {
            const val = "WebGL 1.0 (three-native)";
            return c.JS_NewStringLen(ctx, val.ptr, val.len);
        },
        GL_SHADING_LANGUAGE_VERSION => {
            const val = "WebGL GLSL ES 1.0";
            return c.JS_NewStringLen(ctx, val.ptr, val.len);
        },
        GL_VENDOR => {
            const val = "three-native";
            return c.JS_NewStringLen(ctx, val.ptr, val.len);
        },
        GL_RENDERER => {
            const val = "sokol";
            return c.JS_NewStringLen(ctx, val.ptr, val.len);
        },
        GL_MAX_TEXTURE_IMAGE_UNITS => return c.JS_NewInt32(ctx, 8),
        GL_MAX_VERTEX_ATTRIBS => return c.JS_NewInt32(ctx, 16),
        GL_MAX_TEXTURE_SIZE => return c.JS_NewInt32(ctx, 4096),
        GL_MAX_CUBE_MAP_TEXTURE_SIZE => return c.JS_NewInt32(ctx, 4096),
        GL_MAX_VERTEX_UNIFORM_VECTORS => return c.JS_NewInt32(ctx, 128),
        GL_MAX_FRAGMENT_UNIFORM_VECTORS => return c.JS_NewInt32(ctx, 128),
        GL_MAX_VARYING_VECTORS => return c.JS_NewInt32(ctx, 8),
        GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS => return c.JS_NewInt32(ctx, 8),
        GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS => return c.JS_NewInt32(ctx, 8),
        GL_ALIASED_LINE_WIDTH_RANGE => return jsArray2(ctx, 1, 1),
        GL_ALIASED_POINT_SIZE_RANGE => return jsArray2(ctx, 1, 1),
        GL_MAX_VIEWPORT_DIMS => return jsArray2(ctx, 4096, 4096),
        GL_VIEWPORT => return jsArray4(ctx, g_gl_state.viewport[0], g_gl_state.viewport[1], g_gl_state.viewport[2], g_gl_state.viewport[3]),
        GL_SCISSOR_BOX => return jsArray4(ctx, g_gl_state.scissor[0], g_gl_state.scissor[1], g_gl_state.scissor[2], g_gl_state.scissor[3]),
        GL_SAMPLES => return c.JS_NewInt32(ctx, 1),
        GL_MAX_SAMPLES => return c.JS_NewInt32(ctx, 1),
        GL_IMPLEMENTATION_COLOR_READ_FORMAT => return c.JS_NewInt32(ctx, @intCast(GL_RGBA)),
        GL_IMPLEMENTATION_COLOR_READ_TYPE => return c.JS_NewInt32(ctx, @intCast(GL_UNSIGNED_BYTE)),
        GL_UNPACK_ALIGNMENT => return c.JS_NewInt32(ctx, g_gl_state.unpack_alignment),
        GL_UNPACK_ROW_LENGTH => return c.JS_NewInt32(ctx, g_gl_state.unpack_row_length),
        GL_UNPACK_SKIP_PIXELS => return c.JS_NewInt32(ctx, g_gl_state.unpack_skip_pixels),
        GL_UNPACK_SKIP_ROWS => return c.JS_NewInt32(ctx, g_gl_state.unpack_skip_rows),
        GL_UNPACK_FLIP_Y_WEBGL => return if (g_gl_state.unpack_flip_y) c.JS_TRUE else c.JS_FALSE,
        GL_UNPACK_PREMULTIPLY_ALPHA_WEBGL => return if (g_gl_state.unpack_premultiply_alpha) c.JS_TRUE else c.JS_FALSE,
        GL_UNPACK_COLORSPACE_CONVERSION_WEBGL => return c.JS_NewInt32(ctx, g_gl_state.unpack_colorspace_conversion),
        GL_STENCIL_FUNC => return c.JS_NewInt32(ctx, @intCast(g_gl_state.stencil_func_front)),
        GL_STENCIL_REF => return c.JS_NewInt32(ctx, g_gl_state.stencil_ref_front),
        GL_STENCIL_VALUE_MASK => return c.JS_NewInt32(ctx, g_gl_state.stencil_value_mask_front),
        GL_STENCIL_WRITEMASK => return c.JS_NewInt32(ctx, g_gl_state.stencil_write_mask_front),
        GL_STENCIL_FAIL => return c.JS_NewInt32(ctx, @intCast(g_gl_state.stencil_fail_front)),
        GL_STENCIL_PASS_DEPTH_FAIL => return c.JS_NewInt32(ctx, @intCast(g_gl_state.stencil_zfail_front)),
        GL_STENCIL_PASS_DEPTH_PASS => return c.JS_NewInt32(ctx, @intCast(g_gl_state.stencil_zpass_front)),
        GL_STENCIL_BACK_FUNC => return c.JS_NewInt32(ctx, @intCast(g_gl_state.stencil_func_back)),
        GL_STENCIL_BACK_REF => return c.JS_NewInt32(ctx, g_gl_state.stencil_ref_back),
        GL_STENCIL_BACK_VALUE_MASK => return c.JS_NewInt32(ctx, g_gl_state.stencil_value_mask_back),
        GL_STENCIL_BACK_WRITEMASK => return c.JS_NewInt32(ctx, g_gl_state.stencil_write_mask_back),
        GL_STENCIL_BACK_FAIL => return c.JS_NewInt32(ctx, @intCast(g_gl_state.stencil_fail_back)),
        GL_STENCIL_BACK_PASS_DEPTH_FAIL => return c.JS_NewInt32(ctx, @intCast(g_gl_state.stencil_zfail_back)),
        GL_STENCIL_BACK_PASS_DEPTH_PASS => return c.JS_NewInt32(ctx, @intCast(g_gl_state.stencil_zpass_back)),
        GL_DEPTH_TEST => return if (g_gl_state.enabled_depth_test) c.JS_TRUE else c.JS_FALSE,
        GL_STENCIL_TEST => return if (g_gl_state.enabled_stencil_test) c.JS_TRUE else c.JS_FALSE,
        GL_BLEND => return if (g_gl_state.enabled_blend) c.JS_TRUE else c.JS_FALSE,
        GL_CULL_FACE => return if (g_gl_state.enabled_cull_face) c.JS_TRUE else c.JS_FALSE,
        GL_POLYGON_OFFSET_FILL => return if (g_gl_state.enabled_polygon_offset) c.JS_TRUE else c.JS_FALSE,
        GL_SCISSOR_TEST => return if (g_gl_state.enabled_scissor_test) c.JS_TRUE else c.JS_FALSE,
        GL_SAMPLE_ALPHA_TO_COVERAGE => return if (g_gl_state.enabled_sample_alpha_to_coverage) c.JS_TRUE else c.JS_FALSE,
        else => return c.JS_NULL,
    }
}

export fn js_gl_getExtension(ctx: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    _ = ctx;
    return c.JS_NULL;
}

export fn js_gl_getSupportedExtensions(ctx: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    return c.JS_NewArray(ctx, 0);
}

export fn js_gl_getContextAttributes(ctx: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "alpha", c.JS_TRUE);
    _ = c.JS_SetPropertyStr(ctx, obj, "depth", c.JS_TRUE);
    _ = c.JS_SetPropertyStr(ctx, obj, "stencil", c.JS_FALSE);
    _ = c.JS_SetPropertyStr(ctx, obj, "antialias", c.JS_FALSE);
    _ = c.JS_SetPropertyStr(ctx, obj, "premultipliedAlpha", c.JS_TRUE);
    _ = c.JS_SetPropertyStr(ctx, obj, "preserveDrawingBuffer", c.JS_FALSE);
    return obj;
}

export fn js_gl_stencilFunc(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 3) return c.JS_UNDEFINED;
    var func: u32 = 0;
    var ref: i32 = 0;
    var mask: u32 = 0;
    _ = c.JS_ToUint32(ctx, &func, argv[0]);
    _ = c.JS_ToInt32(ctx, &ref, argv[1]);
    _ = c.JS_ToUint32(ctx, &mask, argv[2]);
    const ref_u8 = clampU8(ref);
    const mask_u8: u8 = @truncate(mask);
    g_gl_state.stencil_func_front = func;
    g_gl_state.stencil_func_back = func;
    g_gl_state.stencil_ref_front = ref_u8;
    g_gl_state.stencil_ref_back = ref_u8;
    g_gl_state.stencil_value_mask_front = mask_u8;
    g_gl_state.stencil_value_mask_back = mask_u8;
    webgl_draw.setStencilFunc(func, ref, mask);
    return c.JS_UNDEFINED;
}

export fn js_gl_stencilFuncSeparate(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 4) return c.JS_UNDEFINED;
    var face: u32 = 0;
    var func: u32 = 0;
    var ref: i32 = 0;
    var mask: u32 = 0;
    _ = c.JS_ToUint32(ctx, &face, argv[0]);
    _ = c.JS_ToUint32(ctx, &func, argv[1]);
    _ = c.JS_ToInt32(ctx, &ref, argv[2]);
    _ = c.JS_ToUint32(ctx, &mask, argv[3]);
    const ref_u8 = clampU8(ref);
    const mask_u8: u8 = @truncate(mask);
    applyStencilFaceU32(face, &g_gl_state.stencil_func_front, &g_gl_state.stencil_func_back, func);
    applyStencilFaceU8(face, &g_gl_state.stencil_ref_front, &g_gl_state.stencil_ref_back, ref_u8);
    applyStencilFaceU8(face, &g_gl_state.stencil_value_mask_front, &g_gl_state.stencil_value_mask_back, mask_u8);
    webgl_draw.setStencilFuncSeparate(face, func, ref, mask);
    return c.JS_UNDEFINED;
}

export fn js_gl_stencilMask(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    var mask: u32 = 0;
    _ = c.JS_ToUint32(ctx, &mask, argv[0]);
    const mask_u8: u8 = @truncate(mask);
    g_gl_state.stencil_write_mask_front = mask_u8;
    g_gl_state.stencil_write_mask_back = mask_u8;
    webgl_draw.setStencilMask(mask);
    return c.JS_UNDEFINED;
}

export fn js_gl_stencilMaskSeparate(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) return c.JS_UNDEFINED;
    var face: u32 = 0;
    var mask: u32 = 0;
    _ = c.JS_ToUint32(ctx, &face, argv[0]);
    _ = c.JS_ToUint32(ctx, &mask, argv[1]);
    const mask_u8: u8 = @truncate(mask);
    applyStencilFaceU8(face, &g_gl_state.stencil_write_mask_front, &g_gl_state.stencil_write_mask_back, mask_u8);
    webgl_draw.setStencilMaskSeparate(face, mask);
    return c.JS_UNDEFINED;
}

export fn js_gl_stencilOp(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 3) return c.JS_UNDEFINED;
    var fail: u32 = 0;
    var zfail: u32 = 0;
    var zpass: u32 = 0;
    _ = c.JS_ToUint32(ctx, &fail, argv[0]);
    _ = c.JS_ToUint32(ctx, &zfail, argv[1]);
    _ = c.JS_ToUint32(ctx, &zpass, argv[2]);
    g_gl_state.stencil_fail_front = fail;
    g_gl_state.stencil_zfail_front = zfail;
    g_gl_state.stencil_zpass_front = zpass;
    g_gl_state.stencil_fail_back = fail;
    g_gl_state.stencil_zfail_back = zfail;
    g_gl_state.stencil_zpass_back = zpass;
    webgl_draw.setStencilOp(fail, zfail, zpass);
    return c.JS_UNDEFINED;
}

export fn js_gl_stencilOpSeparate(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 4) return c.JS_UNDEFINED;
    var face: u32 = 0;
    var fail: u32 = 0;
    var zfail: u32 = 0;
    var zpass: u32 = 0;
    _ = c.JS_ToUint32(ctx, &face, argv[0]);
    _ = c.JS_ToUint32(ctx, &fail, argv[1]);
    _ = c.JS_ToUint32(ctx, &zfail, argv[2]);
    _ = c.JS_ToUint32(ctx, &zpass, argv[3]);
    applyStencilFaceU32(face, &g_gl_state.stencil_fail_front, &g_gl_state.stencil_fail_back, fail);
    applyStencilFaceU32(face, &g_gl_state.stencil_zfail_front, &g_gl_state.stencil_zfail_back, zfail);
    applyStencilFaceU32(face, &g_gl_state.stencil_zpass_front, &g_gl_state.stencil_zpass_back, zpass);
    webgl_draw.setStencilOpSeparate(face, fail, zfail, zpass);
    return c.JS_UNDEFINED;
}

export fn js_gl_activeTexture(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    var unit: u32 = 0;
    if (c.JS_ToUint32(ctx, &unit, argv[0]) != 0) return c.JS_EXCEPTION;
    if (unit < GL_TEXTURE0) return c.JS_UNDEFINED;
    const idx = unit - GL_TEXTURE0;
    if (idx >= MaxTextureUnits) return c.JS_UNDEFINED;
    g_gl_state.active_texture_unit = idx;
    return c.JS_UNDEFINED;
}

export fn js_gl_createTexture(ctx: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    const id = allocTextureId() orelse return c.JS_NULL;
    return c.JS_NewUint32(ctx, id);
}

export fn js_gl_deleteTexture(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) return c.JS_EXCEPTION;
    if (freeTextureId(raw)) {
        for (&g_gl_state.bound_textures_2d) |*slot| {
            if (slot.* == raw) slot.* = 0;
        }
        for (&g_gl_state.bound_textures_cube) |*slot| {
            if (slot.* == raw) slot.* = 0;
        }
    }
    return c.JS_UNDEFINED;
}

export fn js_gl_bindTexture(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) return c.JS_UNDEFINED;
    var target: u32 = 0;
    if (c.JS_ToUint32(ctx, &target, argv[0]) != 0) return c.JS_EXCEPTION;
    var raw: u32 = 0;
    if (argv[1] != c.JS_NULL and argv[1] != c.JS_UNDEFINED) {
        if (c.JS_ToUint32(ctx, &raw, argv[1]) != 0) return c.JS_EXCEPTION;
    }
    if (raw != 0 and !isTextureId(raw)) {
        return throwTypeError(ctx, "invalid texture handle");
    }
    const unit = g_gl_state.active_texture_unit;
    switch (target) {
        GL_TEXTURE_2D, GL_TEXTURE_2D_ARRAY, GL_TEXTURE_3D => g_gl_state.bound_textures_2d[unit] = raw,
        GL_TEXTURE_CUBE_MAP => g_gl_state.bound_textures_cube[unit] = raw,
        else => {},
    }
    return c.JS_UNDEFINED;
}

export fn js_gl_texParameteri(_: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    return c.JS_UNDEFINED;
}

export fn js_gl_texImage2D(_: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    return c.JS_UNDEFINED;
}

export fn js_gl_texSubImage2D(_: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    return c.JS_UNDEFINED;
}

export fn js_gl_texImage3D(_: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    return c.JS_UNDEFINED;
}

export fn js_gl_texSubImage3D(_: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    return c.JS_UNDEFINED;
}

export fn js_gl_generateMipmap(_: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    return c.JS_UNDEFINED;
}

export fn js_gl_createFramebuffer(ctx: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    const id = allocFramebufferId() orelse return c.JS_NULL;
    return c.JS_NewUint32(ctx, id);
}

export fn js_gl_deleteFramebuffer(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) return c.JS_EXCEPTION;
    if (freeFramebufferId(raw) and g_bound_framebuffer == raw) {
        g_bound_framebuffer = 0;
    }
    return c.JS_UNDEFINED;
}

export fn js_gl_bindFramebuffer(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) return c.JS_UNDEFINED;
    var target: u32 = 0;
    if (c.JS_ToUint32(ctx, &target, argv[0]) != 0) return c.JS_EXCEPTION;
    if (target != GL_FRAMEBUFFER) return c.JS_UNDEFINED;
    var raw: u32 = 0;
    if (argv[1] != c.JS_NULL and argv[1] != c.JS_UNDEFINED) {
        if (c.JS_ToUint32(ctx, &raw, argv[1]) != 0) return c.JS_EXCEPTION;
    }
    if (raw != 0 and !isFramebufferId(raw)) {
        return throwTypeError(ctx, "invalid framebuffer handle");
    }
    g_bound_framebuffer = raw;
    return c.JS_UNDEFINED;
}

export fn js_gl_framebufferTexture2D(_: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    return c.JS_UNDEFINED;
}

export fn js_gl_checkFramebufferStatus(ctx: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    return c.JS_NewUint32(ctx, GL_FRAMEBUFFER_COMPLETE);
}

export fn js_gl_createRenderbuffer(ctx: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    const id = allocRenderbufferId() orelse return c.JS_NULL;
    return c.JS_NewUint32(ctx, id);
}

export fn js_gl_deleteRenderbuffer(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) return c.JS_EXCEPTION;
    if (freeRenderbufferId(raw) and g_bound_renderbuffer == raw) {
        g_bound_renderbuffer = 0;
    }
    return c.JS_UNDEFINED;
}

export fn js_gl_bindRenderbuffer(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) return c.JS_UNDEFINED;
    var target: u32 = 0;
    if (c.JS_ToUint32(ctx, &target, argv[0]) != 0) return c.JS_EXCEPTION;
    if (target != GL_RENDERBUFFER) return c.JS_UNDEFINED;
    var raw: u32 = 0;
    if (argv[1] != c.JS_NULL and argv[1] != c.JS_UNDEFINED) {
        if (c.JS_ToUint32(ctx, &raw, argv[1]) != 0) return c.JS_EXCEPTION;
    }
    if (raw != 0 and !isRenderbufferId(raw)) {
        return throwTypeError(ctx, "invalid renderbuffer handle");
    }
    g_bound_renderbuffer = raw;
    return c.JS_UNDEFINED;
}

export fn js_gl_renderbufferStorage(_: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    return c.JS_UNDEFINED;
}

export fn js_gl_framebufferRenderbuffer(_: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    return c.JS_UNDEFINED;
}

export fn js_gl_createVertexArray(ctx: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    const id = allocVaoId() orelse return c.JS_NULL;
    return c.JS_NewUint32(ctx, id);
}

export fn js_gl_deleteVertexArray(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) return c.JS_EXCEPTION;
    if (freeVaoId(raw) and g_bound_vao == raw) {
        g_bound_vao = 0;
    }
    return c.JS_UNDEFINED;
}

export fn js_gl_bindVertexArray(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    var raw: u32 = 0;
    if (argv[0] != c.JS_NULL and argv[0] != c.JS_UNDEFINED) {
        if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) return c.JS_EXCEPTION;
    }
    if (raw != 0 and !isVaoId(raw)) {
        return throwTypeError(ctx, "invalid vertex array handle");
    }
    g_bound_vao = raw;
    return c.JS_UNDEFINED;
}

export fn js_gl_enable(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    var cap: u32 = 0;
    if (c.JS_ToUint32(ctx, &cap, argv[0]) != 0) return c.JS_EXCEPTION;
    setEnableState(cap, true);
    switch (cap) {
        GL_SCISSOR_TEST => webgl_draw.setScissorEnabled(true),
        GL_DEPTH_TEST => webgl_draw.setDepthTestEnabled(true),
        GL_STENCIL_TEST => webgl_draw.setStencilEnabled(true),
        GL_CULL_FACE => webgl_draw.setCullEnabled(true),
        GL_BLEND => webgl_draw.setBlendEnabled(true),
        GL_POLYGON_OFFSET_FILL => webgl_draw.setPolygonOffsetEnabled(true),
        GL_SAMPLE_ALPHA_TO_COVERAGE => webgl_draw.setAlphaToCoverageEnabled(true),
        else => {},
    }
    return c.JS_UNDEFINED;
}

export fn js_gl_disable(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    var cap: u32 = 0;
    if (c.JS_ToUint32(ctx, &cap, argv[0]) != 0) return c.JS_EXCEPTION;
    setEnableState(cap, false);
    switch (cap) {
        GL_SCISSOR_TEST => webgl_draw.setScissorEnabled(false),
        GL_DEPTH_TEST => webgl_draw.setDepthTestEnabled(false),
        GL_STENCIL_TEST => webgl_draw.setStencilEnabled(false),
        GL_CULL_FACE => webgl_draw.setCullEnabled(false),
        GL_BLEND => webgl_draw.setBlendEnabled(false),
        GL_POLYGON_OFFSET_FILL => webgl_draw.setPolygonOffsetEnabled(false),
        GL_SAMPLE_ALPHA_TO_COVERAGE => webgl_draw.setAlphaToCoverageEnabled(false),
        else => {},
    }
    return c.JS_UNDEFINED;
}

export fn js_gl_viewport(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 4) return c.JS_UNDEFINED;
    var x: i32 = 0;
    var y: i32 = 0;
    var w: i32 = 0;
    var h: i32 = 0;
    _ = c.JS_ToInt32(ctx, &x, argv[0]);
    _ = c.JS_ToInt32(ctx, &y, argv[1]);
    _ = c.JS_ToInt32(ctx, &w, argv[2]);
    _ = c.JS_ToInt32(ctx, &h, argv[3]);
    g_gl_state.viewport = .{ x, y, w, h };
    webgl_draw.setViewport(x, y, w, h);
    return c.JS_UNDEFINED;
}

export fn js_gl_clearColor(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 4) return c.JS_UNDEFINED;
    var r: f64 = 0;
    var g: f64 = 0;
    var b: f64 = 0;
    var a: f64 = 0;
    _ = c.JS_ToNumber(ctx, &r, argv[0]);
    _ = c.JS_ToNumber(ctx, &g, argv[1]);
    _ = c.JS_ToNumber(ctx, &b, argv[2]);
    _ = c.JS_ToNumber(ctx, &a, argv[3]);
    g_gl_state.clear_color = .{ @floatCast(r), @floatCast(g), @floatCast(b), @floatCast(a) };
    webgl_draw.setClearColor(@floatCast(r), @floatCast(g), @floatCast(b), @floatCast(a));
    if (getRuntime(ctx)) |rt| {
        rt.shared.clear_color = .{ @floatCast(r), @floatCast(g), @floatCast(b) };
    }
    return c.JS_UNDEFINED;
}

export fn js_gl_clear(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    var mask: u32 = 0;
    _ = c.JS_ToUint32(ctx, &mask, argv[0]);
    webgl_draw.requestClear(mask);
    return c.JS_UNDEFINED;
}

export fn js_gl_clearDepth(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    var val: f64 = 1.0;
    _ = c.JS_ToNumber(ctx, &val, argv[0]);
    g_gl_state.clear_depth = @floatCast(val);
    webgl_draw.setClearDepth(@floatCast(val));
    return c.JS_UNDEFINED;
}

export fn js_gl_clearStencil(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    var val: i32 = 0;
    _ = c.JS_ToInt32(ctx, &val, argv[0]);
    g_gl_state.clear_stencil = val;
    webgl_draw.setClearStencil(val);
    return c.JS_UNDEFINED;
}

export fn js_gl_depthFunc(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    var val: u32 = 0;
    _ = c.JS_ToUint32(ctx, &val, argv[0]);
    g_gl_state.depth_func = val;
    webgl_draw.setDepthFunc(val);
    return c.JS_UNDEFINED;
}

export fn js_gl_depthMask(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    var val: i32 = 0;
    _ = c.JS_ToInt32(ctx, &val, argv[0]);
    g_gl_state.depth_mask = val != 0;
    webgl_draw.setDepthMask(val != 0);
    return c.JS_UNDEFINED;
}

export fn js_gl_colorMask(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 4) return c.JS_UNDEFINED;
    var r: i32 = 0;
    var g: i32 = 0;
    var b: i32 = 0;
    var a: i32 = 0;
    _ = c.JS_ToInt32(ctx, &r, argv[0]);
    _ = c.JS_ToInt32(ctx, &g, argv[1]);
    _ = c.JS_ToInt32(ctx, &b, argv[2]);
    _ = c.JS_ToInt32(ctx, &a, argv[3]);
    g_gl_state.color_mask = .{ r != 0, g != 0, b != 0, a != 0 };
    webgl_draw.setColorMask(r != 0, g != 0, b != 0, a != 0);
    return c.JS_UNDEFINED;
}

export fn js_gl_cullFace(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    var val: u32 = 0;
    _ = c.JS_ToUint32(ctx, &val, argv[0]);
    g_gl_state.cull_face = val;
    webgl_draw.setCullFace(val);
    return c.JS_UNDEFINED;
}

export fn js_gl_frontFace(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    var val: u32 = 0;
    _ = c.JS_ToUint32(ctx, &val, argv[0]);
    g_gl_state.front_face = val;
    webgl_draw.setFrontFace(val);
    return c.JS_UNDEFINED;
}

export fn js_gl_blendFunc(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) return c.JS_UNDEFINED;
    var src: u32 = 0;
    var dst: u32 = 0;
    _ = c.JS_ToUint32(ctx, &src, argv[0]);
    _ = c.JS_ToUint32(ctx, &dst, argv[1]);
    g_gl_state.blend_src = src;
    g_gl_state.blend_dst = dst;
    g_gl_state.blend_src_alpha = src;
    g_gl_state.blend_dst_alpha = dst;
    webgl_draw.setBlendFunc(src, dst);
    return c.JS_UNDEFINED;
}

export fn js_gl_blendFuncSeparate(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 4) return c.JS_UNDEFINED;
    var src: u32 = 0;
    var dst: u32 = 0;
    var src_a: u32 = 0;
    var dst_a: u32 = 0;
    _ = c.JS_ToUint32(ctx, &src, argv[0]);
    _ = c.JS_ToUint32(ctx, &dst, argv[1]);
    _ = c.JS_ToUint32(ctx, &src_a, argv[2]);
    _ = c.JS_ToUint32(ctx, &dst_a, argv[3]);
    g_gl_state.blend_src = src;
    g_gl_state.blend_dst = dst;
    g_gl_state.blend_src_alpha = src_a;
    g_gl_state.blend_dst_alpha = dst_a;
    webgl_draw.setBlendFuncSeparate(src, dst, src_a, dst_a);
    return c.JS_UNDEFINED;
}

export fn js_gl_blendEquation(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    var eq: u32 = 0;
    _ = c.JS_ToUint32(ctx, &eq, argv[0]);
    g_gl_state.blend_eq = eq;
    g_gl_state.blend_eq_alpha = eq;
    webgl_draw.setBlendEquation(eq);
    return c.JS_UNDEFINED;
}

export fn js_gl_blendEquationSeparate(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) return c.JS_UNDEFINED;
    var eq: u32 = 0;
    var eq_a: u32 = 0;
    _ = c.JS_ToUint32(ctx, &eq, argv[0]);
    _ = c.JS_ToUint32(ctx, &eq_a, argv[1]);
    g_gl_state.blend_eq = eq;
    g_gl_state.blend_eq_alpha = eq_a;
    webgl_draw.setBlendEquationSeparate(eq, eq_a);
    return c.JS_UNDEFINED;
}

export fn js_gl_scissor(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 4) return c.JS_UNDEFINED;
    var x: i32 = 0;
    var y: i32 = 0;
    var w: i32 = 0;
    var h: i32 = 0;
    _ = c.JS_ToInt32(ctx, &x, argv[0]);
    _ = c.JS_ToInt32(ctx, &y, argv[1]);
    _ = c.JS_ToInt32(ctx, &w, argv[2]);
    _ = c.JS_ToInt32(ctx, &h, argv[3]);
    g_gl_state.scissor = .{ x, y, w, h };
    webgl_draw.setScissor(x, y, w, h);
    return c.JS_UNDEFINED;
}

export fn js_gl_lineWidth(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    var val: f64 = 1.0;
    _ = c.JS_ToNumber(ctx, &val, argv[0]);
    g_gl_state.line_width = @floatCast(val);
    return c.JS_UNDEFINED;
}

export fn js_gl_polygonOffset(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) return c.JS_UNDEFINED;
    var factor: f64 = 0;
    var units: f64 = 0;
    _ = c.JS_ToNumber(ctx, &factor, argv[0]);
    _ = c.JS_ToNumber(ctx, &units, argv[1]);
    g_gl_state.polygon_offset = .{ @floatCast(factor), @floatCast(units) };
    webgl_draw.setPolygonOffset(@floatCast(factor), @floatCast(units));
    return c.JS_UNDEFINED;
}

export fn js_gl_pixelStorei(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) return c.JS_UNDEFINED;
    var pname: u32 = 0;
    var param: i32 = 0;
    _ = c.JS_ToUint32(ctx, &pname, argv[0]);
    _ = c.JS_ToInt32(ctx, &param, argv[1]);
    switch (pname) {
        GL_UNPACK_ALIGNMENT => g_gl_state.unpack_alignment = param,
        GL_UNPACK_ROW_LENGTH => g_gl_state.unpack_row_length = param,
        GL_UNPACK_SKIP_PIXELS => g_gl_state.unpack_skip_pixels = param,
        GL_UNPACK_SKIP_ROWS => g_gl_state.unpack_skip_rows = param,
        GL_UNPACK_FLIP_Y_WEBGL => g_gl_state.unpack_flip_y = param != 0,
        GL_UNPACK_PREMULTIPLY_ALPHA_WEBGL => g_gl_state.unpack_premultiply_alpha = param != 0,
        GL_UNPACK_COLORSPACE_CONVERSION_WEBGL => g_gl_state.unpack_colorspace_conversion = param,
        else => {},
    }
    return c.JS_UNDEFINED;
}

export fn js_gl_getError(ctx: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    return c.JS_NewInt32(ctx, @intCast(GL_NO_ERROR));
}

export fn js_gl_getShaderPrecisionFormat(ctx: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "rangeMin", c.JS_NewInt32(ctx, 127));
    _ = c.JS_SetPropertyStr(ctx, obj, "rangeMax", c.JS_NewInt32(ctx, 127));
    _ = c.JS_SetPropertyStr(ctx, obj, "precision", c.JS_NewInt32(ctx, 23));
    return obj;
}

export fn js_gl_createBuffer(ctx: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    const mgr = webgl_state.globalBufferManager();
    const id = mgr.createBuffer(.{ .usage = .vertex }) catch {
        return throwInternalError(ctx, "createBuffer failed");
    };
    return c.JS_NewUint32(ctx, bufferIdToU32(id));
}

export fn js_gl_deleteBuffer(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    if (argv[0] == c.JS_NULL or argv[0] == c.JS_UNDEFINED) {
        return c.JS_UNDEFINED;
    }
    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    const mgr = webgl_state.globalBufferManager();
    _ = mgr.deleteBuffer(bufferIdFromU32(raw));
    return c.JS_UNDEFINED;
}

export fn js_gl_bindBuffer(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) {
        return throwTypeError(ctx, "bindBuffer requires (target, buffer)");
    }
    var target_raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &target_raw, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    const target = parseBufferTarget(target_raw) catch {
        return throwTypeError(ctx, "invalid buffer target");
    };

    const mgr = webgl_state.globalBufferManager();
    if (argv[1] == c.JS_NULL or argv[1] == c.JS_UNDEFINED) {
        mgr.unbindBuffer(target);
        return c.JS_UNDEFINED;
    }

    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[1]) != 0) {
        return c.JS_EXCEPTION;
    }
    mgr.bindBuffer(target, bufferIdFromU32(raw)) catch {
        return throwTypeError(ctx, "invalid buffer handle");
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_bufferData(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) {
        return throwTypeError(ctx, "bufferData requires (target, size)");
    }
    var target_raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &target_raw, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    const target = parseBufferTarget(target_raw) catch {
        return throwTypeError(ctx, "invalid buffer target");
    };

    const mgr = webgl_state.globalBufferManager();
    var c_ptr: [*c]u8 = null;
    var len: usize = 0;

    if (c.JS_GetTypedArrayData(ctx, argv[1], &c_ptr, &len) == 0) {
        const data = @as([*]u8, @ptrCast(c_ptr))[0..len];
        mgr.bufferData(target, data) catch {
            return throwTypeError(ctx, "bufferData failed");
        };
        return c.JS_UNDEFINED;
    }
    if (c.JS_GetArrayBufferData(ctx, argv[1], &c_ptr, &len) == 0) {
        const data = @as([*]u8, @ptrCast(c_ptr))[0..len];
        mgr.bufferData(target, data) catch {
            return throwTypeError(ctx, "bufferData failed");
        };
        return c.JS_UNDEFINED;
    }

    var size: u32 = 0;
    if (c.JS_ToUint32(ctx, &size, argv[1]) != 0) {
        return c.JS_EXCEPTION;
    }
    if (size > webgl.MaxBufferBytes) {
        return throwTypeError(ctx, "bufferData too large");
    }

    if (size == 0) {
        mgr.bufferData(target, &.{}) catch {
            return throwTypeError(ctx, "bufferData failed");
        };
        return c.JS_UNDEFINED;
    }

    const data = std.heap.page_allocator.alloc(u8, size) catch {
        return throwInternalError(ctx, "out of memory");
    };
    defer std.heap.page_allocator.free(data);
    @memset(data, 0);

    mgr.bufferData(target, data) catch {
        return throwTypeError(ctx, "bufferData failed");
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_createShader(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) {
        return throwTypeError(ctx, "createShader requires a type");
    }
    var kind_raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &kind_raw, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    const kind = parseShaderKind(kind_raw) catch {
        return throwTypeError(ctx, "invalid shader type");
    };
    const table = webgl_shader.globalShaderTable();
    const id = table.alloc(kind) catch {
        return throwInternalError(ctx, "createShader failed");
    };
    return c.JS_NewUint32(ctx, shaderIdToU32(id));
}

export fn js_gl_deleteShader(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    if (argv[0] == c.JS_NULL or argv[0] == c.JS_UNDEFINED) {
        return c.JS_UNDEFINED;
    }
    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    const table = webgl_shader.globalShaderTable();
    _ = table.free(shaderIdFromU32(raw));
    return c.JS_UNDEFINED;
}

export fn js_gl_shaderSource(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) {
        return throwTypeError(ctx, "shaderSource requires (shader, source)");
    }
    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    if (c.JS_IsString(ctx, argv[1]) == 0) {
        return throwTypeError(ctx, "shaderSource requires a string");
    }
    var len: usize = 0;
    var buf: c.JSCStringBuf = undefined;
    const c_str = c.JS_ToCStringLen(ctx, &len, argv[1], &buf);
    if (c_str == null) {
        return c.JS_EXCEPTION;
    }
    const slice: [*]const u8 = @ptrCast(c_str);
    const table = webgl_shader.globalShaderTable();
    table.setSource(shaderIdFromU32(raw), slice[0..len]) catch |err| switch (err) {
        error.InvalidHandle => return throwTypeError(ctx, "invalid shader handle"),
        error.TooLarge => return throwTypeError(ctx, "shaderSource too large"),
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_compileShader(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) {
        return throwTypeError(ctx, "compileShader requires a shader");
    }
    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    const table = webgl_shader.globalShaderTable();
    table.compile(shaderIdFromU32(raw)) catch |err| switch (err) {
        error.InvalidHandle => return throwTypeError(ctx, "invalid shader handle"),
        else => return throwInternalError(ctx, "compileShader failed"),
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_getShaderParameter(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) {
        return throwTypeError(ctx, "getShaderParameter requires (shader, pname)");
    }
    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    var pname: u32 = 0;
    if (c.JS_ToUint32(ctx, &pname, argv[1]) != 0) {
        return c.JS_EXCEPTION;
    }
    if (pname != GL_COMPILE_STATUS) {
        return throwTypeError(ctx, "invalid shader parameter");
    }
    const table = webgl_shader.globalShaderTable();
    const sh = table.get(shaderIdFromU32(raw)) orelse {
        return throwTypeError(ctx, "invalid shader handle");
    };
    return if (sh.compiled) c.JS_TRUE else c.JS_FALSE;
}

export fn js_gl_getShaderInfoLog(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) {
        return throwTypeError(ctx, "getShaderInfoLog requires a shader");
    }
    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    const table = webgl_shader.globalShaderTable();
    _ = table.get(shaderIdFromU32(raw)) orelse {
        return throwTypeError(ctx, "invalid shader handle");
    };
    if (table.getInfoLog(shaderIdFromU32(raw))) |log| {
        return c.JS_NewStringLen(ctx, @ptrCast(log.ptr), log.len);
    }
    return c.JS_NewStringLen(ctx, "", 0);
}

export fn js_gl_createProgram(ctx: *c.JSContext, _: *c.JSValue, _: c_int, _: [*]c.JSValue) callconv(.c) c.JSValue {
    const table = webgl_program.globalProgramTable();
    const id = table.alloc() catch {
        return throwInternalError(ctx, "createProgram failed");
    };
    return c.JS_NewUint32(ctx, programIdToU32(id));
}

export fn js_gl_deleteProgram(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    if (argv[0] == c.JS_NULL or argv[0] == c.JS_UNDEFINED) {
        return c.JS_UNDEFINED;
    }
    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    const table = webgl_program.globalProgramTable();
    _ = table.free(programIdFromU32(raw));
    return c.JS_UNDEFINED;
}

export fn js_gl_attachShader(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) {
        return throwTypeError(ctx, "attachShader requires (program, shader)");
    }
    var program_raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &program_raw, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    var shader_raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &shader_raw, argv[1]) != 0) {
        return c.JS_EXCEPTION;
    }
    const programs = webgl_program.globalProgramTable();
    const shaders = webgl_shader.globalShaderTable();
    programs.attachShader(programIdFromU32(program_raw), shaderIdFromU32(shader_raw), shaders) catch |err| switch (err) {
        error.InvalidHandle => return throwTypeError(ctx, "invalid program handle"),
        error.InvalidShader => return throwTypeError(ctx, "invalid shader handle"),
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_linkProgram(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) {
        return throwTypeError(ctx, "linkProgram requires a program");
    }
    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    const programs = webgl_program.globalProgramTable();
    const shaders = webgl_shader.globalShaderTable();
    programs.link(programIdFromU32(raw), shaders) catch |err| switch (err) {
        error.InvalidHandle => return throwTypeError(ctx, "invalid program handle"),
        else => return throwInternalError(ctx, "linkProgram failed"),
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_getProgramParameter(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) {
        return throwTypeError(ctx, "getProgramParameter requires (program, pname)");
    }
    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    var pname: u32 = 0;
    if (c.JS_ToUint32(ctx, &pname, argv[1]) != 0) {
        return c.JS_EXCEPTION;
    }
    const programs = webgl_program.globalProgramTable();
    const prog = programs.get(programIdFromU32(raw)) orelse {
        return throwTypeError(ctx, "invalid program handle");
    };
    switch (pname) {
        GL_LINK_STATUS => return if (prog.linked) c.JS_TRUE else c.JS_FALSE,
        GL_VALIDATE_STATUS => return c.JS_TRUE,
        GL_ACTIVE_ATTRIBUTES => return c.JS_NewUint32(ctx, prog.attr_count),
        GL_ACTIVE_UNIFORMS => {
            const uniform_count: u32 = prog.countUniformUnion();
            const total: u32 = uniform_count + prog.sampler_count;
            return c.JS_NewUint32(ctx, total);
        },
        GL_ATTACHED_SHADERS => {
            var count: u32 = 0;
            if (prog.vertex_shader != null) count += 1;
            if (prog.fragment_shader != null) count += 1;
            return c.JS_NewUint32(ctx, count);
        },
        else => return c.JS_NULL,
    }
}

export fn js_gl_getProgramInfoLog(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) {
        return throwTypeError(ctx, "getProgramInfoLog requires a program");
    }
    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    const programs = webgl_program.globalProgramTable();
    const prog = programs.get(programIdFromU32(raw)) orelse {
        return throwTypeError(ctx, "invalid program handle");
    };
    if (prog.info_log_len > 0) {
        const len: usize = @intCast(prog.info_log_len);
        return c.JS_NewStringLen(ctx, @ptrCast(prog.info_log_bytes[0..].ptr), len);
    }
    return c.JS_NewStringLen(ctx, "", 0);
}

export fn js_gl_useProgram(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) {
        return throwTypeError(ctx, "useProgram requires a program");
    }
    if (argv[0] == c.JS_NULL or argv[0] == c.JS_UNDEFINED) {
        webgl_draw.clearProgram();
        return c.JS_UNDEFINED;
    }
    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    webgl_draw.useProgram(programIdFromU32(raw)) catch {
        return throwTypeError(ctx, "invalid program handle");
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_getAttribLocation(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) {
        return throwTypeError(ctx, "getAttribLocation requires (program, name)");
    }
    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    if (c.JS_IsString(ctx, argv[1]) == 0) {
        return throwTypeError(ctx, "getAttribLocation requires a string");
    }
    var len: usize = 0;
    var buf: c.JSCStringBuf = undefined;
    const c_str = c.JS_ToCStringLen(ctx, &len, argv[1], &buf);
    if (c_str == null) {
        return c.JS_EXCEPTION;
    }
    const slice: [*]const u8 = @ptrCast(c_str);
    const loc = webgl_draw.getAttribLocation(programIdFromU32(raw), slice[0..len]) catch {
        return throwTypeError(ctx, "invalid program handle");
    };
    return c.JS_NewInt32(ctx, @intCast(loc));
}

export fn js_gl_getActiveAttrib(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) {
        return throwTypeError(ctx, "getActiveAttrib requires (program, index)");
    }
    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    var index: u32 = 0;
    if (c.JS_ToUint32(ctx, &index, argv[1]) != 0) {
        return c.JS_EXCEPTION;
    }
    const programs = webgl_program.globalProgramTable();
    const prog = programs.get(programIdFromU32(raw)) orelse {
        return throwTypeError(ctx, "invalid program handle");
    };
    if (index >= prog.attr_count) {
        return c.JS_NULL;
    }
    const idx: usize = @intCast(index);
    const name_len: usize = @intCast(prog.attr_name_lens[idx]);
    if (name_len == 0) return c.JS_NULL;
    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "name", c.JS_NewStringLen(ctx, prog.attr_names[idx][0..name_len].ptr, name_len));
    _ = c.JS_SetPropertyStr(ctx, obj, "size", c.JS_NewInt32(ctx, 1));
    _ = c.JS_SetPropertyStr(ctx, obj, "type", c.JS_NewUint32(ctx, GL_FLOAT));
    return obj;
}

export fn js_gl_getActiveUniform(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) {
        return throwTypeError(ctx, "getActiveUniform requires (program, index)");
    }
    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    var index: u32 = 0;
    if (c.JS_ToUint32(ctx, &index, argv[1]) != 0) {
        return c.JS_EXCEPTION;
    }
    const programs = webgl_program.globalProgramTable();
    const prog = programs.get(programIdFromU32(raw)) orelse {
        return throwTypeError(ctx, "invalid program handle");
    };
    const uniform_count: u32 = prog.countUniformUnion();
    const sampler_count: u32 = prog.sampler_count;
    const total: u32 = uniform_count + sampler_count;
    if (index >= total) return c.JS_NULL;
    var name_buf: [webgl_program.MaxUniformNameBytes + 3]u8 = undefined;
    var name_len: usize = 0;
    var size: u32 = 1;
    var utype: u32 = GL_FLOAT;
    if (index < uniform_count) {
        const u = prog.getUniformAtUnionIndex(index) orelse return c.JS_NULL;
        name_len = @intCast(u.name_len);
        if (name_len == 0) return c.JS_NULL;
        @memcpy(name_buf[0..name_len], u.name_bytes[0..name_len]);
        size = if (u.array_count == 0) 1 else u.array_count;
        if (size > 1 and name_len + 3 <= name_buf.len) {
            name_buf[name_len] = '[';
            name_buf[name_len + 1] = '0';
            name_buf[name_len + 2] = ']';
            name_len += 3;
        }
        utype = uniformTypeToGlEnum(u.utype);
    } else {
        const s_idx: usize = @intCast(index - uniform_count);
        if (s_idx >= sampler_count) return c.JS_NULL;
        const s = prog.samplers[s_idx];
        name_len = @intCast(s.name_len);
        if (name_len == 0) return c.JS_NULL;
        @memcpy(name_buf[0..name_len], s.name_bytes[0..name_len]);
        size = if (s.array_count == 0) 1 else s.array_count;
        if (size > 1 and name_len + 3 <= name_buf.len) {
            name_buf[name_len] = '[';
            name_buf[name_len + 1] = '0';
            name_buf[name_len + 2] = ']';
            name_len += 3;
        }
        utype = samplerKindToGlEnum(@intFromEnum(s.kind));
    }
    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "name", c.JS_NewStringLen(ctx, name_buf[0..name_len].ptr, name_len));
    _ = c.JS_SetPropertyStr(ctx, obj, "size", c.JS_NewUint32(ctx, size));
    _ = c.JS_SetPropertyStr(ctx, obj, "type", c.JS_NewUint32(ctx, utype));
    return obj;
}

export fn js_gl_enableVertexAttribArray(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) {
        return throwTypeError(ctx, "enableVertexAttribArray requires an index");
    }
    var idx: u32 = 0;
    if (c.JS_ToUint32(ctx, &idx, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    webgl_draw.enableVertexAttribArray(idx) catch {
        return throwTypeError(ctx, "invalid attrib index");
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_disableVertexAttribArray(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 1) {
        return throwTypeError(ctx, "disableVertexAttribArray requires an index");
    }
    var idx: u32 = 0;
    if (c.JS_ToUint32(ctx, &idx, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    webgl_draw.disableVertexAttribArray(idx) catch {
        return throwTypeError(ctx, "invalid attrib index");
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_vertexAttribPointer(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 6) {
        return throwTypeError(ctx, "vertexAttribPointer requires 6 arguments");
    }
    var idx: u32 = 0;
    if (c.JS_ToUint32(ctx, &idx, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    var size_i: c_int = 0;
    if (c.JS_ToInt32(ctx, &size_i, argv[1]) != 0) {
        return c.JS_EXCEPTION;
    }
    var type_raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &type_raw, argv[2]) != 0) {
        return c.JS_EXCEPTION;
    }
    var normalized_i: c_int = 0;
    if (c.JS_ToInt32(ctx, &normalized_i, argv[3]) != 0) {
        return c.JS_EXCEPTION;
    }
    var stride_i: c_int = 0;
    if (c.JS_ToInt32(ctx, &stride_i, argv[4]) != 0) {
        return c.JS_EXCEPTION;
    }
    var offset_i: c_int = 0;
    if (c.JS_ToInt32(ctx, &offset_i, argv[5]) != 0) {
        return c.JS_EXCEPTION;
    }
    if (size_i <= 0 or stride_i < 0 or offset_i < 0) {
        return throwTypeError(ctx, "vertexAttribPointer invalid arguments");
    }
    const mgr = webgl_state.globalBufferManager();
    const buffer = mgr.getBoundBuffer(.array) orelse {
        return throwTypeError(ctx, "no array buffer bound");
    };
    webgl_draw.vertexAttribPointer(
        idx,
        @intCast(size_i),
        type_raw,
        normalized_i != 0,
        @intCast(stride_i),
        @intCast(offset_i),
        buffer,
    ) catch {
        return throwTypeError(ctx, "vertexAttribPointer failed");
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_drawArrays(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 3) {
        return throwTypeError(ctx, "drawArrays requires (mode, first, count)");
    }
    var mode: u32 = 0;
    if (c.JS_ToUint32(ctx, &mode, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    var first: c_int = 0;
    if (c.JS_ToInt32(ctx, &first, argv[1]) != 0) {
        return c.JS_EXCEPTION;
    }
    var count: c_int = 0;
    if (c.JS_ToInt32(ctx, &count, argv[2]) != 0) {
        return c.JS_EXCEPTION;
    }
    webgl_draw.drawArrays(mode, first, count) catch {
        return throwTypeError(ctx, "drawArrays failed");
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_drawElements(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 4) {
        return throwTypeError(ctx, "drawElements requires (mode, count, type, offset)");
    }
    var mode: u32 = 0;
    if (c.JS_ToUint32(ctx, &mode, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    var count: c_int = 0;
    if (c.JS_ToInt32(ctx, &count, argv[1]) != 0) {
        return c.JS_EXCEPTION;
    }
    var type_raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &type_raw, argv[2]) != 0) {
        return c.JS_EXCEPTION;
    }
    var offset: c_int = 0;
    if (c.JS_ToInt32(ctx, &offset, argv[3]) != 0) {
        return c.JS_EXCEPTION;
    }
    if (offset < 0) {
        return throwTypeError(ctx, "drawElements invalid offset");
    }
    const mgr = webgl_state.globalBufferManager();
    const element = mgr.getBoundBuffer(.element_array) orelse {
        return throwTypeError(ctx, "no element array buffer bound");
    };
    webgl_draw.drawElements(mode, count, type_raw, @intCast(offset), element) catch {
        return throwTypeError(ctx, "drawElements failed");
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_getUniformLocation(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) {
        return throwTypeError(ctx, "getUniformLocation requires (program, name)");
    }
    var raw: u32 = 0;
    if (c.JS_ToUint32(ctx, &raw, argv[0]) != 0) {
        return c.JS_EXCEPTION;
    }
    if (c.JS_IsString(ctx, argv[1]) == 0) {
        return throwTypeError(ctx, "getUniformLocation requires a string");
    }
    var len: usize = 0;
    var buf: c.JSCStringBuf = undefined;
    const c_str = c.JS_ToCStringLen(ctx, &len, argv[1], &buf);
    if (c_str == null) {
        return c.JS_EXCEPTION;
    }
    const slice: [*]const u8 = @ptrCast(c_str);
    const programs = webgl_program.globalProgramTable();
    const loc = programs.getUniformLocation(programIdFromU32(raw), slice[0..len]) catch {
        return throwTypeError(ctx, "invalid program handle");
    };
    return c.JS_NewInt32(ctx, @intCast(loc));
}

export fn js_gl_uniform1f(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) return throwTypeError(ctx, "uniform1f requires (location, x)");
    const loc = (readUniformLocation(ctx, argv[0]) catch return c.JS_EXCEPTION) orelse return c.JS_UNDEFINED;
    const prog = webgl_draw.currentProgram() orelse {
        return throwTypeError(ctx, "no program in use");
    };
    var x: f64 = 0;
    if (c.JS_ToNumber(ctx, &x, argv[1]) != 0) return c.JS_EXCEPTION;
    const values = [_]f32{@floatCast(x)};
    webgl_program.globalProgramTable().setUniformFloats(prog, loc, values[0..]) catch {
        return c.JS_UNDEFINED;
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_uniform2f(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 3) return throwTypeError(ctx, "uniform2f requires (location, x, y)");
    const loc = (readUniformLocation(ctx, argv[0]) catch return c.JS_EXCEPTION) orelse return c.JS_UNDEFINED;
    const prog = webgl_draw.currentProgram() orelse return throwTypeError(ctx, "no program in use");
    var x: f64 = 0;
    var y: f64 = 0;
    if (c.JS_ToNumber(ctx, &x, argv[1]) != 0) return c.JS_EXCEPTION;
    if (c.JS_ToNumber(ctx, &y, argv[2]) != 0) return c.JS_EXCEPTION;
    const values = [_]f32{ @floatCast(x), @floatCast(y) };
    webgl_program.globalProgramTable().setUniformFloats(prog, loc, values[0..]) catch {
        return c.JS_UNDEFINED;
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_uniform3f(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 4) return throwTypeError(ctx, "uniform3f requires (location, x, y, z)");
    const loc = (readUniformLocation(ctx, argv[0]) catch return c.JS_EXCEPTION) orelse return c.JS_UNDEFINED;
    const prog = webgl_draw.currentProgram() orelse return throwTypeError(ctx, "no program in use");
    var x: f64 = 0;
    var y: f64 = 0;
    var z: f64 = 0;
    if (c.JS_ToNumber(ctx, &x, argv[1]) != 0) return c.JS_EXCEPTION;
    if (c.JS_ToNumber(ctx, &y, argv[2]) != 0) return c.JS_EXCEPTION;
    if (c.JS_ToNumber(ctx, &z, argv[3]) != 0) return c.JS_EXCEPTION;
    const values = [_]f32{ @floatCast(x), @floatCast(y), @floatCast(z) };
    webgl_program.globalProgramTable().setUniformFloats(prog, loc, values[0..]) catch {
        return c.JS_UNDEFINED;
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_uniform4f(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 5) return throwTypeError(ctx, "uniform4f requires (location, x, y, z, w)");
    const loc = (readUniformLocation(ctx, argv[0]) catch return c.JS_EXCEPTION) orelse return c.JS_UNDEFINED;
    const prog = webgl_draw.currentProgram() orelse return throwTypeError(ctx, "no program in use");
    var x: f64 = 0;
    var y: f64 = 0;
    var z: f64 = 0;
    var w: f64 = 0;
    if (c.JS_ToNumber(ctx, &x, argv[1]) != 0) return c.JS_EXCEPTION;
    if (c.JS_ToNumber(ctx, &y, argv[2]) != 0) return c.JS_EXCEPTION;
    if (c.JS_ToNumber(ctx, &z, argv[3]) != 0) return c.JS_EXCEPTION;
    if (c.JS_ToNumber(ctx, &w, argv[4]) != 0) return c.JS_EXCEPTION;
    const values = [_]f32{ @floatCast(x), @floatCast(y), @floatCast(z), @floatCast(w) };
    webgl_program.globalProgramTable().setUniformFloats(prog, loc, values[0..]) catch {
        return c.JS_UNDEFINED;
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_uniform1i(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) return throwTypeError(ctx, "uniform1i requires (location, x)");
    const loc = (readUniformLocation(ctx, argv[0]) catch return c.JS_EXCEPTION) orelse return c.JS_UNDEFINED;
    const prog = webgl_draw.currentProgram() orelse return throwTypeError(ctx, "no program in use");
    var x: c_int = 0;
    if (c.JS_ToInt32(ctx, &x, argv[1]) != 0) return c.JS_EXCEPTION;
    const values = [_]i32{@intCast(x)};
    webgl_program.globalProgramTable().setUniformInts(prog, loc, values[0..]) catch {
        return c.JS_UNDEFINED;
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_uniform2i(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 3) return throwTypeError(ctx, "uniform2i requires (location, x, y)");
    const loc = (readUniformLocation(ctx, argv[0]) catch return c.JS_EXCEPTION) orelse return c.JS_UNDEFINED;
    const prog = webgl_draw.currentProgram() orelse return throwTypeError(ctx, "no program in use");
    var x: c_int = 0;
    var y: c_int = 0;
    if (c.JS_ToInt32(ctx, &x, argv[1]) != 0) return c.JS_EXCEPTION;
    if (c.JS_ToInt32(ctx, &y, argv[2]) != 0) return c.JS_EXCEPTION;
    const values = [_]i32{ @intCast(x), @intCast(y) };
    webgl_program.globalProgramTable().setUniformInts(prog, loc, values[0..]) catch {
        return c.JS_UNDEFINED;
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_uniform3i(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 4) return throwTypeError(ctx, "uniform3i requires (location, x, y, z)");
    const loc = (readUniformLocation(ctx, argv[0]) catch return c.JS_EXCEPTION) orelse return c.JS_UNDEFINED;
    const prog = webgl_draw.currentProgram() orelse return throwTypeError(ctx, "no program in use");
    var x: c_int = 0;
    var y: c_int = 0;
    var z: c_int = 0;
    if (c.JS_ToInt32(ctx, &x, argv[1]) != 0) return c.JS_EXCEPTION;
    if (c.JS_ToInt32(ctx, &y, argv[2]) != 0) return c.JS_EXCEPTION;
    if (c.JS_ToInt32(ctx, &z, argv[3]) != 0) return c.JS_EXCEPTION;
    const values = [_]i32{ @intCast(x), @intCast(y), @intCast(z) };
    webgl_program.globalProgramTable().setUniformInts(prog, loc, values[0..]) catch {
        return c.JS_UNDEFINED;
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_uniform4i(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 5) return throwTypeError(ctx, "uniform4i requires (location, x, y, z, w)");
    const loc = (readUniformLocation(ctx, argv[0]) catch return c.JS_EXCEPTION) orelse return c.JS_UNDEFINED;
    const prog = webgl_draw.currentProgram() orelse return throwTypeError(ctx, "no program in use");
    var x: c_int = 0;
    var y: c_int = 0;
    var z: c_int = 0;
    var w: c_int = 0;
    if (c.JS_ToInt32(ctx, &x, argv[1]) != 0) return c.JS_EXCEPTION;
    if (c.JS_ToInt32(ctx, &y, argv[2]) != 0) return c.JS_EXCEPTION;
    if (c.JS_ToInt32(ctx, &z, argv[3]) != 0) return c.JS_EXCEPTION;
    if (c.JS_ToInt32(ctx, &w, argv[4]) != 0) return c.JS_EXCEPTION;
    const values = [_]i32{ @intCast(x), @intCast(y), @intCast(z), @intCast(w) };
    webgl_program.globalProgramTable().setUniformInts(prog, loc, values[0..]) catch {
        return c.JS_UNDEFINED;
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_uniformMatrix4fv(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 3) return throwTypeError(ctx, "uniformMatrix4fv requires (location, transpose, data)");
    const loc = (readUniformLocation(ctx, argv[0]) catch return c.JS_EXCEPTION) orelse return c.JS_UNDEFINED;
    const prog = webgl_draw.currentProgram() orelse return throwTypeError(ctx, "no program in use");
    var transpose: c_int = 0;
    if (c.JS_ToInt32(ctx, &transpose, argv[1]) != 0) return c.JS_EXCEPTION;
    if (transpose != 0) return throwTypeError(ctx, "uniformMatrix4fv transpose must be false");
    var temp: [MaxUniformFloatCount]f32 = undefined;
    const count = readFloatValues(ctx, argv[2], temp[0..]) catch {
        return throwTypeError(ctx, "uniformMatrix4fv requires Float32Array");
    };
    webgl_program.globalProgramTable().setUniformFloats(prog, loc, temp[0..count]) catch {
        return c.JS_UNDEFINED;
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_uniform3fv(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) return throwTypeError(ctx, "uniform3fv requires (location, data)");
    const loc = (readUniformLocation(ctx, argv[0]) catch return c.JS_EXCEPTION) orelse return c.JS_UNDEFINED;
    const prog = webgl_draw.currentProgram() orelse return throwTypeError(ctx, "no program in use");
    var temp: [MaxUniformFloatCount]f32 = undefined;
    const count = readFloatValues(ctx, argv[1], temp[0..]) catch {
        return throwTypeError(ctx, "uniform3fv requires Float32Array");
    };
    webgl_program.globalProgramTable().setUniformFloats(prog, loc, temp[0..count]) catch {
        return c.JS_UNDEFINED;
    };
    return c.JS_UNDEFINED;
}

export fn js_gl_uniform4fv(ctx: *c.JSContext, _: *c.JSValue, argc: c_int, argv: [*]c.JSValue) callconv(.c) c.JSValue {
    if (argc < 2) return throwTypeError(ctx, "uniform4fv requires (location, data)");
    const loc = (readUniformLocation(ctx, argv[0]) catch return c.JS_EXCEPTION) orelse return c.JS_UNDEFINED;
    const prog = webgl_draw.currentProgram() orelse return throwTypeError(ctx, "no program in use");
    var temp: [MaxUniformFloatCount]f32 = undefined;
    const count = readFloatValues(ctx, argv[1], temp[0..]) catch {
        return throwTypeError(ctx, "uniform4fv requires Float32Array");
    };
    webgl_program.globalProgramTable().setUniformFloats(prog, loc, temp[0..count]) catch {
        return c.JS_UNDEFINED;
    };
    return c.JS_UNDEFINED;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "Runtime creates and destroys" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var rt = try Runtime.init(gpa.allocator(), 64 * 1024);
    defer rt.deinit();
    rt.makeCurrent();
}

test "setClearColor updates shared state" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var rt = try Runtime.init(gpa.allocator(), 64 * 1024);
    defer rt.deinit();
    rt.makeCurrent();

    try rt.eval("setClearColor(0.2, 0.4, 0.6)", "test");
    const state = rt.getSharedState();
    try testing.expectApproxEqAbs(@as(f32, 0.2), state.clear_color[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.4), state.clear_color[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.6), state.clear_color[2], 0.001);
}

test "requestAnimationFrame schedules and fires" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var rt = try Runtime.init(gpa.allocator(), 64 * 1024);
    defer rt.deinit();
    rt.makeCurrent();

    try rt.eval("var raf_called = 0; requestAnimationFrame(function(ts){ raf_called = 1; });", "test");
    rt.tick(16.0);

    const called = try rt.evalInt("raf_called", "test");
    try testing.expectEqual(@as(i32, 1), called);
}

test "document.createElement canvas getContext" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var rt = try Runtime.init(gpa.allocator(), 128 * 1024);
    defer rt.deinit();
    rt.makeCurrent();
    try rt.installDomStubs();

    try rt.eval(
        \\var c = document.createElement('canvas');
        \\c.width = 320;
        \\c.height = 240;
        \\var ctx0 = c.getContext('webgl');
        \\var ctx1 = c.getContext('webgl');
        \\var ok_ctx = (ctx0 === ctx1) ? 1 : 0;
        \\var ok_null = (c.getContext('nope') === null) ? 1 : 0;
        \\var ok_w = (ctx0.drawingBufferWidth === 320) ? 1 : 0;
        \\var ok_h = (ctx0.drawingBufferHeight === 240) ? 1 : 0;
    , "test");

    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_ctx", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_null", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_w", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_h", "test"));
}

test "gl capability stubs return defaults" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var rt = try Runtime.init(gpa.allocator(), 128 * 1024);
    defer rt.deinit();
    rt.makeCurrent();
    try rt.installDomStubs();

    try rt.eval(
        \\var ok_ver = (gl.getParameter(gl.VERSION).indexOf('WebGL') === 0) ? 1 : 0;
        \\var ok_tex = (gl.getParameter(gl.MAX_TEXTURE_SIZE) >= 1024) ? 1 : 0;
        \\var ok_ext = (gl.getSupportedExtensions().length === 0) ? 1 : 0;
        \\var ok_attr = gl.getContextAttributes().alpha ? 1 : 0;
    , "test");

    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_ver", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_tex", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_ext", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_attr", "test"));
}

test "gl enable/disable toggles depth cull blend" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var rt = try Runtime.init(gpa.allocator(), 128 * 1024);
    defer rt.deinit();
    rt.makeCurrent();
    try rt.installDomStubs();

    try rt.eval(
        \\gl.enable(gl.DEPTH_TEST);
        \\gl.enable(gl.CULL_FACE);
        \\gl.enable(gl.BLEND);
        \\var ok_depth = gl.getParameter(gl.DEPTH_TEST) ? 1 : 0;
        \\var ok_cull = gl.getParameter(gl.CULL_FACE) ? 1 : 0;
        \\var ok_blend = gl.getParameter(gl.BLEND) ? 1 : 0;
        \\gl.disable(gl.DEPTH_TEST);
        \\gl.disable(gl.CULL_FACE);
        \\gl.disable(gl.BLEND);
        \\var ok_depth_off = gl.getParameter(gl.DEPTH_TEST) ? 0 : 1;
        \\var ok_cull_off = gl.getParameter(gl.CULL_FACE) ? 0 : 1;
        \\var ok_blend_off = gl.getParameter(gl.BLEND) ? 0 : 1;
    , "test");

    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_depth", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_cull", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_blend", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_depth_off", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_cull_off", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_blend_off", "test"));
}

test "gl stencil state updates" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var rt = try Runtime.init(gpa.allocator(), 128 * 1024);
    defer rt.deinit();
    rt.makeCurrent();
    try rt.installDomStubs();

    try rt.eval(
        \\gl.enable(gl.STENCIL_TEST);
        \\gl.stencilFunc(gl.ALWAYS, 7, 0xAA);
        \\gl.stencilMask(0x0F);
        \\gl.stencilOp(gl.KEEP, gl.INCR, gl.DECR);
        \\gl.stencilFuncSeparate(gl.BACK, gl.NEVER, 3, 0xF0);
        \\gl.stencilMaskSeparate(gl.BACK, 0xF0);
        \\gl.stencilOpSeparate(gl.BACK, gl.REPLACE, gl.INVERT, gl.INCR_WRAP);
        \\var ok_func = (gl.getParameter(gl.STENCIL_FUNC) === gl.ALWAYS) ? 1 : 0;
        \\var ok_ref = (gl.getParameter(gl.STENCIL_REF) === 7) ? 1 : 0;
        \\var ok_mask = (gl.getParameter(gl.STENCIL_VALUE_MASK) === 0xAA) ? 1 : 0;
        \\var ok_wmask = (gl.getParameter(gl.STENCIL_WRITEMASK) === 0x0F) ? 1 : 0;
        \\var ok_fail = (gl.getParameter(gl.STENCIL_FAIL) === gl.KEEP) ? 1 : 0;
        \\var ok_zfail = (gl.getParameter(gl.STENCIL_PASS_DEPTH_FAIL) === gl.INCR) ? 1 : 0;
        \\var ok_zpass = (gl.getParameter(gl.STENCIL_PASS_DEPTH_PASS) === gl.DECR) ? 1 : 0;
        \\var ok_bfunc = (gl.getParameter(gl.STENCIL_BACK_FUNC) === gl.NEVER) ? 1 : 0;
        \\var ok_bref = (gl.getParameter(gl.STENCIL_BACK_REF) === 3) ? 1 : 0;
        \\var ok_bmask = (gl.getParameter(gl.STENCIL_BACK_VALUE_MASK) === 0xF0) ? 1 : 0;
        \\var ok_bwmask = (gl.getParameter(gl.STENCIL_BACK_WRITEMASK) === 0xF0) ? 1 : 0;
        \\var ok_bfail = (gl.getParameter(gl.STENCIL_BACK_FAIL) === gl.REPLACE) ? 1 : 0;
        \\var ok_bzfail = (gl.getParameter(gl.STENCIL_BACK_PASS_DEPTH_FAIL) === gl.INVERT) ? 1 : 0;
        \\var ok_bzpass = (gl.getParameter(gl.STENCIL_BACK_PASS_DEPTH_PASS) === gl.INCR_WRAP) ? 1 : 0;
    , "test");

    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_func", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_ref", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_mask", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_wmask", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_fail", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_zfail", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_zpass", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_bfunc", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_bref", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_bmask", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_bwmask", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_bfail", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_bzfail", "test"));
    try testing.expectEqual(@as(i32, 1), try rt.evalInt("ok_bzpass", "test"));
}

test "JS gl buffer lifecycle hits backend" {
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

    const mgr = webgl_state.globalBufferManager();
    mgr.reset();
    defer mgr.reset();
    try mgr.setBackend(&backend);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var rt = try Runtime.init(gpa.allocator(), 64 * 1024);
    defer rt.deinit();
    rt.makeCurrent();

    try rt.eval(
        \\var b = gl.createBuffer();
        \\gl.bindBuffer(gl.ARRAY_BUFFER, b);
        \\gl.bufferData(gl.ARRAY_BUFFER, 16);
        \\gl.bindBuffer(gl.ARRAY_BUFFER, null);
        \\gl.deleteBuffer(b);
    , "test");

    try testing.expectEqual(@as(u32, 1), stub.create_calls);
    try testing.expectEqual(@as(u32, 1), stub.update_calls);
    try testing.expectEqual(@as(u32, 1), stub.destroy_calls);
    try testing.expectEqual(@as(u16, 0), mgr.buffers.count);
}

test "JS gl bufferData accepts typed arrays" {
    const BackendStub = struct {
        update_calls: u32 = 0,
        last_len: usize = 0,

        const Self = @This();

        fn create(ctx: ?*anyopaque, size: usize, usage: webgl.BufferUsage) webgl.BufferBackend.Handle {
            _ = size;
            _ = usage;
            _ = ctx;
            return 1;
        }

        fn update(ctx: ?*anyopaque, handle: webgl.BufferBackend.Handle, data: []const u8) void {
            _ = handle;
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.update_calls += 1;
            self.last_len = data.len;
        }

        fn destroy(ctx: ?*anyopaque, handle: webgl.BufferBackend.Handle) void {
            _ = ctx;
            _ = handle;
        }
    };

    var stub = BackendStub{};
    const backend = webgl.BufferBackend{
        .ctx = &stub,
        .create = BackendStub.create,
        .update = BackendStub.update,
        .destroy = BackendStub.destroy,
    };

    const mgr = webgl_state.globalBufferManager();
    mgr.reset();
    defer mgr.reset();
    try mgr.setBackend(&backend);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var rt = try Runtime.init(gpa.allocator(), 64 * 1024);
    defer rt.deinit();
    rt.makeCurrent();

    try rt.eval(
        \\var b = gl.createBuffer();
        \\gl.bindBuffer(gl.ARRAY_BUFFER, b);
        \\var arr = new Uint8Array(4);
        \\gl.bufferData(gl.ARRAY_BUFFER, arr);
    , "test");

    try testing.expectEqual(@as(u32, 1), stub.update_calls);
    try testing.expectEqual(@as(usize, 4), stub.last_len);

    try rt.eval(
        \\var ab = new ArrayBuffer(12);
        \\gl.bufferData(gl.ARRAY_BUFFER, ab);
    , "test");

    try testing.expectEqual(@as(u32, 2), stub.update_calls);
    try testing.expectEqual(@as(usize, 12), stub.last_len);
}

test "JS element array buffer sets index usage" {
    const mgr = webgl_state.globalBufferManager();
    mgr.reset();
    defer mgr.reset();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var rt = try Runtime.init(gpa.allocator(), 64 * 1024);
    defer rt.deinit();
    rt.makeCurrent();

    try rt.eval(
        \\var b = gl.createBuffer();
        \\gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, b);
        \\gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, new Uint16Array(6));
    , "test");

    const id_raw = try rt.evalInt("b", "test");
    const id: webgl.BufferId = bufferIdFromU32(@intCast(id_raw));
    const buf = mgr.buffers.get(id) orelse return error.UnexpectedNull;
    try testing.expectEqual(webgl.BufferUsage.index, buf.usage);
    try testing.expectEqual(@as(u32, 12), buf.data_len);
}

test "JS gl shaderSource stores source" {
    const table = webgl_shader.globalShaderTable();
    table.reset();
    defer table.reset();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var rt = try Runtime.init(gpa.allocator(), 64 * 1024);
    defer rt.deinit();
    rt.makeCurrent();

    const src = "void main() {}";
    try rt.eval(
        \\var s = gl.createShader(gl.VERTEX_SHADER);
        \\gl.shaderSource(s, "void main() {}");
    , "test");

    const id_raw = try rt.evalInt("s", "test");
    const id: webgl_shader.ShaderId = shaderIdFromU32(@intCast(id_raw));
    const sh = table.get(id) orelse return error.UnexpectedNull;
    try testing.expectEqual(webgl_shader.ShaderKind.vertex, sh.kind);
    try testing.expectEqual(@as(u32, src.len), sh.source_len);
    const stored = table.getSource(id) orelse return error.UnexpectedNull;
    try testing.expectEqualSlices(u8, src, stored);
}

test "JS gl compileShader updates status and info log" {
    const table = webgl_shader.globalShaderTable();
    table.reset();
    defer table.reset();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var rt = try Runtime.init(gpa.allocator(), 64 * 1024);
    defer rt.deinit();
    rt.makeCurrent();

    try rt.eval(
        \\var s = gl.createShader(gl.VERTEX_SHADER);
        \\gl.compileShader(s);
        \\var status0 = gl.getShaderParameter(s, gl.COMPILE_STATUS) ? 1 : 0;
        \\var log0 = gl.getShaderInfoLog(s).length;
        \\gl.shaderSource(s, "void main() {}");
        \\gl.compileShader(s);
        \\var status1 = gl.getShaderParameter(s, gl.COMPILE_STATUS) ? 1 : 0;
        \\var log1 = gl.getShaderInfoLog(s).length;
    , "test");

    const status0 = try rt.evalInt("status0", "test");
    const log0 = try rt.evalInt("log0", "test");
    const status1 = try rt.evalInt("status1", "test");
    const log1 = try rt.evalInt("log1", "test");
    try testing.expectEqual(@as(i32, 0), status0);
    try testing.expect(log0 > 0);
    try testing.expectEqual(@as(i32, 1), status1);
    try testing.expectEqual(@as(i32, 0), log1);
}

test "JS gl program link status reflects shader state" {
    const shaders = webgl_shader.globalShaderTable();
    shaders.reset();
    defer shaders.reset();
    const programs = webgl_program.globalProgramTable();
    programs.reset();
    defer programs.reset();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var rt = try Runtime.init(gpa.allocator(), 64 * 1024);
    defer rt.deinit();
    rt.makeCurrent();

    try rt.eval(
        \\var vs = gl.createShader(gl.VERTEX_SHADER);
        \\var fs = gl.createShader(gl.FRAGMENT_SHADER);
        \\gl.shaderSource(vs, "void main() {}");
        \\gl.shaderSource(fs, "void main() {}");
        \\gl.compileShader(vs);
        \\gl.compileShader(fs);
        \\var p = gl.createProgram();
        \\gl.attachShader(p, vs);
        \\gl.attachShader(p, fs);
        \\gl.linkProgram(p);
        \\var linked0 = gl.getProgramParameter(p, gl.LINK_STATUS) ? 1 : 0;
        \\var log0 = gl.getProgramInfoLog(p).length;
        \\var bad = gl.createProgram();
        \\gl.attachShader(bad, vs);
        \\gl.linkProgram(bad);
        \\var linked1 = gl.getProgramParameter(bad, gl.LINK_STATUS) ? 1 : 0;
        \\var log1 = gl.getProgramInfoLog(bad).length;
    , "test");

    const linked0 = try rt.evalInt("linked0", "test");
    const log0 = try rt.evalInt("log0", "test");
    const linked1 = try rt.evalInt("linked1", "test");
    const log1 = try rt.evalInt("log1", "test");
    try testing.expectEqual(@as(i32, 1), linked0);
    try testing.expectEqual(@as(i32, 0), log0);
    try testing.expectEqual(@as(i32, 0), linked1);
    try testing.expect(log1 > 0);
}
