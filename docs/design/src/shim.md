# Browser Shim

The shim provides just enough browser surface area for Three.js to run. It is
not a general-purpose DOM implementation. The guiding rule is: implement what
Three.js touches, no more.

## API Surface (Initial)

- `WebGLRenderingContext` and `WebGL2RenderingContext` (subset)
- `HTMLCanvasElement` with `getContext`, width, height
- `requestAnimationFrame` and `cancelAnimationFrame`
- `performance.now()`
- `Image`, `createImageBitmap`
- `fetch`, `FileReader`, `URL.createObjectURL`, `URL.revokeObjectURL`
- Input via `addEventListener` (mouse, keyboard, wheel, resize)
- Pointer lock and gamepad APIs (later milestones)
- `console.*` for debugging

## WebGL Mapping

WebGL calls are translated to native backend calls. The mapping is explicit:

- WebGL buffers map to native vertex/index buffers.
- WebGL textures map to native textures.
- WebGL programs map to native shader pipelines.
- WebGL state is tracked in a lightweight state cache to reduce redundant calls.

The shim does not aim for full WebGL conformance. It aims for correctness on
the Three.js usage path.

## Canvas and Document

- A single primary canvas is created at startup.
- `document.createElement("canvas")` returns an offscreen canvas object with a
  separate WebGL context if needed by Three.js helpers.
- DOM traversal and layout are intentionally absent.

## Event Dispatch

Platform events are normalized and dispatched into the shim. The shim delivers
synthetic browser-style event objects to JS listeners.
