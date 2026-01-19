# Roadmap

This roadmap follows Tiger Style phased development. Each phase is fully tested
before proceeding. We validate with napkin math, build foundations first, and
never accumulate tech debt.

## Planning Philosophy

1. **Napkin math before code** — Validate feasibility upfront
2. **Foundation before features** — Core types, then behavior  
3. **Test before complexity** — Each phase fully tested
4. **No tech debt** — Do it right or skip it

---

## M0: Proof of Life ✅

**Status: Complete**

- [x] mquickjs compiles in Zig build
- [x] Call JS from Zig
- [x] Call Zig from JS  
- [x] Print "hello from mquickjs"

---

## M1: Triangle

Open a native window and render a triangle. JS controls the clear color.

### Napkin Math

```
Frame budget: 16.6ms (60 FPS target)
├── JS eval overhead: ~1ms (mquickjs is fast for small scripts)
├── Clear color update: ~0.01ms
├── Triangle draw: ~0.1ms
├── Present/swap: ~1ms
└── Buffer: 14ms
Verdict: ✓ Plenty of headroom
```

### Phase 1.0: Design Validation ✅

**Goals**
- [x] sokol dependency added to build.zig
- [x] Window creation API defined
- [x] JS↔Zig color binding API defined

**Deliverables**
- [x] `src/platform/window.zig` - type definitions only
- [x] `src/shim/globals.zig` - JS global bindings skeleton
- [x] Test fixture: empty window opens and closes

**Exit Criteria**
- [x] sokol compiles with Zig
- [x] Types defined and compile
- [x] Build still works on Linux (CI green)

### Phase 1.1: Native Window ✅

**Goals**
- [x] Window opens with sokol_app
- [x] Window closes cleanly
- [x] Basic event loop runs

**Implementation**
- [x] Initialize sokol_app
- [x] Create window with fixed size (800x600)
- [x] Handle close event
- [x] Pump events in main loop

**Tests Required**
- [x] Window opens without crash
- [ ] Window closes without leak (valgrind/GPA)
- [ ] 1000 open/close cycles without leak

**Exit Criteria**
- [x] Black window appears
- [x] Closes on X button / ESC
- [ ] No memory leaks (not formally verified yet)

### Phase 1.2: Clear Color from Zig ✅

**Goals**
- [x] sokol_gfx initialized
- [x] Frame clears to solid color
- [x] Color changeable from Zig

**Implementation**
- [x] Initialize sokol_gfx with sokol_app
- [x] Create default pass action
- [x] Clear to configurable RGB
- [x] Present frame

**Tests Required**
- [ ] Clear to red, verify framebuffer (screenshot test)
- [ ] Clear to green, verify
- [ ] Clear to blue, verify
- [x] 60 FPS sustained for 10 seconds (2500 frames @ ~60fps = 41 seconds)

**Exit Criteria**
- [x] Solid color fills window
- [x] Color changes work (animated cycling demo)
- [x] Stable 60 FPS

### Phase 1.3: Triangle Rendering

**Goals**
- [ ] Hardcoded triangle vertices
- [ ] Basic shader compiles
- [ ] Triangle visible on screen

**Implementation**
- [ ] Create vertex buffer with 3 vertices
- [ ] Write minimal vertex/fragment shader
- [ ] Create pipeline
- [ ] Draw call in frame loop

**Tests Required**
- [ ] Triangle visible (screenshot comparison)
- [ ] Triangle colors correct
- [ ] No shader compilation errors
- [ ] Works on all 3 platforms (CI matrix)

**Exit Criteria**
- [ ] Colored triangle on solid background
- [ ] Renders at 60 FPS
- [ ] Works on Linux, macOS, Windows

### Phase 1.4: JS Controls Clear Color

**Goals**
- [ ] JS can call native function to set color
- [ ] Color updates visible next frame
- [ ] Round-trip works reliably

**Implementation**
- [ ] Expose `setClearColor(r, g, b)` to JS
- [ ] Store color in shared state
- [ ] Apply color in render loop
- [ ] Add `requestAnimationFrame` shim

**Tests Required**
- [ ] JS sets red → window is red
- [ ] JS sets green → window is green
- [ ] JS animation loop changes color over time
- [ ] 1000 color changes, all apply correctly

