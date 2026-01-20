# three-native

Native runtime for Three.js games. Write Three.js, ship to Steam as a small
native binary. Same codebase runs in browser.

No Electron. No Chromium. No bullshit.

## What This Is

`three-native` is a Zig-based runtime that hosts an unmodified Three.js build
on top of a lightweight JavaScript engine and a browser API shim. The goal is
to make Three.js apps run natively with minimal footprint while keeping the
existing Three.js codebase intact.

## Stack

```
┌─────────────────────────────────┐
│  Your Game (Three.js)           │  ← Unmodified Three.js code
├─────────────────────────────────┤
│  Three.js (submodule)           │
├─────────────────────────────────┤
│  Browser Shim                   │  ← WebGL, DOM, etc.
├─────────────────────────────────┤
│  mquickjs                       │  ← 100KB JS engine
├─────────────────────────────────┤
│  Native Backend (Zig)           │  ← sokol or wgpu-native
└─────────────────────────────────┘
```

## Why mquickjs?

- 10KB RAM, 100KB ROM
- ES5 subset encourages clean code
- JS is not the hot path; GPU calls are
- Can swap to V8/JSC later if needed

## Shim Surface (High Level)

Three.js touches these browser APIs:

- WebGL: `WebGLRenderingContext` / `WebGL2RenderingContext`
- Canvas: `HTMLCanvasElement`, `getContext`, width/height
- Timing: `requestAnimationFrame`, `performance.now()`
- Assets: `Image`, `createImageBitmap`, `fetch`, `FileReader`, `URL.*`
- Input: `addEventListener`, pointer lock, gamepad API
- Audio (phase 2): `AudioContext`, `AudioBuffer`, `GainNode`, etc.
- Misc: `document.createElement('canvas')`, `TextDecoder`, `console.*`

## Getting Started

```bash
git clone --recursive https://github.com/mattneel/three-native
cd three-native
zig build run -- examples/creating-a-scene.js
```

Requires:

- Zig 0.15.2+
- Node.js + npm (used to build the ES5 Three.js bundle on first run)

Notes:

- `zig build run` automatically runs `npm install` and builds `examples/three.es5.js`.
- You can rebuild the bundle manually with `zig build three-es5`.
- Three.js is a submodule, so `--recursive` is required on clone.

## Vendored Dependencies

- `deps/sokol-zig` is vendored to keep Sokol patches reproducible. We raise
  `SG_MAX_UNIFORMBLOCK_MEMBERS` to 64 to match current Three.js shader needs.

## Status

Early stage. Milestones are tracked in `KICKSTART.md`.

## Known Warnings

When running Three.js examples, you may see Sokol warnings like:

```
GL_UNIFORMBLOCK_NAME_NOT_FOUND_IN_SHADER: uniform block name not found in shader
GL_VERTEX_ATTRIBUTE_NOT_FOUND_IN_SHADER: vertex attribute not found in shader
```

**These are benign.** They occur because:

1. Three.js shaders declare many standard uniforms/attributes for optional features
2. The GLSL compiler optimizes out unused ones
3. Sokol logs a warning when `glGetUniformLocation`/`glGetAttribLocation` returns -1

The runtime uses preprocessor-aware filtering to minimize these, but the GLSL
compiler's dead code elimination is more aggressive than our heuristics. Unused
uniforms simply won't be applied, which is correct behavior.

## Docs

- Design docs (GitHub Pages): https://mattneel.github.io/three-native/docs/design/
- Local mdbook source: `docs/design`

## Contributing

If you want to help:

1. Pick an unimplemented `gl.*` function
2. Implement it in `src/shim/webgl.zig`
3. Add a test
4. Open a PR

Issues and ideas are welcome.

## License

MIT
