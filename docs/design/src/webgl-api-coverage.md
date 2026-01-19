# WebGL API Coverage

This spreadsheet tracks every `gl.*` method/constant referenced by Three.js and
the current shim coverage status.

- **Spreadsheet**: `webgl-api-coverage.csv`
- **Source**: unique `gl.` identifiers from `deps/three`
- **Status legend**: `implemented`, `partial`, `missing`

Notes:
- The list includes WebGL2-only APIs used by Three.js. Those are marked
  `webgl2` and can be deferred for the WebGL1 shim.
- Sampler uniforms are tracked, but texture binding is still pending.
