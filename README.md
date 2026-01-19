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

```
git clone --recursive https://github.com/mattneel/three-native
cd three-native
zig build run
```

## Status

Early stage. Milestones are tracked in `KICKSTART.md`.

## Contributing

If you want to help:

1. Pick an unimplemented `gl.*` function
2. Implement it in `src/shim/webgl.zig`
3. Add a test
4. Open a PR

Issues and ideas are welcome.

## License

MIT