**Exit Criteria**
- [ ] `setClearColor(1, 0, 0)` from JS makes window red
- [ ] Animation callback works
- [ ] M1 demo script runs

---

## M2: Cube via Shim

WebGL shim subset. JS draws a cube through the shim layer.

### Napkin Math

```
WebGL calls per frame (simple cube): ~50 calls
├── State changes: ~20 calls × 0.1μs = 2μs
├── Buffer binds: ~5 calls × 0.5μs = 2.5μs  
├── Draw calls: ~1 call × 1μs = 1μs
├── Uniform updates: ~10 calls × 0.2μs = 2μs
└── Total shim overhead: ~10μs per frame
Verdict: ✓ Negligible vs 16.6ms budget
```

### Phase 2.0: Design Validation

**Goals**
- [ ] WebGL API surface mapped
- [ ] Shim architecture documented
- [ ] State machine design complete

**Deliverables**
- [ ] `src/shim/webgl.zig` - type definitions
- [ ] `src/shim/webgl_state.zig` - state machine types
- [ ] API coverage spreadsheet (which gl.* calls needed)

**Exit Criteria**
- [ ] Know exactly which 30-40 GL calls to implement
- [ ] State machine transitions documented
- [ ] Types compile

### Phase 2.1: WebGL Context Creation

**Goals**
- [ ] `canvas.getContext('webgl')` returns context
- [ ] Context has correct properties
- [ ] Context is usable object in JS

**Implementation**
- [ ] Canvas shim with getContext
- [ ] WebGLRenderingContext object
- [ ] Property getters (drawingBufferWidth, etc.)
- [ ] Register with JS runtime

**Tests Required**
- [ ] getContext returns truthy
- [ ] Context has expected properties
- [ ] Multiple getContext calls return same context
- [ ] Invalid context type returns null

**Exit Criteria**
- [ ] `canvas.getContext('webgl')` works
- [ ] Properties readable
- [ ] No crashes

### Phase 2.2: Buffer Management

**Goals**
- [ ] createBuffer works
- [ ] bindBuffer works
- [ ] bufferData works
- [ ] deleteBuffer works

**Implementation**
- [ ] Buffer handle allocation
- [ ] Bind state tracking
- [ ] Data upload to sokol buffer
- [ ] Cleanup on delete

**Tests Required**
- [ ] Create 1000 buffers, no leak
- [ ] Bind/unbind cycles
- [ ] Upload data, verify size
- [ ] Delete buffer, handle invalid

**Exit Criteria**
- [ ] Buffer lifecycle complete
- [ ] State tracked correctly
- [ ] No resource leaks

### Phase 2.3: Shader Compilation

**Goals**
- [ ] createShader works
- [ ] shaderSource works
- [ ] compileShader works
- [ ] getShaderParameter works
- [ ] createProgram, attachShader, linkProgram work

**Implementation**
- [ ] Shader source storage
- [ ] GLSL to sokol shader translation (or passthrough)
- [ ] Compilation error reporting
- [ ] Program linking

**Tests Required**
- [ ] Valid shader compiles
- [ ] Invalid shader reports error
- [ ] Program links with valid shaders
- [ ] Program fails with incompatible shaders
- [ ] getShaderInfoLog returns errors

**Exit Criteria**
- [ ] Shader pipeline works
- [ ] Errors reported correctly
- [ ] No crashes on bad input

### Phase 2.4: Draw Calls

**Goals**
- [ ] bindBuffer + bindShader + draw workflow
- [ ] drawArrays works
- [ ] drawElements works (indexed)
- [ ] Uniform updates work

**Implementation**
- [ ] Assemble sokol pipeline from GL state
- [ ] Execute draw with current bindings
- [ ] Uniform buffer management
- [ ] State validation before draw

**Tests Required**
- [ ] Draw triangle via WebGL calls
- [ ] Draw indexed quad
- [ ] Uniform changes affect output
- [ ] Invalid state rejected

**Exit Criteria**
- [ ] WebGL draw calls produce visible output
- [ ] Matches expected rendering
- [ ] State machine validated

### Phase 2.5: Cube Demo

**Goals**
- [ ] Rotating cube rendered
- [ ] All via WebGL shim calls
- [ ] Runs at 60 FPS

