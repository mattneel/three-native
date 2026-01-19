# Performance Budgets

The runtime targets 60 FPS with a stable frame time and predictable memory use.
Budgets are estimates; update them as measurements are collected.

## Targets

- Frame time: 16.6 ms (60 FPS)
- Main thread CPU budget: 6 to 8 ms
- JS budget: 2 to 4 ms (depends on scene complexity)
- Shim + command translation: 1 to 2 ms
- Present and GPU submission: 1 ms (CPU side)

The GPU budget is scene-dependent and not included in the CPU budgets above.

## Napkin Math Template

```
RESOURCE BUDGET: [Feature Name]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Memory:
  Per-item size: ___ bytes (struct + padding)
  Max items: ___
  Total: ___ MB/GB
  Cache analysis:
    L1 (64KB): fits ___ items
    L2 (512KB): fits ___ items
    L3 (16MB): fits ___ items
  Verdict: PASS/FAIL

CPU:
  Operation: ___
  Cycles estimate: ___
  At 3GHz: ___ ns
  Per-second throughput: ___
  Verdict: PASS/FAIL

Latency Budget:
  Target: ___ ns/us/ms
  Breakdown:
    - Step 1: ___ ns
    - Step 2: ___ ns
    - Total: ___ ns
  Safety margin: ___x
  Verdict: PASS/FAIL

Conclusion: PROCEED / REDESIGN
```

## Example Budget: Event Queue Drain

Assumptions:

- 512 events max per frame
- 120 cycles per event to normalize and dispatch

Estimate:

- 512 * 120 cycles = 61,440 cycles
- At 3GHz: ~20.5 us

Verdict: PASS (well under 1 ms)

## WebGL Call Budget

Early milestones assume:

- 2,000 to 5,000 WebGL calls per frame
- 200 to 500 draw calls per frame

The shim state cache must avoid redundant state changes to stay within budget.

## Startup Budget

Targets for cold start:

- App window visible: < 1.0 s
- First frame rendered: < 2.0 s

These numbers are placeholders and should be validated against real demos.
