/*
 * JS runtime wrapper for three-native
 * Uses mquickjs example stdlib as base
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/time.h>

#include "cutils.h"
#include "mquickjs.h"

#define JS_CLASS_RECTANGLE (JS_CLASS_USER + 0)
#define JS_CLASS_FILLED_RECTANGLE (JS_CLASS_USER + 1)
#define JS_CLASS_COUNT (JS_CLASS_USER + 2)

#define JS_CFUNCTION_rectangle_closure_test (JS_CFUNCTION_USER + 0)

typedef struct {
    int x;
    int y;
} RectangleData;

typedef struct {
    RectangleData parent;
    int color;
} FilledRectangleData;

static JSValue js_rectangle_constructor(JSContext *ctx, JSValue *this_val, int argc,
                                        JSValue *argv)
{
    JSValue obj;
    RectangleData *d;

    if (!(argc & FRAME_CF_CTOR))
        return JS_ThrowTypeError(ctx, "must be called with new");
    argc &= ~FRAME_CF_CTOR;
    obj = JS_NewObjectClassUser(ctx, JS_CLASS_RECTANGLE);
    d = malloc(sizeof(*d));
    JS_SetOpaque(ctx, obj, d);
    if (JS_ToInt32(ctx, &d->x, argv[0]))
        return JS_EXCEPTION;
    if (JS_ToInt32(ctx, &d->y, argv[1]))
        return JS_EXCEPTION;
    return obj;
}

static void js_rectangle_finalizer(JSContext *ctx, void *opaque)
{
    RectangleData *d = opaque;
    free(d);
}

static JSValue js_rectangle_get_x(JSContext *ctx, JSValue *this_val, int argc,
                                  JSValue *argv)
{
    RectangleData *d;
    int class_id = JS_GetClassID(ctx, *this_val);
    if (class_id != JS_CLASS_RECTANGLE && class_id != JS_CLASS_FILLED_RECTANGLE)
        return JS_ThrowTypeError(ctx, "expecting Rectangle class");
    d = JS_GetOpaque(ctx, *this_val);
    return JS_NewInt32(ctx, d->x);
}

static JSValue js_rectangle_get_y(JSContext *ctx, JSValue *this_val, int argc,
                                  JSValue *argv)
{
    RectangleData *d;
    int class_id = JS_GetClassID(ctx, *this_val);
    if (class_id != JS_CLASS_RECTANGLE && class_id != JS_CLASS_FILLED_RECTANGLE)
        return JS_ThrowTypeError(ctx, "expecting Rectangle class");
    d = JS_GetOpaque(ctx, *this_val);
    return JS_NewInt32(ctx, d->y);
}

static JSValue js_rectangle_closure_test(JSContext *ctx, JSValue *this_val, int argc,
                                         JSValue *argv, JSValue params)
{
    return params;
}

static JSValue js_rectangle_getClosure(JSContext *ctx, JSValue *this_val, int argc,
                                    JSValue *argv)
{
    return JS_NewCFunctionParams(ctx, JS_CFUNCTION_rectangle_closure_test, argv[0]);
}

static JSValue js_rectangle_call(JSContext *ctx, JSValue *this_val, int argc,
                                 JSValue *argv)
{
    if (JS_StackCheck(ctx, 3))
        return JS_EXCEPTION;
    JS_PushArg(ctx, argv[1]);
    JS_PushArg(ctx, argv[0]);
    JS_PushArg(ctx, JS_NULL);
    return JS_Call(ctx, 1);
}

static JSValue js_filled_rectangle_constructor(JSContext *ctx, JSValue *this_val, int argc,
                                               JSValue *argv)
{
    JSGCRef obj_ref;
    JSValue *obj;
    FilledRectangleData *d;

    if (!(argc & FRAME_CF_CTOR))
        return JS_ThrowTypeError(ctx, "must be called with new");
    obj = JS_PushGCRef(ctx, &obj_ref);
    
    argc &= ~FRAME_CF_CTOR;
    *obj = JS_NewObjectClassUser(ctx, JS_CLASS_FILLED_RECTANGLE);
    d = malloc(sizeof(*d));
    JS_SetOpaque(ctx, *obj, d);
    if (JS_ToInt32(ctx, &d->parent.x, argv[0]))
        return JS_EXCEPTION;
    if (JS_ToInt32(ctx, &d->parent.y, argv[1]))
        return JS_EXCEPTION;
    if (JS_ToInt32(ctx, &d->color, argv[2]))
        return JS_EXCEPTION;
    JS_PopGCRef(ctx, &obj_ref);
    return *obj;
}

static void js_filled_rectangle_finalizer(JSContext *ctx, void *opaque)
{
    FilledRectangleData *d = opaque;
    free(d);
}

static JSValue js_filled_rectangle_get_color(JSContext *ctx, JSValue *this_val, int argc,
                                             JSValue *argv)
{
    FilledRectangleData *d;
    if (JS_GetClassID(ctx, *this_val) != JS_CLASS_FILLED_RECTANGLE)
        return JS_ThrowTypeError(ctx, "expecting FilledRectangle class");
    d = JS_GetOpaque(ctx, *this_val);
    return JS_NewInt32(ctx, d->color);
}

static JSValue js_print(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    int i;
    JSValue v;
    
    for(i = 0; i < argc; i++) {
        if (i != 0)
            putchar(' ');
        v = argv[i];
        if (JS_IsString(ctx, v)) {
            JSCStringBuf buf;
            const char *str;
            size_t len;
            str = JS_ToCStringLen(ctx, &len, v, &buf);
            fwrite(str, 1, len, stdout);
        } else {
            JS_PrintValueF(ctx, argv[i], JS_DUMP_LONG);
        }
    }
    putchar('\n');
    fflush(stdout);
    return JS_UNDEFINED;
}

#if defined(__linux__) || defined(__APPLE__)
static int64_t get_time_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (ts.tv_nsec / 1000000);
}
#else
static int64_t get_time_ms(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + (tv.tv_usec / 1000);
}
#endif

static JSValue js_date_now(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return JS_NewInt64(ctx, (int64_t)tv.tv_sec * 1000 + (tv.tv_usec / 1000));
}

static JSValue js_performance_now(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    return JS_NewInt64(ctx, get_time_ms());
}

/* Include the generated stdlib from mquickjs example */
#include "example_stdlib.h"

