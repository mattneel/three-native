# Platform and Rendering

The platform layer provides window management, input capture, timing, and the
native rendering backend. The first implementation is built around `sokol`.

## Windowing

- Single primary window in early phases.
- Resizable window; resize events update the canvas size.
- High-DPI scaling is supported via platform-provided scale factor.

## Rendering Backend

`sokol_gfx` is the initial backend because it provides:

- Small, single-header integration.
- Backends for Metal, D3D11, and OpenGL.
- Simple, explicit resource lifetimes.

The design keeps a clean boundary so that `wgpu-native` can be evaluated later.

## Frame Lifecycle

1. Begin frame and clear swapchain.
2. Apply state updates from the WebGL shim.
3. Submit draw calls.
4. End frame and present.

All GPU resource creation and destruction happens on the main thread to keep
ordering explicit and avoid cross-thread driver issues.