**Implementation**
- [ ] Matrix math in JS (or shim)
- [ ] Cube vertex data
- [ ] Rotation animation
- [ ] Perspective projection

**Tests Required**
- [ ] Cube visible and rotating
- [ ] Screenshot comparison
- [ ] 60 FPS sustained
- [ ] Memory stable over 1 minute

**Exit Criteria**
- [ ] Cube demo runs
- [ ] Pure WebGL JS code (no native calls except shim)
- [ ] M2 complete

---

## M3: Three.js Loads

Three.js imports without error and renders a basic scene.

### Napkin Math

```
Three.js bundle size: ~600KB minified
├── Parse time (mquickjs): ~500ms one-time
├── Memory for parsed AST: ~2MB
└── Runtime objects: ~1MB
Total JS memory: ~3MB

Frame with Three.js:
├── Scene graph traversal: ~0.5ms (100 objects)
├── Matrix updates: ~0.2ms
├── WebGL calls: ~2ms (batched)
├── Buffer: 13ms
└── Total: ~3ms
Verdict: ✓ Fits in 64KB mquickjs heap? NO - need larger heap

Revised: 256KB heap minimum for Three.js
```

### Phase 3.0: Design Validation

**Goals**
- [ ] Three.js load tested in mquickjs standalone
- [ ] Missing APIs identified
- [ ] Memory requirements validated

**Deliverables**
- [ ] List of required browser APIs
- [ ] Memory budget confirmed
- [ ] Shim gap analysis

**Exit Criteria**
- [ ] Know every API Three.js needs
- [ ] Memory budget feasible
- [ ] No blockers identified

### Phase 3.1: DOM Shims

**Goals**
- [ ] document.createElement works
- [ ] Basic Element properties
- [ ] Event handling basics

**Implementation**
- [ ] Document object shim
- [ ] Element object shim
- [ ] createElement for canvas
- [ ] Style object (noop most properties)

**Tests Required**
- [ ] createElement returns element
- [ ] Element has expected properties
- [ ] Canvas element works with getContext

**Exit Criteria**
- [ ] Three.js doesn't throw on DOM access
- [ ] Canvas creation works

### Phase 3.2: Additional WebGL Coverage

**Goals**
- [ ] All WebGL calls Three.js uses
- [ ] Extensions Three.js checks for
- [ ] Error handling for unsupported

**Implementation**
- [ ] Audit Three.js WebGLRenderer
- [ ] Implement missing calls
- [ ] Extension query responses
- [ ] Graceful degradation

**Tests Required**
- [ ] Three.js WebGLRenderer constructs
- [ ] No "undefined" errors
- [ ] Extension queries return expected

**Exit Criteria**
- [ ] WebGLRenderer initializes
- [ ] No missing method errors

### Phase 3.3: Three.js Scene Basics

**Goals**
- [ ] Scene creates
- [ ] Camera creates
- [ ] Renderer creates and attaches

**Implementation**
- [ ] Scene shim if needed
- [ ] Camera types supported
- [ ] Renderer integration

**Tests Required**
- [ ] `new THREE.Scene()` works
- [ ] `new THREE.PerspectiveCamera()` works
- [ ] `new THREE.WebGLRenderer()` works
- [ ] renderer.render(scene, camera) runs

**Exit Criteria**
- [ ] Basic Three.js setup code runs
- [ ] No errors

### Phase 3.4: BoxGeometry + MeshBasicMaterial

**Goals**
- [ ] BoxGeometry creates
- [ ] MeshBasicMaterial creates
- [ ] Mesh renders

**Implementation**
- [ ] Geometry buffer handling
- [ ] Material uniform handling
- [ ] Mesh in scene renders

**Tests Required**
- [ ] Box visible on screen
- [ ] Color from material applied
- [ ] Screenshot matches reference

**Exit Criteria**
- [ ] Three.js renders a box
- [ ] M3 complete

---

## M4: Real Demo

GLTF loading, OrbitControls, lighting. Demo-quality output.

### Phase 4.0: Design Validation

**Goals**
- [ ] GLTF loader requirements mapped
- [ ] OrbitControls input requirements mapped
- [ ] Lighting shader requirements mapped

**Exit Criteria**
- [ ] Know full scope
- [ ] No unknown unknowns

