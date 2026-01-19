# Runtime

The runtime embeds `mquickjs` as the JavaScript engine. A single JS context is
created and kept for the lifetime of the app. All shim APIs are exposed as
host bindings registered on startup.

## Execution Model

- One JS runtime and one primary context.
- The main thread owns JS execution.
- `requestAnimationFrame` drives the app tick.
- Host bindings are synchronous in the initial phase.

## Module Loading

`mquickjs` targets ES5, so user code should be bundled (Rollup, esbuild, etc.)
into a single entry script. The runtime loads that entry file and evaluates it
inside the JS context.

Future work may add module resolution and source maps, but the baseline is a
single bundled file to keep startup small and predictable.

## Native Handles

Browser objects that map to native resources (textures, buffers, programs,
framebuffers) are represented in JS as small wrapper objects with an internal
numeric handle. The host stores the real objects in tables keyed by that handle.

Rules:

- Handle tables are fixed-size or pooled at init.
- Handles are reused only after explicit destruction.
- JS wrapper objects register finalizers that release native resources.

## Error Handling

- JS exceptions propagate to the host as Zig errors.
- Zig errors thrown by host bindings are converted into JS exceptions.
- On fatal errors, the runtime surfaces a clear error message and exits.
