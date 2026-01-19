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
JSValue js_gl_createProgram(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_deleteProgram(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_attachShader(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_linkProgram(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_getProgramParameter(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_getProgramInfoLog(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_useProgram(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_getAttribLocation(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_enableVertexAttribArray(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_disableVertexAttribArray(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_vertexAttribPointer(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_drawArrays(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_drawElements(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_getUniformLocation(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_uniform1f(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_uniform2f(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_uniform3f(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_uniform4f(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_uniform1i(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_uniform2i(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_uniform3i(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_uniform4i(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_uniformMatrix4fv(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_uniform3fv(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gl_uniform4fv(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);