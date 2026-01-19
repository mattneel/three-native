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
JSValue js_gl_createBuffer(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_deleteBuffer(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_bindBuffer(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_bufferData(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_createShader(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_deleteShader(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_shaderSource(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_compileShader(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_getShaderParameter(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_getShaderInfoLog(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);