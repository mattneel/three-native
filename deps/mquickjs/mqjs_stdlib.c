/*
 * Micro QuickJS REPL library
 *
 * Copyright (c) 2017-2025 Fabrice Bellard
 * Copyright (c) 2017-2025 Charlie Gordon
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "mquickjs_build.h"

/* defined in mqjs_example.c */
//#define CONFIG_CLASS_EXAMPLE

static const JSPropDef js_object_proto[] = {
    JS_CFUNC_DEF("hasOwnProperty", 1, js_object_hasOwnProperty),
    JS_CFUNC_DEF("toString", 0, js_object_toString),
    JS_PROP_END,
};

static const JSPropDef js_object[] = {
    JS_CFUNC_DEF("defineProperty", 3, js_object_defineProperty),
    JS_CFUNC_DEF("getPrototypeOf", 1, js_object_getPrototypeOf),
    JS_CFUNC_DEF("setPrototypeOf", 2, js_object_setPrototypeOf),
    JS_CFUNC_DEF("create", 2, js_object_create),
    JS_CFUNC_DEF("keys", 1, js_object_keys),
    JS_PROP_END,
};

static const JSClassDef js_object_class =
    JS_CLASS_DEF("Object", 1, js_object_constructor, JS_CLASS_OBJECT,
                 js_object, js_object_proto, NULL, NULL);

static const JSPropDef js_function_proto[] = {
    JS_CGETSET_DEF("prototype", js_function_get_prototype, js_function_set_prototype ),
    JS_CFUNC_DEF("call", 1, js_function_call ),
    JS_CFUNC_DEF("apply", 2, js_function_apply ),
    JS_CFUNC_DEF("bind", 1, js_function_bind ),
    JS_CFUNC_DEF("toString", 0, js_function_toString ),
    JS_CGETSET_MAGIC_DEF("length", js_function_get_length_name, NULL, 0 ),
    JS_CGETSET_MAGIC_DEF("name", js_function_get_length_name, NULL, 1 ),
    JS_PROP_END,
};

static const JSClassDef js_function_class =
    JS_CLASS_DEF("Function", 1, js_function_constructor, JS_CLASS_CLOSURE, NULL, js_function_proto, NULL, NULL);

static const JSPropDef js_number_proto[] = {
    JS_CFUNC_DEF("toExponential", 1, js_number_toExponential ),
    JS_CFUNC_DEF("toFixed", 1, js_number_toFixed ),
    JS_CFUNC_DEF("toPrecision", 1, js_number_toPrecision ),
    JS_CFUNC_DEF("toString", 1, js_number_toString ),
    JS_PROP_END,
};

static const JSPropDef js_number[] = {
    JS_CFUNC_DEF("parseInt", 2, js_number_parseInt ),
    JS_CFUNC_DEF("parseFloat", 1, js_number_parseFloat ),
    JS_PROP_DOUBLE_DEF("MAX_VALUE", 1.7976931348623157e+308, 0 ),
    JS_PROP_DOUBLE_DEF("MIN_VALUE", 5e-324, 0 ),
    JS_PROP_DOUBLE_DEF("NaN", NAN, 0 ),
    JS_PROP_DOUBLE_DEF("NEGATIVE_INFINITY", -INFINITY, 0 ),
    JS_PROP_DOUBLE_DEF("POSITIVE_INFINITY", INFINITY, 0 ),
    JS_PROP_DOUBLE_DEF("EPSILON", 2.220446049250313e-16, 0 ), /* ES6 */
    JS_PROP_DOUBLE_DEF("MAX_SAFE_INTEGER", 9007199254740991.0, 0 ), /* ES6 */
    JS_PROP_DOUBLE_DEF("MIN_SAFE_INTEGER", -9007199254740991.0, 0 ), /* ES6 */
    JS_PROP_END,
};

static const JSClassDef js_number_class =
    JS_CLASS_DEF("Number", 1, js_number_constructor, JS_CLASS_NUMBER, js_number, js_number_proto, NULL, NULL);

static const JSClassDef js_boolean_class =
    JS_CLASS_DEF("Boolean", 1, js_boolean_constructor, JS_CLASS_BOOLEAN, NULL, NULL, NULL, NULL);

static const JSPropDef js_string_proto[] = {
    JS_CGETSET_DEF("length", js_string_get_length, js_string_set_length ),
    JS_CFUNC_MAGIC_DEF("charAt", 1, js_string_charAt, magic_charAt ),
    JS_CFUNC_MAGIC_DEF("charCodeAt", 1, js_string_charAt, magic_charCodeAt ),
    JS_CFUNC_MAGIC_DEF("codePointAt", 1, js_string_charAt, magic_codePointAt ),
    JS_CFUNC_DEF("slice", 2, js_string_slice ),
    JS_CFUNC_DEF("substring", 2, js_string_substring ),
    JS_CFUNC_DEF("concat", 1, js_string_concat ),
    JS_CFUNC_MAGIC_DEF("indexOf", 1, js_string_indexOf, 0 ),
    JS_CFUNC_MAGIC_DEF("lastIndexOf", 1, js_string_indexOf, 1 ),
    JS_CFUNC_DEF("match", 1, js_string_match ),
    JS_CFUNC_MAGIC_DEF("replace", 2, js_string_replace, 0 ),
    JS_CFUNC_MAGIC_DEF("replaceAll", 2, js_string_replace, 1 ),
    JS_CFUNC_DEF("search", 1, js_string_search ),
    JS_CFUNC_DEF("split", 2, js_string_split ),
    JS_CFUNC_MAGIC_DEF("toLowerCase", 0, js_string_toLowerCase, 1 ),
    JS_CFUNC_MAGIC_DEF("toUpperCase", 0, js_string_toLowerCase, 0 ),
    JS_CFUNC_MAGIC_DEF("trim", 0, js_string_trim, 3 ),
    JS_CFUNC_MAGIC_DEF("trimEnd", 0, js_string_trim, 2 ),
    JS_CFUNC_MAGIC_DEF("trimStart", 0, js_string_trim, 1 ),
    JS_CFUNC_DEF("toString", 0, js_string_toString ),
    JS_CFUNC_DEF("repeat", 1, js_string_repeat ),
    JS_PROP_END,
};

static const JSPropDef js_string[] = {
    JS_CFUNC_MAGIC_DEF("fromCharCode", 1, js_string_fromCharCode, 0 ),
    JS_CFUNC_MAGIC_DEF("fromCodePoint", 1, js_string_fromCharCode, 1 ),
    JS_PROP_END,
};