static void js_log_func(void *opaque, const void *buf, size_t buf_len)
{
    fwrite(buf, 1, buf_len, stdout);
}

/* Public API for Zig */
typedef struct {
    JSContext *ctx;
    void *mem_buf;
} JSRuntime;

JSRuntime *js_runtime_new(size_t mem_size)
{
    JSRuntime *rt = malloc(sizeof(JSRuntime));
    if (!rt) return NULL;
    
    rt->mem_buf = malloc(mem_size);
    if (!rt->mem_buf) {
        free(rt);
        return NULL;
    }
    
    rt->ctx = JS_NewContext(rt->mem_buf, mem_size, &js_stdlib);
    if (!rt->ctx) {
        free(rt->mem_buf);
        free(rt);
        return NULL;
    }
    
    JS_SetLogFunc(rt->ctx, js_log_func);
    return rt;
}

void js_runtime_free(JSRuntime *rt)
{
    if (rt) {
        if (rt->ctx) JS_FreeContext(rt->ctx);
        if (rt->mem_buf) free(rt->mem_buf);
        free(rt);
    }
}

int js_runtime_eval(JSRuntime *rt, const char *code, size_t len, const char *filename)
{
    JSValue val = JS_Eval(rt->ctx, code, len, filename, 0);
    if (JS_IsException(val)) {
        JSValue obj = JS_GetException(rt->ctx);
        JS_PrintValueF(rt->ctx, obj, JS_DUMP_LONG);
        printf("\n");
        return -1;
    }
    return 0;
}
