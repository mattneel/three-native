# Testing

Testing focuses on correctness of the shim and determinism of the runtime.

## Goals

- Verify WebGL API behavior used by Three.js.
- Validate asset loading and IO paths.
- Keep tests fast and runnable on CI.
- Provide deterministic failures with useful diagnostics.

## Test Types

### Unit Tests

- Handle table allocation and reuse.
- WebGL state cache transitions.
- JS binding argument validation and error paths.
- Math helpers and utility functions.

### Integration Tests

- Execute bundled JS fixtures under `mquickjs`.
- Validate that expected WebGL calls are observed.
- Exercise `fetch`, `Image`, and `FileReader` shims.

### Rendering Tests

- Render simple scenes (triangle, cube).
- Read back pixels and compare with a reference hash.
- Use tolerances for driver variance.

Rendering tests are optional on CI unless a GPU runner is available.

### Fuzz Tests

- Fuzz parsers and binary decoders (GLTF, image formats).
- Run with `zig build test --fuzz` for long-running sessions.

## Test Fixtures

JS fixtures live alongside the tests and are bundled into a single file for
execution by `mquickjs`. Fixtures should be minimal and deterministic.

## Failure Diagnostics

On failure:

- Dump the last N WebGL calls.
- Log the JS exception and stack if present.
- Save a PNG of the render output (if available).
