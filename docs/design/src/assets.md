# Assets and IO

Assets are loaded through browser-like APIs but resolved to native IO.

## `fetch`

`fetch` resolves URLs relative to a configurable asset root. In the initial
phase, only local files are supported. Future phases may add HTTP support.

Guidelines:

- URL parsing is minimal; no redirects in phase 1.
- Responses expose `arrayBuffer()` and `text()` as needed by Three.js loaders.
- Binary data stays in contiguous buffers owned by the host.

## Images

- `Image` and `createImageBitmap` load common formats (PNG, JPEG).
- Decode may be synchronous initially; later moved to background threads.
- Decoded pixel data is uploaded to GPU via the WebGL shim.

## FileReader and Blobs

- `FileReader` supports the subset used for drag-and-drop assets.
- `URL.createObjectURL` returns a short-lived token that maps to a host buffer.
- `URL.revokeObjectURL` releases that buffer promptly.
