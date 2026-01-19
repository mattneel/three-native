# Architecture

At a high level, `three-native` embeds a JavaScript runtime and a minimal
browser API shim on top of a native rendering backend.

```
┌─────────────────────────────────┐
│  Your Game (Three.js)           │
├─────────────────────────────────┤
│  Three.js (submodule)           │
├─────────────────────────────────┤
│  Browser Shim                   │  WebGL, DOM, timing, input
├─────────────────────────────────┤
│  mquickjs                       │  JS runtime
├─────────────────────────────────┤
│  Native Backend (Zig)           │  sokol or wgpu-native
└─────────────────────────────────┘
```

## Core Components

- **Host runtime (Zig)**: Owns the process lifecycle and platform integration.
- **JS runtime**: `mquickjs` with a single global context.
- **Browser shim**: Implements the small subset of browser APIs that Three.js
  expects, especially WebGL.
- **Render backend**: Translates WebGL-like calls into native GPU API calls.
- **Platform layer**: Window creation, input capture, timing, and event pumps.

## Boot Sequence

1. Initialize platform layer and create the primary window.
2. Initialize the rendering backend and device state.
3. Initialize the JS runtime and register host bindings.
4. Load the Three.js bundle and user entry module.
5. Create a canvas and WebGL context for the app.
6. Enter the frame loop and start `requestAnimationFrame`.

## Frame Loop

Each frame follows a fixed, explicit order:

1. Poll platform events (input, resize, focus).
2. Dispatch events into the shim.
3. Run one `requestAnimationFrame` tick in JS.
4. Translate WebGL calls into native backend commands.
5. Present the frame.

The loop is single-threaded in the initial phase to keep behavior deterministic.