### Phase 4.1: Asset Loading Infrastructure

**Goals**
- [ ] fetch() shim for local files
- [ ] ArrayBuffer handling
- [ ] Blob/URL handling

**Implementation**
- [ ] File read from Zig
- [ ] ArrayBuffer shim
- [ ] Response object shim

**Tests Required**
- [ ] Fetch local file works
- [ ] Binary data correct
- [ ] Large file (10MB) works

**Exit Criteria**
- [ ] Can load assets from disk

### Phase 4.2: GLTF Loading

**Goals**
- [ ] GLTFLoader works
- [ ] Simple GLTF loads
- [ ] Textures load

**Implementation**
- [ ] TextDecoder shim
- [ ] Image loading shim
- [ ] createImageBitmap shim

**Tests Required**
- [ ] Load reference GLTF
- [ ] Geometry correct
- [ ] Textures applied

**Exit Criteria**
- [ ] GLTF model visible

### Phase 4.3: OrbitControls

**Goals**
- [ ] Mouse input works
- [ ] OrbitControls functional
- [ ] Smooth camera movement

**Implementation**
- [ ] Mouse event shims
- [ ] Pointer lock if needed
- [ ] Event dispatch

**Tests Required**
- [ ] Click and drag rotates
- [ ] Scroll zooms
- [ ] No jank

**Exit Criteria**
- [ ] Interactive camera

### Phase 4.4: Lighting

**Goals**
- [ ] DirectionalLight works
- [ ] AmbientLight works
- [ ] MeshStandardMaterial works

**Implementation**
- [ ] Light uniform handling
- [ ] PBR shader support
- [ ] Shadow maps (stretch)

**Tests Required**
- [ ] Lit scene visible
- [ ] Light position affects shading
- [ ] Multiple lights work

**Exit Criteria**
- [ ] Professional-looking render

### Phase 4.5: Demo Polish

**Goals**
- [ ] Demo scene assembled
- [ ] Screenshot quality
- [ ] Stable performance

**Tests Required**
- [ ] Runs 5 minutes without issue
- [ ] Screenshot comparison
- [ ] Memory stable

**Exit Criteria**
- [ ] M4 complete
- [ ] Demo ready for sharing

---

## M5: Ship It

Cross-platform builds. Steam demo page.

### Phase 5.1: macOS Build

**Goals**
- [ ] Builds on macOS
- [ ] Metal backend works
- [ ] App bundle created

**Tests Required**
- [ ] CI builds macOS
- [ ] Demo runs on macOS
- [ ] No code signing issues (for dev)

**Exit Criteria**
- [ ] .app bundle works

### Phase 5.2: Windows Build

**Goals**
- [ ] Builds on Windows
- [ ] D3D11 backend works
- [ ] .exe created

**Tests Required**
- [ ] CI builds Windows
- [ ] Demo runs on Windows
- [ ] No missing DLLs

**Exit Criteria**
- [ ] .exe works standalone

### Phase 5.3: Linux Build

**Goals**
- [ ] Builds on Linux
- [ ] OpenGL backend works
- [ ] Binary runs

**Tests Required**
- [ ] CI builds Linux
- [ ] Demo runs on Linux
- [ ] Works on Ubuntu, Fedora

**Exit Criteria**
- [ ] Binary works

### Phase 5.4: Steam Integration

**Goals**
- [ ] Steamworks SDK integrated
- [ ] Demo page created
- [ ] Build uploaded

**Implementation**
- [ ] Steam app ID
- [ ] Depot configuration
- [ ] Build script for Steam

**Exit Criteria**
- [ ] Demo on Steam
- [ ] M5 complete
- [ ] three-native shipped 🚀

---

## Test Infrastructure

Each phase requires passing tests. The test suite grows with the project:

| Milestone | Test Types |
|-----------|------------|
| M0 | Unit tests only |
| M1 | Unit + screenshot comparison |
| M2 | Unit + screenshot + WebGL conformance subset |
| M3 | Unit + screenshot + Three.js example tests |
| M4 | Unit + screenshot + integration + perf |
| M5 | All above + platform matrix CI |

## CI Requirements

- Linux builds on every push
- macOS/Windows builds on PR and main
- Screenshot tests with golden images
- Memory leak detection (GPA in debug)
- Performance regression detection
