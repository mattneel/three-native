# KICKSTART.md

## What is this?

Native runtime for Three.js games. Write Three.js, ship to Steam as a ~3MB binary. Same codebase runs in browser.

No Electron. No Chromium. No bullshit.

## The Stack

```
┌─────────────────────────────────┐
│  Your Game (Three.js)           │  ← Unmodified Three.js code
├─────────────────────────────────┤
│  Three.js                       │  ← Submoduled, not forked
├─────────────────────────────────┤
│  Browser Shim                   │  ← THE WORK: WebGL, DOM, etc.
├─────────────────────────────────┤
│  mquickjs                       │  ← 100KB JS engine
├─────────────────────────────────┤
│  Native Backend (Zig)           │  ← sokol or wgpu-native
└─────────────────────────────────┘
```

## Why mquickjs?

- 10KB RAM, 100KB ROM
- Bellard engineering
- ES5 subset forces clean code
- JS isn't the hot path anyway - GPU calls are
- Can swap to V8/JSC later if needed (we won't need to)

## The Shim Surface

Three.js touches these browser APIs:

### Critical (Blocks rendering)
- `WebGLRenderingContext` / `WebGL2RenderingContext` - all the gl.* calls
- `HTMLCanvasElement` - getContext, width, height
- `requestAnimationFrame` - frame loop
- `performance.now()` - timing

### Asset Loading
- `Image` - texture loading
- `createImageBitmap` - async image decode
- `fetch` - GLTF, textures, etc.
- `FileReader` - drag/drop assets
- `URL.createObjectURL` / `revokeObjectURL` - blob handling

### Input
- `addEventListener` - mouse, keyboard, wheel, resize
- `pointer lock API` - FPS controls
- `gamepad API` - controller support

### Audio (Phase 2)
- `AudioContext` - Web Audio API
- `AudioBuffer`, `GainNode`, etc.

### Misc
- `document.createElement('canvas')` - offscreen canvases
- `TextDecoder` - GLTF parsing
- `console.*` - debugging

## Milestones

### M0: Proof of Life ✅
- [x] mquickjs compiles in Zig build
- [x] Call JS from Zig
- [x] Call Zig from JS
- [x] Print "hello from mquickjs" 

### M1: Triangle
- [ ] sokol_gfx window opens
- [ ] Hardcoded triangle renders
- [ ] JS controls clear color

### M2: Cube via Shim
- [ ] WebGLRenderingContext shim (subset)
- [ ] gl.bindBuffer, bindTexture, bindShader basics
- [ ] JS draws a cube through the shim

### M3: Three.js Loads
- [ ] Three.js imports without error
- [ ] Scene, Camera, Renderer construct
- [ ] BoxGeometry + MeshBasicMaterial renders

### M4: Real Demo
- [ ] GLTF loading works
- [ ] OrbitControls work
- [ ] Lighting works
- [ ] Screenshot goes viral

### M5: Ship It
- [ ] macOS build
- [ ] Windows build  
- [ ] Linux build
- [ ] Steam demo page

## Non-Goals (For Now)

- 100% WebGL coverage (just what Three.js needs)
- WebXR (cool but later)
- Node.js compatibility (this isn't Node)
- Hot reload (nice to have, not critical)

## Architecture Decisions

### Why Zig?
- C interop is free
- Cross-compilation is trivial
- No runtime, no GC
- It's good

### Why sokol?
- Single-file headers
- Zig bindings exist
- Metal/D3D11/OpenGL backends
- floooh knows what he's doing

### Why not wgpu-native?
- Could swap later
- sokol is simpler to start
- Less abstraction to debug

## Getting Started

```bash
git clone --recursive https://github.com/mattneel/three-native
cd three-native
zig build run
```

Requires: Zig 0.15+ (that's it - builds anywhere Zig builds)

The build system orchestrates everything: mquickjs stdlib generation, C compilation, and Zig linking - all using Zig's built-in C compiler for full cross-platform portability.

## Contributing

This is early. If you want to help:

1. Pick an unimplemented gl.* function
2. Implement it in src/shim/webgl.zig
3. Add a test
4. PR

Or just show up in issues with ideas.

## License

MIT
