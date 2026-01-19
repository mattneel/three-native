# Introduction

`three-native` is a Zig runtime that hosts unmodified Three.js code inside a
tiny native application. The goal is to ship a small, fast executable without
Electron or Chromium while keeping the same codebase runnable in the browser.

This book captures the design intent for the runtime. It is forward-looking
and will be updated as the implementation evolves.

## Goals

- Run unmodified Three.js applications.
- Keep the native binary small and portable.
- Support macOS, Windows, and Linux with one codebase.
- Provide a thin, predictable browser API shim (only what Three.js needs).
- Keep hot paths allocation-free after initialization.

## Non-Goals

- Full browser DOM compatibility.
- Node.js compatibility.
- 100 percent WebGL feature coverage.
- WebXR (not in early milestones).
- Hot reload (nice to have, not critical).

## Constraints and Assumptions

- JavaScript engine is `mquickjs` (ES5 subset).
- Initial graphics backend is `sokol` (wgpu-native is a possible later swap).
- Main loop targets 60 FPS (16.6 ms frame budget).
- Shader compilation and image decode may be moved off-thread later.
- Design is driven by current Three.js usage patterns.

## Design Principles (Tiger Style)

1. Napkin math before implementation.
2. Data structures match access patterns.
3. Static allocation at startup, explicit lifetimes.
4. Bounded loops and explicit control flow.

Milestones and near-term scope are tracked in `KICKSTART.md`.
