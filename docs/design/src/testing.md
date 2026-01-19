# Testing

Testing follows Tiger Style: each phase is fully tested before proceeding.
Tests are written first, implementations make them pass.

## TDD Workflow

```
1. Write failing test for new behavior
2. Implement minimal code to pass
3. Refactor with confidence
4. Repeat
```

Every phase in the roadmap has explicit test requirements. No phase is complete
until all its tests pass.

## Test Categories

### Unit Tests

Fast, isolated tests for individual functions and types.

```zig
test "buffer handle allocation" {
    var handles = BufferHandles.init(testing.allocator);
    defer handles.deinit();
    
    const h1 = handles.alloc();
    const h2 = handles.alloc();
    try testing.expect(h1 != h2);
    
    handles.free(h1);
    const h3 = handles.alloc();
    try testing.expectEqual(h1, h3); // reuse
}
```

**Coverage targets:**
- Handle/resource allocation
- State machine transitions
- Error paths
- Boundary conditions

### Integration Tests

Test JS↔Zig round-trips and WebGL shim workflows.

```zig
test "JS sets clear color" {
    var rt = try Runtime.init(testing.allocator, 256 * 1024);
    defer rt.deinit();
    
    try rt.eval("setClearColor(1.0, 0.0, 0.0)");
    
    const color = rt.getClearColor();
    try testing.expectApproxEqAbs(@as(f32, 1.0), color.r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), color.g, 0.001);
}
```

**Coverage targets:**
- JS function bindings
- WebGL call sequences
- Asset loading paths
- Error propagation

### Screenshot Tests

Render and compare against golden images.

```zig
test "triangle renders correctly" {
    var renderer = try TestRenderer.init();
    defer renderer.deinit();
    
    renderer.drawTriangle();
    
    const pixels = renderer.readPixels();
    try testing.expectScreenshotMatch("golden/triangle.png", pixels, .{
        .tolerance = 0.01, // 1% pixel difference allowed
    });
}
```

**Why tolerances:**
- Driver differences
- Floating point variance
- Platform antialiasing

**Golden image updates:**
```bash
zig build test -- --update-golden
```

### Fuzz Tests

Test robustness against malformed inputs.

```zig
test "fuzz: GLTF parser doesn't crash" {
    try testing.fuzz(struct {
        fn run(input: []const u8) !void {
            _ = gltf.parse(input) catch return;
        }
    }, .{});
}
```

**Fuzz targets:**
- GLTF parser
- Image decoders
- JS eval (if applicable)
- Any binary format handling

Run extended fuzzing:
```bash
zig build test --fuzz -- --duration 3600
```

### Benchmark Tests

Validate performance meets napkin math estimates.

```zig
test "benchmark: context switch under 200ns" {
    const result = testing.benchmark(struct {
        fn run() void {
            runtime.contextSwitch();
        }
    }, .{});
    
    try testing.expect(result.mean_ns < 200);
}
```

**Benchmarks track:**
- WebGL call overhead
- JS eval latency
- Frame time budget
- Memory allocation rate

## Test Infrastructure

### Directory Structure

```
tests/
├── unit/
│   ├── handles_test.zig
│   ├── state_machine_test.zig
│   └── ...
├── integration/
│   ├── webgl_test.zig
│   ├── runtime_test.zig
│   └── ...
├── screenshot/
│   ├── triangle_test.zig
│   ├── cube_test.zig
│   └── golden/
│       ├── triangle.png
│       └── cube.png
├── fuzz/
│   ├── gltf_fuzz.zig
│   └── ...
└── fixtures/
    ├── simple.js
    ├── webgl_cube.js
    └── ...
```

### Running Tests

```bash
# All tests
zig build test

# Unit tests only
zig build test -- --filter unit

# Screenshot tests (requires display)
zig build test -- --filter screenshot

# With verbose output
zig build test -- -v

# With memory leak detection
zig build test -- --detect-leaks
```

### CI Configuration

| Platform | Test Scope |
|----------|------------|
| Linux (every push) | Unit, integration, memory leaks |
| Linux + GPU (PR) | All including screenshot |
| macOS (PR) | Unit, integration |
| Windows (PR) | Unit, integration |

### Memory Leak Detection

All tests run with GeneralPurposeAllocator in debug mode:

```zig
test "no memory leaks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked) @panic("memory leak detected");
    }
    
    // test code using gpa.allocator()
}
```

## Failure Diagnostics

When a test fails:

1. **Context dump** — Last N WebGL calls logged
2. **JS exception** — Stack trace if JS threw
3. **Screenshot** — Actual render saved (screenshot tests)
4. **Diff image** — Visual diff against golden (screenshot tests)
5. **State snapshot** — GL state machine dump

Example failure output:
```
test "cube renders correctly" FAILED
  Expected: golden/cube.png
  Actual: /tmp/test_output/cube_actual.png
  Diff: /tmp/test_output/cube_diff.png
  Pixel difference: 5.2% (threshold: 1.0%)
  
  Last 5 WebGL calls:
    gl.bindBuffer(ARRAY_BUFFER, 3)
    gl.bufferData(ARRAY_BUFFER, 288, STATIC_DRAW)
    gl.vertexAttribPointer(0, 3, FLOAT, false, 12, 0)
    gl.enableVertexAttribArray(0)
    gl.drawArrays(TRIANGLES, 0, 36)
```

## Test-First Development

For each new feature:

1. **Write the test first**
   ```zig
   test "gl.createBuffer returns valid handle" {
       var gl = try WebGLContext.init();
       const buf = gl.createBuffer();
       try testing.expect(buf != 0);
   }
   ```

2. **Watch it fail** — Confirms test is testing the right thing

3. **Implement** — Minimum code to pass

4. **Refactor** — Clean up with passing tests as safety net

5. **Commit** — Test and implementation together

This ensures:
- No untested code
- Tests document expected behavior
- Regressions caught immediately
