//! Pure Zig runtime bindings for mquickjs.
//!
//! The mquickjs engine stays in C, but all stdlib bindings and runtime glue
//! are implemented in Zig and provided through the stdlib table.

const std = @import("std");
const webgl_state = @import("../shim/webgl_state.zig");
const webgl = @import("../shim/webgl.zig");
const webgl_shader = @import("../shim/webgl_shader.zig");

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

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, mem_size: usize) !Self {
        const mem_buf = try allocator.alloc(u8, mem_size);
        errdefer allocator.free(mem_buf);

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
        };
    }

    pub fn deinit(self: *Self) void {
        if (g_runtime == self) {
            g_runtime = null;
        }
        c.JS_FreeContext(self.ctx);
        self.allocator.free(self.mem_buf);
    }

    pub fn makeCurrent(self: *Self) void {
        g_runtime = self;
        g_start_time_ms = std.time.milliTimestamp();
    }

    pub fn eval(self: *Self, code: []const u8, filename: [:0]const u8) !void {
        const val = c.JS_Eval(self.ctx, code.ptr, code.len, filename.ptr, 0);
        if (val == c.JS_EXCEPTION) {
            dumpException(self.ctx);
            return error.EvalFailed;
        }
    }

    pub fn evalInt(self: *Self, code: []const u8, filename: [:0]const u8) !i32 {
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
        self.shared.time_ms = timestamp_ms;
        self.runTimers(timestamp_ms);
        self.runRaf(timestamp_ms);
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

fn getRuntime(ctx: *c.JSContext) ?*Runtime {
    _ = ctx;
    return g_runtime;
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

const GL_ARRAY_BUFFER: u32 = 34962;
const GL_ELEMENT_ARRAY_BUFFER: u32 = 34963;
const GL_VERTEX_SHADER: u32 = 35633;
const GL_FRAGMENT_SHADER: u32 = 35632;
const GL_COMPILE_STATUS: u32 = 35713;

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

    return c.JS_Eval(ctx, data.ptr, data.len, filename, 0);
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
        else => return throwInternalError(ctx, "shaderSource failed"),
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
    const sh = table.get(shaderIdFromU32(raw)) orelse {
        return throwTypeError(ctx, "invalid shader handle");
    };
    if (sh.info_log) |log| {
        return c.JS_NewStringLen(ctx, @ptrCast(log.ptr), log.len);
    }
    return c.JS_NewStringLen(ctx, "", 0);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "Runtime creates and destroys" {
    var rt = try Runtime.init(testing.allocator, 64 * 1024);
    defer rt.deinit();
    rt.makeCurrent();
}

test "setClearColor updates shared state" {
    var rt = try Runtime.init(testing.allocator, 64 * 1024);
    defer rt.deinit();
    rt.makeCurrent();

    try rt.eval("setClearColor(0.2, 0.4, 0.6)", "test");
    const state = rt.getSharedState();
    try testing.expectApproxEqAbs(@as(f32, 0.2), state.clear_color[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.4), state.clear_color[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.6), state.clear_color[2], 0.001);
}

test "requestAnimationFrame schedules and fires" {
    var rt = try Runtime.init(testing.allocator, 64 * 1024);
    defer rt.deinit();
    rt.makeCurrent();

    try rt.eval("var raf_called = 0; requestAnimationFrame(function(ts){ raf_called = 1; });", "test");
    rt.tick(16.0);

    const called = try rt.evalInt("raf_called", "test");
    try testing.expectEqual(@as(i32, 1), called);
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
    mgr.setBackend(&backend);

    var rt = try Runtime.init(testing.allocator, 64 * 1024);
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
    mgr.setBackend(&backend);

    var rt = try Runtime.init(testing.allocator, 64 * 1024);
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

    var rt = try Runtime.init(testing.allocator, 64 * 1024);
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

    var rt = try Runtime.init(testing.allocator, 64 * 1024);
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
    const stored = sh.source orelse return error.UnexpectedNull;
    try testing.expectEqualSlices(u8, src, stored);
}

test "JS gl compileShader updates status and info log" {
    const table = webgl_shader.globalShaderTable();
    table.reset();
    defer table.reset();

    var rt = try Runtime.init(testing.allocator, 64 * 1024);
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
