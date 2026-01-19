//! Pure Zig runtime bindings for mquickjs.
//!
//! The mquickjs engine stays in C, but all stdlib bindings and runtime glue
//! are implemented in Zig and provided through the stdlib table.

const std = @import("std");

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
