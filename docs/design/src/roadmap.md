# Roadmap

This roadmap mirrors `KICKSTART.md`. It is intentionally short and focused on
the minimal set of milestones required to run a real Three.js demo.

## M0: Proof of Life

- mquickjs compiles in Zig build
- Call JS from Zig
- Call Zig from JS
- Print "hello from JS"

## M1: Triangle

- sokol_gfx window opens
- Hardcoded triangle renders
- JS controls clear color

## M2: Cube via Shim

- WebGLRenderingContext shim (subset)
- Implement core GL calls (bindBuffer, bindTexture, shader basics)
- JS draws a cube through the shim

## M3: Three.js Loads

- Three.js imports without error
- Scene, Camera, Renderer construct
- BoxGeometry + MeshBasicMaterial renders

## M4: Real Demo

- GLTF loading works
- OrbitControls work
- Lighting works
- Demo quality screenshot

## M5: Ship It

- macOS build
- Windows build
- Linux build
- Steam demo page