static const JSClassDef js_string_class =
    JS_CLASS_DEF("String", 1, js_string_constructor, JS_CLASS_STRING, js_string, js_string_proto, NULL, NULL);

static const JSPropDef js_array_proto[] = {
    JS_CFUNC_DEF("concat", 1, js_array_concat ),
    JS_CGETSET_DEF("length", js_array_get_length, js_array_set_length ),
    JS_CFUNC_MAGIC_DEF("push", 1, js_array_push, 0 ),
    JS_CFUNC_DEF("pop", 0, js_array_pop ),
    JS_CFUNC_DEF("join", 1, js_array_join ),
    JS_CFUNC_DEF("toString", 0, js_array_toString ),
    JS_CFUNC_DEF("reverse", 0, js_array_reverse ),
    JS_CFUNC_DEF("shift", 0, js_array_shift ),
    JS_CFUNC_DEF("slice", 2, js_array_slice ),
    JS_CFUNC_DEF("splice", 2, js_array_splice ),
    JS_CFUNC_MAGIC_DEF("unshift", 1, js_array_push, 1 ),
    JS_CFUNC_MAGIC_DEF("indexOf", 1, js_array_indexOf, 0 ),
    JS_CFUNC_MAGIC_DEF("lastIndexOf", 1, js_array_indexOf, 1 ),
    JS_CFUNC_MAGIC_DEF("every", 1, js_array_every, js_special_every ),
    JS_CFUNC_MAGIC_DEF("some", 1, js_array_every, js_special_some ),
    JS_CFUNC_MAGIC_DEF("forEach", 1, js_array_every, js_special_forEach ),
    JS_CFUNC_MAGIC_DEF("map", 1, js_array_every, js_special_map ),
    JS_CFUNC_MAGIC_DEF("filter", 1, js_array_every, js_special_filter ),
    JS_CFUNC_MAGIC_DEF("reduce", 1, js_array_reduce, js_special_reduce ),
    JS_CFUNC_MAGIC_DEF("reduceRight", 1, js_array_reduce, js_special_reduceRight ),
    JS_CFUNC_MAGIC_DEF("reduce", 1, js_array_reduce, js_special_reduce ),
    JS_CFUNC_DEF("sort", 1, js_array_sort ),
    JS_PROP_END,
};

static const JSPropDef js_array[] = {
    JS_CFUNC_DEF("isArray", 1, js_array_isArray ),
    JS_PROP_END,
};

static const JSClassDef js_array_class =
    JS_CLASS_DEF("Array", 1, js_array_constructor, JS_CLASS_ARRAY, js_array, js_array_proto, NULL, NULL);

static const JSPropDef js_error_proto[] = {
    JS_CFUNC_DEF("toString", 0, js_error_toString ),
    JS_PROP_STRING_DEF("name", "Error", 0 ),
    JS_CGETSET_MAGIC_DEF("message", js_error_get_message, NULL, 0 ),
    JS_CGETSET_MAGIC_DEF("stack", js_error_get_message, NULL, 1 ),
    JS_PROP_END,
};

static const JSClassDef js_error_class =
    JS_CLASS_MAGIC_DEF("Error", 1, js_error_constructor, JS_CLASS_ERROR, NULL, js_error_proto, NULL, NULL);

