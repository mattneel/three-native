#pragma once

#include <stddef.h>
#include "mquickjs.h"

JSValue js_print(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_date_now(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_performance_now(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gc(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_load(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_setTimeout(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_clearTimeout(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_setClearColor(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_requestAnimationFrame(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_cancelAnimationFrame(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
