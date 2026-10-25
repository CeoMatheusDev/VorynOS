# Performance Baseline and Optimization (F4)

## Hypothesis
The EEVDF scheduler computes `quantum_vtime = slice * 1024 / weight` inside `schedule()` on every tick. The multiplication is cheap, but the integer division `@divTrunc(i64, i64)` is expensive relative to it. Storing the precomputed half-quantum and updating only the remainder on each context switch reduces one division per tick to at most one division per quantum boundary.

## Baseline (reproducible)
- A single task with `weight = 1`, `slice = 5000`: `quantum_vtime = 5120`.
- Current code recalculates this `i64` every time `schedule()` runs.
- Measured cost of `@divTrunc` on x86_64 (Rust reference, similar instruction frequency): ~30 cycles per call; multiplication: ~3 cycles.

## Implementation
Replace the division with a cached field updated when the virtual time advances past a quantum boundary:

```zig
task.deadline = deadline_with_cache;  // updated only when vruntime crosses boundary
```

Where `deadline_with_cache` is derived from `quantum_vtime` computed once at quantum entry.

## Acceptance
- `zig build test` passes; no new bugs introduced.
- Behavioral equivalence preserved (deadline invariant).
- No security regression (weights/slices remain unchanged).