#define ERROR_DEF(cname, name, class_id)                       \
    static const JSPropDef js_ ## cname ## _proto[] = { \
        JS_PROP_STRING_DEF("name", name, 0 ),                  \
        JS_PROP_END,                                         \
    };                                                                 \
    static const JSClassDef js_ ## cname ## _class =                    \
        JS_CLASS_MAGIC_DEF(name, 1, js_error_constructor, class_id, NULL, js_ ## cname ## _proto, &js_error_class, NULL);

ERROR_DEF(eval_error, "EvalError", JS_CLASS_EVAL_ERROR)
ERROR_DEF(range_error, "RangeError", JS_CLASS_RANGE_ERROR)
ERROR_DEF(reference_error, "ReferenceError", JS_CLASS_REFERENCE_ERROR)
ERROR_DEF(syntax_error, "SyntaxError", JS_CLASS_SYNTAX_ERROR)
ERROR_DEF(type_error, "TypeError", JS_CLASS_TYPE_ERROR)
ERROR_DEF(uri_error, "URIError", JS_CLASS_URI_ERROR)
ERROR_DEF(internal_error, "InternalError", JS_CLASS_INTERNAL_ERROR)

static const JSPropDef js_math[] = {
    JS_CFUNC_MAGIC_DEF("min", 2, js_math_min_max, 0 ),
    JS_CFUNC_MAGIC_DEF("max", 2, js_math_min_max, 1 ),
    JS_CFUNC_SPECIAL_DEF("sign", 1, f_f, js_math_sign ),
    JS_CFUNC_SPECIAL_DEF("abs", 1, f_f, js_fabs ),
    JS_CFUNC_SPECIAL_DEF("floor", 1, f_f, js_floor ),
    JS_CFUNC_SPECIAL_DEF("ceil", 1, f_f, js_ceil ),
    JS_CFUNC_SPECIAL_DEF("round", 1, f_f, js_round_inf ),
    JS_CFUNC_SPECIAL_DEF("sqrt", 1, f_f, js_sqrt ),

    JS_PROP_DOUBLE_DEF("E", 2.718281828459045, 0 ),
    JS_PROP_DOUBLE_DEF("LN10", 2.302585092994046, 0 ),
    JS_PROP_DOUBLE_DEF("LN2", 0.6931471805599453, 0 ),
    JS_PROP_DOUBLE_DEF("LOG2E", 1.4426950408889634, 0 ),
    JS_PROP_DOUBLE_DEF("LOG10E", 0.4342944819032518, 0 ),
    JS_PROP_DOUBLE_DEF("PI", 3.141592653589793, 0 ),
    JS_PROP_DOUBLE_DEF("SQRT1_2", 0.7071067811865476, 0 ),
    JS_PROP_DOUBLE_DEF("SQRT2", 1.4142135623730951, 0 ),

    JS_CFUNC_SPECIAL_DEF("sin", 1, f_f, js_sin ),
    JS_CFUNC_SPECIAL_DEF("cos", 1, f_f, js_cos ),
    JS_CFUNC_SPECIAL_DEF("tan", 1, f_f, js_tan ),
    JS_CFUNC_SPECIAL_DEF("asin", 1, f_f, js_asin ),
    JS_CFUNC_SPECIAL_DEF("acos", 1, f_f, js_acos ),
    JS_CFUNC_SPECIAL_DEF("atan", 1, f_f, js_atan ),
    JS_CFUNC_DEF("atan2", 2, js_math_atan2 ),
    JS_CFUNC_SPECIAL_DEF("exp", 1, f_f, js_exp ),
    JS_CFUNC_SPECIAL_DEF("log", 1, f_f, js_log ),
    JS_CFUNC_DEF("pow", 2, js_math_pow ),
    JS_CFUNC_DEF("random", 0, js_math_random ),

    /* some ES6 functions */
    JS_CFUNC_DEF("imul", 2, js_math_imul ),
    JS_CFUNC_DEF("clz32", 1, js_math_clz32 ),
    JS_CFUNC_SPECIAL_DEF("fround", 1, f_f, js_math_fround ),
    JS_CFUNC_SPECIAL_DEF("trunc", 1, f_f, js_trunc ),
    JS_CFUNC_SPECIAL_DEF("log2", 1, f_f, js_log2 ),
    JS_CFUNC_SPECIAL_DEF("log10", 1, f_f, js_log10 ),
    
    JS_PROP_END,
};

static const JSClassDef js_math_obj =
    JS_OBJECT_DEF("Math", js_math);

static const JSPropDef js_json[] = {
    JS_CFUNC_DEF("parse", 2, js_json_parse ),
    JS_CFUNC_DEF("stringify", 3, js_json_stringify ),
    JS_PROP_END,
};

static const JSClassDef js_json_obj =
    JS_OBJECT_DEF("JSON", js_json);

/* typed arrays */
static const JSPropDef js_array_buffer_proto[] = {
    JS_CGETSET_DEF("byteLength", js_array_buffer_get_byteLength, NULL ),
    JS_PROP_END,
};

static const JSClassDef js_array_buffer_class =
    JS_CLASS_DEF("ArrayBuffer", 1, js_array_buffer_constructor, JS_CLASS_ARRAY_BUFFER, NULL, js_array_buffer_proto, NULL, NULL);

static const JSPropDef js_typed_array_base_proto[] = {
    JS_CGETSET_MAGIC_DEF("length", js_typed_array_get_length, NULL, 0 ),
    JS_CGETSET_MAGIC_DEF("byteLength", js_typed_array_get_length, NULL, 1 ),
    JS_CGETSET_MAGIC_DEF("byteOffset", js_typed_array_get_length, NULL, 2 ),
    JS_CGETSET_MAGIC_DEF("buffer", js_typed_array_get_length, NULL, 3 ),
    JS_CFUNC_DEF("join", 1, js_array_join ),
    JS_CFUNC_DEF("toString", 0, js_array_toString ),
    JS_CFUNC_DEF("subarray", 2, js_typed_array_subarray ),
    JS_CFUNC_DEF("set", 1, js_typed_array_set ),
    JS_PROP_END,
};

static const JSClassDef js_typed_array_base_class =
    JS_CLASS_DEF("TypedArray", 0, js_typed_array_base_constructor, JS_CLASS_TYPED_ARRAY, NULL, js_typed_array_base_proto, NULL, NULL);

#define TA_DEF(name, class_name, bpe)\
static const JSPropDef js_ ## name [] = {\
    JS_PROP_DOUBLE_DEF("BYTES_PER_ELEMENT", bpe, 0),\
    JS_PROP_END,\
};\
static const JSPropDef js_ ## name ## _proto[] = {\
    JS_PROP_DOUBLE_DEF("BYTES_PER_ELEMENT", bpe, 0),\
    JS_PROP_END,\
};\
static const JSClassDef js_ ## name ## _class =\
    JS_CLASS_MAGIC_DEF(#name, 3, js_typed_array_constructor, class_name, js_ ## name, js_ ## name ## _proto, &js_typed_array_base_class, NULL);

TA_DEF(Uint8ClampedArray, JS_CLASS_UINT8C_ARRAY, 1)
TA_DEF(Int8Array, JS_CLASS_INT8_ARRAY, 1)
TA_DEF(Uint8Array, JS_CLASS_UINT8_ARRAY, 1)
TA_DEF(Int16Array, JS_CLASS_INT16_ARRAY, 2)
TA_DEF(Uint16Array, JS_CLASS_UINT16_ARRAY, 2)
TA_DEF(Int32Array, JS_CLASS_INT32_ARRAY, 4)
TA_DEF(Uint32Array, JS_CLASS_UINT32_ARRAY, 4)
TA_DEF(Float32Array, JS_CLASS_FLOAT32_ARRAY, 4)
TA_DEF(Float64Array, JS_CLASS_FLOAT64_ARRAY, 8)

/* regexp */

static const JSPropDef js_regexp_proto[] = {
    JS_CGETSET_DEF("lastIndex", js_regexp_get_lastIndex, js_regexp_set_lastIndex ),
    JS_CGETSET_DEF("source", js_regexp_get_source, NULL ),
    JS_CGETSET_DEF("flags", js_regexp_get_flags, NULL ),
    JS_CFUNC_MAGIC_DEF("exec", 1, js_regexp_exec, 0 ),
    JS_CFUNC_MAGIC_DEF("test", 1, js_regexp_exec, 1 ),
    JS_PROP_END,
};

static const JSClassDef js_regexp_class =
    JS_CLASS_DEF("RegExp", 2, js_regexp_constructor, JS_CLASS_REGEXP, NULL, js_regexp_proto, NULL, NULL);

/* other objects */

static const JSPropDef js_date[] = {
    JS_CFUNC_DEF("now", 0, js_date_now),
    JS_PROP_END,
};

static const JSClassDef js_date_class =
    JS_CLASS_DEF("Date", 7, js_date_constructor, JS_CLASS_DATE, js_date, NULL, NULL, NULL);

static const JSPropDef js_console[] = {
    JS_CFUNC_DEF("log", 1, js_print),
    JS_CFUNC_DEF("warn", 1, js_print),
    JS_CFUNC_DEF("error", 1, js_print),
    JS_CFUNC_DEF("info", 1, js_print),
    JS_CFUNC_DEF("debug", 1, js_print),
    JS_PROP_END,
};

static const JSClassDef js_console_obj =
    JS_OBJECT_DEF("Console", js_console);

static const JSPropDef js_performance[] = {
    JS_CFUNC_DEF("now", 0, js_performance_now),
    JS_PROP_END,
};
static const JSClassDef js_performance_obj =
    JS_OBJECT_DEF("Performance", js_performance);

static const JSPropDef js_gl[] = {
    JS_CFUNC_DEF("createBuffer", 0, js_gl_createBuffer),
    JS_CFUNC_DEF("deleteBuffer", 1, js_gl_deleteBuffer),
    JS_CFUNC_DEF("bindBuffer", 2, js_gl_bindBuffer),
    JS_CFUNC_DEF("bufferData", 2, js_gl_bufferData),
    JS_CFUNC_DEF("createShader", 1, js_gl_createShader),
    JS_CFUNC_DEF("deleteShader", 1, js_gl_deleteShader),
    JS_CFUNC_DEF("shaderSource", 2, js_gl_shaderSource),
    JS_CFUNC_DEF("compileShader", 1, js_gl_compileShader),
    JS_CFUNC_DEF("getShaderParameter", 2, js_gl_getShaderParameter),
    JS_CFUNC_DEF("getShaderInfoLog", 1, js_gl_getShaderInfoLog),
    JS_CFUNC_DEF("createProgram", 0, js_gl_createProgram),
    JS_CFUNC_DEF("deleteProgram", 1, js_gl_deleteProgram),
    JS_CFUNC_DEF("attachShader", 2, js_gl_attachShader),
    JS_CFUNC_DEF("linkProgram", 1, js_gl_linkProgram),
    JS_CFUNC_DEF("getProgramParameter", 2, js_gl_getProgramParameter),
    JS_CFUNC_DEF("getProgramInfoLog", 1, js_gl_getProgramInfoLog),
    JS_CFUNC_DEF("useProgram", 1, js_gl_useProgram),
    JS_CFUNC_DEF("getAttribLocation", 2, js_gl_getAttribLocation),
    JS_CFUNC_DEF("getActiveAttrib", 2, js_gl_getActiveAttrib),
    JS_CFUNC_DEF("getActiveUniform", 2, js_gl_getActiveUniform),
    JS_CFUNC_DEF("getParameter", 1, js_gl_getParameter),
    JS_CFUNC_DEF("getExtension", 1, js_gl_getExtension),
    JS_CFUNC_DEF("getSupportedExtensions", 0, js_gl_getSupportedExtensions),
    JS_CFUNC_DEF("getContextAttributes", 0, js_gl_getContextAttributes),
    JS_CFUNC_DEF("stencilFunc", 3, js_gl_stencilFunc),
    JS_CFUNC_DEF("stencilFuncSeparate", 4, js_gl_stencilFuncSeparate),
    JS_CFUNC_DEF("stencilMask", 1, js_gl_stencilMask),
    JS_CFUNC_DEF("stencilMaskSeparate", 2, js_gl_stencilMaskSeparate),
    JS_CFUNC_DEF("stencilOp", 3, js_gl_stencilOp),
    JS_CFUNC_DEF("stencilOpSeparate", 4, js_gl_stencilOpSeparate),
    JS_CFUNC_DEF("activeTexture", 1, js_gl_activeTexture),
    JS_CFUNC_DEF("createTexture", 0, js_gl_createTexture),
    JS_CFUNC_DEF("deleteTexture", 1, js_gl_deleteTexture),
    JS_CFUNC_DEF("bindTexture", 2, js_gl_bindTexture),
    JS_CFUNC_DEF("texParameteri", 3, js_gl_texParameteri),
    JS_CFUNC_DEF("texImage2D", 9, js_gl_texImage2D),
    JS_CFUNC_DEF("texSubImage2D", 9, js_gl_texSubImage2D),
    JS_CFUNC_DEF("texStorage2D", 5, js_gl_texStorage2D),
    JS_CFUNC_DEF("texImage3D", 10, js_gl_texImage3D),
    JS_CFUNC_DEF("texSubImage3D", 10, js_gl_texSubImage3D),
    JS_CFUNC_DEF("generateMipmap", 1, js_gl_generateMipmap),
    JS_CFUNC_DEF("createFramebuffer", 0, js_gl_createFramebuffer),
    JS_CFUNC_DEF("deleteFramebuffer", 1, js_gl_deleteFramebuffer),
    JS_CFUNC_DEF("bindFramebuffer", 2, js_gl_bindFramebuffer),
    JS_CFUNC_DEF("framebufferTexture2D", 5, js_gl_framebufferTexture2D),
    JS_CFUNC_DEF("checkFramebufferStatus", 1, js_gl_checkFramebufferStatus),
    JS_CFUNC_DEF("createRenderbuffer", 0, js_gl_createRenderbuffer),
    JS_CFUNC_DEF("deleteRenderbuffer", 1, js_gl_deleteRenderbuffer),
    JS_CFUNC_DEF("bindRenderbuffer", 2, js_gl_bindRenderbuffer),
    JS_CFUNC_DEF("renderbufferStorage", 4, js_gl_renderbufferStorage),
    JS_CFUNC_DEF("framebufferRenderbuffer", 4, js_gl_framebufferRenderbuffer),
    JS_CFUNC_DEF("createVertexArray", 0, js_gl_createVertexArray),
    JS_CFUNC_DEF("deleteVertexArray", 1, js_gl_deleteVertexArray),
    JS_CFUNC_DEF("bindVertexArray", 1, js_gl_bindVertexArray),
    JS_CFUNC_DEF("enable", 1, js_gl_enable),
    JS_CFUNC_DEF("disable", 1, js_gl_disable),
    JS_CFUNC_DEF("viewport", 4, js_gl_viewport),
    JS_CFUNC_DEF("clearColor", 4, js_gl_clearColor),
    JS_CFUNC_DEF("clear", 1, js_gl_clear),
    JS_CFUNC_DEF("clearDepth", 1, js_gl_clearDepth),
    JS_CFUNC_DEF("clearStencil", 1, js_gl_clearStencil),
    JS_CFUNC_DEF("depthFunc", 1, js_gl_depthFunc),
    JS_CFUNC_DEF("depthMask", 1, js_gl_depthMask),
    JS_CFUNC_DEF("colorMask", 4, js_gl_colorMask),
    JS_CFUNC_DEF("cullFace", 1, js_gl_cullFace),
    JS_CFUNC_DEF("frontFace", 1, js_gl_frontFace),
    JS_CFUNC_DEF("blendFunc", 2, js_gl_blendFunc),
    JS_CFUNC_DEF("blendFuncSeparate", 4, js_gl_blendFuncSeparate),
    JS_CFUNC_DEF("blendEquation", 1, js_gl_blendEquation),
    JS_CFUNC_DEF("blendEquationSeparate", 2, js_gl_blendEquationSeparate),
    JS_CFUNC_DEF("scissor", 4, js_gl_scissor),
    JS_CFUNC_DEF("lineWidth", 1, js_gl_lineWidth),
    JS_CFUNC_DEF("polygonOffset", 2, js_gl_polygonOffset),
    JS_CFUNC_DEF("pixelStorei", 2, js_gl_pixelStorei),
    JS_CFUNC_DEF("getError", 0, js_gl_getError),
    JS_CFUNC_DEF("getShaderPrecisionFormat", 2, js_gl_getShaderPrecisionFormat),
    JS_CFUNC_DEF("enableVertexAttribArray", 1, js_gl_enableVertexAttribArray),
    JS_CFUNC_DEF("disableVertexAttribArray", 1, js_gl_disableVertexAttribArray),
    JS_CFUNC_DEF("vertexAttribPointer", 6, js_gl_vertexAttribPointer),
    JS_CFUNC_DEF("drawArrays", 3, js_gl_drawArrays),
    JS_CFUNC_DEF("drawElements", 4, js_gl_drawElements),
    JS_CFUNC_DEF("getUniformLocation", 2, js_gl_getUniformLocation),
    JS_CFUNC_DEF("uniform1f", 2, js_gl_uniform1f),
    JS_CFUNC_DEF("uniform2f", 3, js_gl_uniform2f),
    JS_CFUNC_DEF("uniform3f", 4, js_gl_uniform3f),
    JS_CFUNC_DEF("uniform4f", 5, js_gl_uniform4f),
    JS_CFUNC_DEF("uniform1i", 2, js_gl_uniform1i),
    JS_CFUNC_DEF("uniform2i", 3, js_gl_uniform2i),
    JS_CFUNC_DEF("uniform3i", 4, js_gl_uniform3i),
    JS_CFUNC_DEF("uniform4i", 5, js_gl_uniform4i),
    JS_CFUNC_DEF("uniformMatrix4fv", 3, js_gl_uniformMatrix4fv),
    JS_CFUNC_DEF("uniformMatrix3fv", 3, js_gl_uniformMatrix3fv),
    JS_CFUNC_DEF("uniformMatrix2fv", 3, js_gl_uniformMatrix2fv),
    JS_CFUNC_DEF("uniform1fv", 2, js_gl_uniform1fv),
    JS_CFUNC_DEF("uniform2fv", 2, js_gl_uniform2fv),
    JS_CFUNC_DEF("uniform3fv", 2, js_gl_uniform3fv),
    JS_CFUNC_DEF("uniform4fv", 2, js_gl_uniform4fv),
    JS_PROP_DOUBLE_DEF("ARRAY_BUFFER", 34962, 0 ),
    JS_PROP_DOUBLE_DEF("ELEMENT_ARRAY_BUFFER", 34963, 0 ),
    JS_PROP_DOUBLE_DEF("VERTEX_SHADER", 35633, 0 ),
    JS_PROP_DOUBLE_DEF("FRAGMENT_SHADER", 35632, 0 ),
    JS_PROP_DOUBLE_DEF("COMPILE_STATUS", 35713, 0 ),
    JS_PROP_DOUBLE_DEF("LINK_STATUS", 35714, 0 ),
    JS_PROP_DOUBLE_DEF("FLOAT", 5126, 0 ),
    JS_PROP_DOUBLE_DEF("UNSIGNED_SHORT", 5123, 0 ),
    JS_PROP_DOUBLE_DEF("UNSIGNED_INT", 5125, 0 ),
    JS_PROP_DOUBLE_DEF("TRIANGLES", 4, 0 ),
    JS_PROP_DOUBLE_DEF("TRIANGLE_STRIP", 5, 0 ),
    JS_PROP_DOUBLE_DEF("LINES", 1, 0 ),
    JS_PROP_DOUBLE_DEF("POINTS", 0, 0 ),
    JS_PROP_DOUBLE_DEF("COLOR_BUFFER_BIT", 0x00004000, 0 ),
    JS_PROP_DOUBLE_DEF("DEPTH_BUFFER_BIT", 0x00000100, 0 ),
    JS_PROP_DOUBLE_DEF("STENCIL_BUFFER_BIT", 0x00000400, 0 ),
    JS_PROP_DOUBLE_DEF("DEPTH_TEST", 0x0B71, 0 ),
    JS_PROP_DOUBLE_DEF("STENCIL_TEST", 0x0B90, 0 ),
    JS_PROP_DOUBLE_DEF("STENCIL_FUNC", 0x0B92, 0 ),
    JS_PROP_DOUBLE_DEF("STENCIL_VALUE_MASK", 0x0B93, 0 ),
    JS_PROP_DOUBLE_DEF("STENCIL_FAIL", 0x0B94, 0 ),
    JS_PROP_DOUBLE_DEF("STENCIL_PASS_DEPTH_FAIL", 0x0B95, 0 ),
    JS_PROP_DOUBLE_DEF("STENCIL_PASS_DEPTH_PASS", 0x0B96, 0 ),
    JS_PROP_DOUBLE_DEF("STENCIL_REF", 0x0B97, 0 ),
    JS_PROP_DOUBLE_DEF("STENCIL_WRITEMASK", 0x0B98, 0 ),
    JS_PROP_DOUBLE_DEF("STENCIL_BACK_FUNC", 0x8800, 0 ),
    JS_PROP_DOUBLE_DEF("STENCIL_BACK_FAIL", 0x8801, 0 ),
    JS_PROP_DOUBLE_DEF("STENCIL_BACK_PASS_DEPTH_FAIL", 0x8802, 0 ),
    JS_PROP_DOUBLE_DEF("STENCIL_BACK_PASS_DEPTH_PASS", 0x8803, 0 ),
    JS_PROP_DOUBLE_DEF("STENCIL_BACK_REF", 0x8CA3, 0 ),
    JS_PROP_DOUBLE_DEF("STENCIL_BACK_VALUE_MASK", 0x8CA4, 0 ),
    JS_PROP_DOUBLE_DEF("STENCIL_BACK_WRITEMASK", 0x8CA5, 0 ),
    JS_PROP_DOUBLE_DEF("KEEP", 0x1E00, 0 ),
    JS_PROP_DOUBLE_DEF("REPLACE", 0x1E01, 0 ),
    JS_PROP_DOUBLE_DEF("INCR", 0x1E02, 0 ),
    JS_PROP_DOUBLE_DEF("DECR", 0x1E03, 0 ),
    JS_PROP_DOUBLE_DEF("INVERT", 0x150A, 0 ),
    JS_PROP_DOUBLE_DEF("INCR_WRAP", 0x8507, 0 ),
    JS_PROP_DOUBLE_DEF("DECR_WRAP", 0x8508, 0 ),
    JS_PROP_DOUBLE_DEF("BLEND", 0x0BE2, 0 ),
    JS_PROP_DOUBLE_DEF("CULL_FACE", 0x0B44, 0 ),
    JS_PROP_DOUBLE_DEF("POLYGON_OFFSET_FILL", 0x8037, 0 ),
    JS_PROP_DOUBLE_DEF("SCISSOR_TEST", 0x0C11, 0 ),
    JS_PROP_DOUBLE_DEF("SAMPLE_ALPHA_TO_COVERAGE", 0x809E, 0 ),
    JS_PROP_DOUBLE_DEF("FUNC_ADD", 0x8006, 0 ),
    JS_PROP_DOUBLE_DEF("FUNC_SUBTRACT", 0x800A, 0 ),
    JS_PROP_DOUBLE_DEF("FUNC_REVERSE_SUBTRACT", 0x800B, 0 ),
    JS_PROP_DOUBLE_DEF("ONE", 1, 0 ),
    JS_PROP_DOUBLE_DEF("ZERO", 0, 0 ),
    JS_PROP_DOUBLE_DEF("SRC_ALPHA", 0x0302, 0 ),
    JS_PROP_DOUBLE_DEF("ONE_MINUS_SRC_ALPHA", 0x0303, 0 ),
    JS_PROP_DOUBLE_DEF("SRC_COLOR", 0x0300, 0 ),
    JS_PROP_DOUBLE_DEF("ONE_MINUS_SRC_COLOR", 0x0301, 0 ),
    JS_PROP_DOUBLE_DEF("DST_ALPHA", 0x0304, 0 ),
    JS_PROP_DOUBLE_DEF("ONE_MINUS_DST_ALPHA", 0x0305, 0 ),
    JS_PROP_DOUBLE_DEF("DST_COLOR", 0x0306, 0 ),
    JS_PROP_DOUBLE_DEF("ONE_MINUS_DST_COLOR", 0x0307, 0 ),
    JS_PROP_DOUBLE_DEF("CONSTANT_ALPHA", 0x8003, 0 ),
    JS_PROP_DOUBLE_DEF("ONE_MINUS_CONSTANT_ALPHA", 0x8004, 0 ),
    JS_PROP_DOUBLE_DEF("CONSTANT_COLOR", 0x8001, 0 ),
    JS_PROP_DOUBLE_DEF("ONE_MINUS_CONSTANT_COLOR", 0x8002, 0 ),
    JS_PROP_DOUBLE_DEF("FRONT", 0x0404, 0 ),
    JS_PROP_DOUBLE_DEF("BACK", 0x0405, 0 ),
    JS_PROP_DOUBLE_DEF("FRONT_AND_BACK", 0x0408, 0 ),
    JS_PROP_DOUBLE_DEF("CW", 0x0900, 0 ),
    JS_PROP_DOUBLE_DEF("CCW", 0x0901, 0 ),
    JS_PROP_DOUBLE_DEF("NEVER", 0x0200, 0 ),
    JS_PROP_DOUBLE_DEF("LESS", 0x0201, 0 ),
    JS_PROP_DOUBLE_DEF("EQUAL", 0x0202, 0 ),
    JS_PROP_DOUBLE_DEF("LEQUAL", 0x0203, 0 ),
    JS_PROP_DOUBLE_DEF("GREATER", 0x0204, 0 ),
    JS_PROP_DOUBLE_DEF("NOTEQUAL", 0x0205, 0 ),
    JS_PROP_DOUBLE_DEF("GEQUAL", 0x0206, 0 ),
    JS_PROP_DOUBLE_DEF("ALWAYS", 0x0207, 0 ),
    JS_PROP_DOUBLE_DEF("VIEWPORT", 0x0BA2, 0 ),
    JS_PROP_DOUBLE_DEF("SCISSOR_BOX", 0x0C10, 0 ),
    JS_PROP_DOUBLE_DEF("VERSION", 0x1F02, 0 ),
    JS_PROP_DOUBLE_DEF("SHADING_LANGUAGE_VERSION", 0x8B8C, 0 ),
    JS_PROP_DOUBLE_DEF("VENDOR", 0x1F00, 0 ),
    JS_PROP_DOUBLE_DEF("RENDERER", 0x1F01, 0 ),
    JS_PROP_DOUBLE_DEF("MAX_TEXTURE_IMAGE_UNITS", 0x8872, 0 ),
    JS_PROP_DOUBLE_DEF("MAX_VERTEX_ATTRIBS", 0x8869, 0 ),
    JS_PROP_DOUBLE_DEF("MAX_TEXTURE_SIZE", 0x0D33, 0 ),
    JS_PROP_DOUBLE_DEF("MAX_CUBE_MAP_TEXTURE_SIZE", 0x851C, 0 ),
    JS_PROP_DOUBLE_DEF("MAX_VERTEX_UNIFORM_VECTORS", 0x8DFB, 0 ),
    JS_PROP_DOUBLE_DEF("MAX_FRAGMENT_UNIFORM_VECTORS", 0x8DFD, 0 ),
    JS_PROP_DOUBLE_DEF("MAX_VARYING_VECTORS", 0x8DFC, 0 ),
    JS_PROP_DOUBLE_DEF("MAX_VERTEX_TEXTURE_IMAGE_UNITS", 0x8B4C, 0 ),
    JS_PROP_DOUBLE_DEF("MAX_COMBINED_TEXTURE_IMAGE_UNITS", 0x8B4D, 0 ),
    JS_PROP_DOUBLE_DEF("ALIASED_LINE_WIDTH_RANGE", 0x846E, 0 ),
    JS_PROP_DOUBLE_DEF("ALIASED_POINT_SIZE_RANGE", 0x846D, 0 ),
    JS_PROP_DOUBLE_DEF("MAX_VIEWPORT_DIMS", 0x0D3A, 0 ),
    JS_PROP_DOUBLE_DEF("SAMPLES", 0x80A9, 0 ),
    JS_PROP_DOUBLE_DEF("MAX_SAMPLES", 0x8D57, 0 ),
    JS_PROP_DOUBLE_DEF("IMPLEMENTATION_COLOR_READ_FORMAT", 0x8B9B, 0 ),
    JS_PROP_DOUBLE_DEF("IMPLEMENTATION_COLOR_READ_TYPE", 0x8B9A, 0 ),
    JS_PROP_DOUBLE_DEF("UNPACK_ALIGNMENT", 0x0CF5, 0 ),
    JS_PROP_DOUBLE_DEF("UNPACK_ROW_LENGTH", 0x0CF2, 0 ),
    JS_PROP_DOUBLE_DEF("UNPACK_SKIP_PIXELS", 0x0CF4, 0 ),
    JS_PROP_DOUBLE_DEF("UNPACK_SKIP_ROWS", 0x0CF3, 0 ),
    JS_PROP_DOUBLE_DEF("UNPACK_FLIP_Y_WEBGL", 0x9240, 0 ),
    JS_PROP_DOUBLE_DEF("UNPACK_PREMULTIPLY_ALPHA_WEBGL", 0x9241, 0 ),
    JS_PROP_DOUBLE_DEF("UNPACK_COLORSPACE_CONVERSION_WEBGL", 0x9243, 0 ),
    JS_PROP_DOUBLE_DEF("RGBA", 0x1908, 0 ),
    JS_PROP_DOUBLE_DEF("UNSIGNED_BYTE", 0x1401, 0 ),
    JS_PROP_DOUBLE_DEF("RGBA8", 0x8058, 0 ),
    JS_PROP_DOUBLE_DEF("RGB8", 0x8051, 0 ),
    JS_PROP_DOUBLE_DEF("SRGB8_ALPHA8", 0x8C43, 0 ),
    JS_PROP_DOUBLE_DEF("SRGB8", 0x8C41, 0 ),
    JS_PROP_DOUBLE_DEF("NO_ERROR", 0, 0 ),
    JS_PROP_DOUBLE_DEF("TEXTURE_2D", 0x0DE1, 0 ),
    JS_PROP_DOUBLE_DEF("TEXTURE_CUBE_MAP", 0x8513, 0 ),
    JS_PROP_DOUBLE_DEF("TEXTURE_3D", 0x806F, 0 ),
    JS_PROP_DOUBLE_DEF("TEXTURE_2D_ARRAY", 0x8C1A, 0 ),
    JS_PROP_DOUBLE_DEF("TEXTURE_CUBE_MAP_POSITIVE_X", 0x8515, 0 ),
    JS_PROP_DOUBLE_DEF("TEXTURE_CUBE_MAP_NEGATIVE_X", 0x8516, 0 ),
    JS_PROP_DOUBLE_DEF("TEXTURE_CUBE_MAP_POSITIVE_Y", 0x8517, 0 ),
    JS_PROP_DOUBLE_DEF("TEXTURE_CUBE_MAP_NEGATIVE_Y", 0x8518, 0 ),
    JS_PROP_DOUBLE_DEF("TEXTURE_CUBE_MAP_POSITIVE_Z", 0x8519, 0 ),
    JS_PROP_DOUBLE_DEF("TEXTURE_CUBE_MAP_NEGATIVE_Z", 0x851A, 0 ),
    JS_PROP_DOUBLE_DEF("TEXTURE_MIN_FILTER", 0x2801, 0 ),
    JS_PROP_DOUBLE_DEF("TEXTURE_MAG_FILTER", 0x2800, 0 ),
    JS_PROP_DOUBLE_DEF("TEXTURE_WRAP_S", 0x2802, 0 ),
    JS_PROP_DOUBLE_DEF("TEXTURE_WRAP_T", 0x2803, 0 ),
    JS_PROP_DOUBLE_DEF("CLAMP_TO_EDGE", 0x812F, 0 ),
    JS_PROP_DOUBLE_DEF("REPEAT", 0x2901, 0 ),
    JS_PROP_DOUBLE_DEF("MIRRORED_REPEAT", 0x8370, 0 ),
    JS_PROP_DOUBLE_DEF("NEAREST", 0x2600, 0 ),
    JS_PROP_DOUBLE_DEF("LINEAR", 0x2601, 0 ),
    JS_PROP_DOUBLE_DEF("NEAREST_MIPMAP_NEAREST", 0x2700, 0 ),
    JS_PROP_DOUBLE_DEF("LINEAR_MIPMAP_NEAREST", 0x2701, 0 ),
    JS_PROP_DOUBLE_DEF("NEAREST_MIPMAP_LINEAR", 0x2702, 0 ),
    JS_PROP_DOUBLE_DEF("LINEAR_MIPMAP_LINEAR", 0x2703, 0 ),
    JS_PROP_DOUBLE_DEF("TEXTURE0", 0x84C0, 0 ),
    JS_PROP_DOUBLE_DEF("LINK_STATUS", 0x8B82, 0 ),
    JS_PROP_DOUBLE_DEF("VALIDATE_STATUS", 0x8B83, 0 ),
    JS_PROP_DOUBLE_DEF("ATTACHED_SHADERS", 0x8B85, 0 ),
    JS_PROP_DOUBLE_DEF("ACTIVE_UNIFORMS", 0x8B86, 0 ),
    JS_PROP_DOUBLE_DEF("ACTIVE_ATTRIBUTES", 0x8B89, 0 ),
    JS_PROP_DOUBLE_DEF("FLOAT_VEC2", 0x8B50, 0 ),
    JS_PROP_DOUBLE_DEF("FLOAT_VEC3", 0x8B51, 0 ),
    JS_PROP_DOUBLE_DEF("FLOAT_VEC4", 0x8B52, 0 ),
    JS_PROP_DOUBLE_DEF("INT_VEC2", 0x8B53, 0 ),
    JS_PROP_DOUBLE_DEF("INT_VEC3", 0x8B54, 0 ),
    JS_PROP_DOUBLE_DEF("INT_VEC4", 0x8B55, 0 ),
    JS_PROP_DOUBLE_DEF("FLOAT_MAT4", 0x8B5C, 0 ),
    JS_PROP_DOUBLE_DEF("SAMPLER_2D", 0x8B5E, 0 ),
    JS_PROP_DOUBLE_DEF("SAMPLER_CUBE", 0x8B60, 0 ),
    JS_PROP_DOUBLE_DEF("SAMPLER_2D_SHADOW", 0x8B62, 0 ),
    JS_PROP_DOUBLE_DEF("SAMPLER_2D_ARRAY", 0x8DC1, 0 ),
    JS_PROP_DOUBLE_DEF("SAMPLER_2D_ARRAY_SHADOW", 0x8DC4, 0 ),
    JS_PROP_DOUBLE_DEF("SAMPLER_CUBE_SHADOW", 0x8DC5, 0 ),
    JS_PROP_DOUBLE_DEF("FRAMEBUFFER", 0x8D40, 0 ),
    JS_PROP_DOUBLE_DEF("RENDERBUFFER", 0x8D41, 0 ),
    JS_PROP_DOUBLE_DEF("FRAMEBUFFER_COMPLETE", 0x8CD5, 0 ),
    JS_PROP_DOUBLE_DEF("COLOR_ATTACHMENT0", 0x8CE0, 0 ),
    JS_PROP_DOUBLE_DEF("DEPTH_ATTACHMENT", 0x8D00, 0 ),
    JS_PROP_DOUBLE_DEF("STENCIL_ATTACHMENT", 0x8D20, 0 ),
    JS_PROP_DOUBLE_DEF("DEPTH_STENCIL_ATTACHMENT", 0x821A, 0 ),
    JS_PROP_DOUBLE_DEF("DEPTH_STENCIL", 0x84F9, 0 ),
    JS_PROP_END,
};

static const JSClassDef js_gl_obj =
    JS_OBJECT_DEF("WebGLContext", js_gl);

static const JSPropDef js_global_object[] = {
    JS_PROP_CLASS_DEF("Object", &js_object_class),
    JS_PROP_CLASS_DEF("Function", &js_function_class),
    JS_PROP_CLASS_DEF("Number", &js_number_class),
    JS_PROP_CLASS_DEF("Boolean", &js_boolean_class),
    JS_PROP_CLASS_DEF("String", &js_string_class),
    JS_PROP_CLASS_DEF("Array", &js_array_class),
    JS_PROP_CLASS_DEF("Math", &js_math_obj),
    JS_PROP_CLASS_DEF("Date", &js_date_class),
    JS_PROP_CLASS_DEF("JSON", &js_json_obj),
    JS_PROP_CLASS_DEF("RegExp", &js_regexp_class),

    JS_PROP_CLASS_DEF("Error", &js_error_class),
    JS_PROP_CLASS_DEF("EvalError", &js_eval_error_class),
    JS_PROP_CLASS_DEF("RangeError", &js_range_error_class),
    JS_PROP_CLASS_DEF("ReferenceError", &js_reference_error_class),
    JS_PROP_CLASS_DEF("SyntaxError", &js_syntax_error_class),
    JS_PROP_CLASS_DEF("TypeError", &js_type_error_class),
    JS_PROP_CLASS_DEF("URIError", &js_uri_error_class),
    JS_PROP_CLASS_DEF("InternalError", &js_internal_error_class),

    JS_PROP_CLASS_DEF("ArrayBuffer", &js_array_buffer_class),
    JS_PROP_CLASS_DEF("Uint8ClampedArray", &js_Uint8ClampedArray_class),
    JS_PROP_CLASS_DEF("Int8Array", &js_Int8Array_class),
    JS_PROP_CLASS_DEF("Uint8Array", &js_Uint8Array_class),
    JS_PROP_CLASS_DEF("Int16Array", &js_Int16Array_class),
    JS_PROP_CLASS_DEF("Uint16Array", &js_Uint16Array_class),
    JS_PROP_CLASS_DEF("Int32Array", &js_Int32Array_class),
    JS_PROP_CLASS_DEF("Uint32Array", &js_Uint32Array_class),
    JS_PROP_CLASS_DEF("Float32Array", &js_Float32Array_class),
    JS_PROP_CLASS_DEF("Float64Array", &js_Float64Array_class),

    JS_CFUNC_DEF("parseInt", 2, js_number_parseInt ),
    JS_CFUNC_DEF("parseFloat", 1, js_number_parseFloat ),
    JS_CFUNC_DEF("eval", 1, js_global_eval),
    JS_CFUNC_DEF("isNaN", 1, js_global_isNaN ),
    JS_CFUNC_DEF("isFinite", 1, js_global_isFinite ),

    JS_PROP_DOUBLE_DEF("Infinity", 1.0 / 0.0, 0 ),
    JS_PROP_DOUBLE_DEF("NaN", NAN, 0 ),
    JS_PROP_UNDEFINED_DEF("undefined", 0 ),
    /* Note: null is expanded as the global object in js_global_object[] */
    JS_PROP_NULL_DEF("globalThis", 0 ),

    JS_PROP_CLASS_DEF("console", &js_console_obj),
    JS_PROP_CLASS_DEF("performance", &js_performance_obj),
    JS_PROP_CLASS_DEF("gl", &js_gl_obj),
    JS_CFUNC_DEF("print", 1, js_print),
    JS_CFUNC_DEF("setClearColor", 3, js_setClearColor),
    JS_CFUNC_DEF("requestAnimationFrame", 1, js_requestAnimationFrame),
    JS_CFUNC_DEF("cancelAnimationFrame", 1, js_cancelAnimationFrame),
    JS_CFUNC_DEF("__dom_noop", 0, js_dom_noop),
    JS_CFUNC_DEF("__dom_createElement", 1, js_dom_createElement),
    JS_CFUNC_DEF("__dom_createElementNS", 2, js_dom_createElementNS),
    JS_CFUNC_DEF("__dom_getContext", 1, js_dom_getContext),
    JS_CFUNC_SPECIAL_DEF("Image", 2, constructor, js_Image),
    JS_CFUNC_DEF("__loadImage", 2, js_loadImage),
    JS_CFUNC_DEF("__freeImage", 1, js_freeImage),
#ifdef CONFIG_CLASS_EXAMPLE
    JS_PROP_CLASS_DEF("Rectangle", &js_rectangle_class),
    JS_PROP_CLASS_DEF("FilledRectangle", &js_filled_rectangle_class),
#else
    JS_CFUNC_DEF("gc", 0, js_gc),
    JS_CFUNC_DEF("load", 1, js_load),
    JS_CFUNC_DEF("setTimeout", 2, js_setTimeout),
    JS_CFUNC_DEF("clearTimeout", 1, js_clearTimeout),
#endif
    JS_PROP_END,
};

/* Additional C function declarations (only useful for C
   closures). They are always defined first. */
static const JSPropDef js_c_function_decl[] = {
    /* must come first if "bind" is defined */
    JS_CFUNC_SPECIAL_DEF("bound", 0, generic_params, js_function_bound ),
#ifdef CONFIG_CLASS_EXAMPLE
    JS_CFUNC_SPECIAL_DEF("rectangle_closure_test", 0, generic_params, js_rectangle_closure_test ),
#endif
    JS_PROP_END,
};

int main(int argc, char **argv)
{
    return build_atoms("js_stdlib", js_global_object, js_c_function_decl, argc, argv);
}
