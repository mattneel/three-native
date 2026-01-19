# Memory and Concurrency

This runtime follows Tiger Style rules: allocate early, bound the hot path, and
keep control flow explicit.

## Memory Strategy

### Rules

- Allocate at startup; avoid malloc in the frame loop.
- Use fixed-size pools for hot objects (buffers, textures, programs).
- Use arenas for transient data (asset decode, loader intermediates).
- Keep ownership explicit and single-threaded in phase 1.

### Handle Tables

Native GPU objects are referenced from JS via numeric handles. The host stores
the real objects in fixed-size tables. Each table entry is either empty or live.

Initial caps are conservative for early milestones and can be raised later:

- Buffers: 4096
- Textures: 2048
- Programs: 1024
- Framebuffers: 512
- Renderbuffers: 512
- Vertex arrays: 1024

Handle tables are sized and allocated at init and never grow at runtime.

### Allocation Map

- **Long-lived**: platform, renderer state, handle tables
- **Per-frame**: scratch buffers, transient state (arena reset each frame)
- **Per-asset**: decode buffers, loader state (freed after upload)

## Concurrency Plan

Phase 1 is single-threaded for determinism. Future phases may add background
threads for IO and decode.

### Threads (Future)

- **Main thread**: JS execution, WebGL shim, GPU submission.
- **IO thread**: file reads and network fetch (if enabled).
- **Decode thread**: image decode and mesh processing.

### Queues

When background work is added:

- SPSC ring buffers for worker-to-main notifications.
- MPSC queue for multiple IO sources (if needed).
- No locks in the frame loop; consumption is bounded per frame.

### Safety

- Background threads never touch GPU objects directly.
- Only the main thread creates and destroys GPU resources.
- Ownership is explicit: workers produce data buffers, main thread consumes.
# Memory and Concurrency

The runtime follows Tiger Style memory and control flow guidelines to keep
behavior predictable and fast.

## Memory Strategy

Rules:

- Allocate long-lived structures at startup.
- Avoid heap allocation on the hot path.
- Use fixed-size pools for frequently created objects.
- Make ownership explicit in API boundaries.

Planned allocations:

- Handle tables for WebGL objects (buffers, textures, programs).
- Event queues sized to a fixed upper bound.
- Scratch arenas for asset loading and parsing.

## Concurrency Model

Initial design is single-threaded for deterministic behavior:

- JS execution, event dispatch, and render submission happen on the main thread.
- The render backend runs on the same thread as the shim.

Planned background work (later phase):

- Asset IO and image decode on worker threads.
- Communication via bounded, single-producer queues.
- All GPU resource creation remains on the main thread.

## Control Flow

- No recursion in hot paths.
- Bounded loops for event and command processing.
- Parent function drives the control flow; helpers are pure computation.
