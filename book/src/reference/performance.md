# Performance

tailx is built for speed. The entire processing pipeline -- parsing, template extraction, grouping, anomaly detection, correlation -- runs in the per-event hot path with zero heap allocation after initialization.

## Throughput

| Metric | Value |
|--------|-------|
| End-to-end throughput | 69,000 events/sec (single core) |
| Measured on | 47,000 mixed-format lines in 3.1s |
| Full pipeline | parse + Drain + group + trace + anomaly + correlation |

This is not a synthetic benchmark. It is the actual measured throughput on real syslog data through the complete 12-stage pipeline.

## Binary size

| Build mode | Size |
|------------|------|
| ReleaseSmall (stripped) | 144 KB |
| ReleaseSafe | 3.1 MB |

The 144 KB ReleaseSmall binary fits in L2 cache on most modern CPUs. It contains zero external dependencies -- no PCRE, no libc (where avoidable), no vendored C code.

## Startup time

Cold start is under 1 millisecond. There is no runtime to initialize, no JIT to warm up, no garbage collector to configure. The first event is processed within microseconds of launch.

## Memory

### Event storage

| Structure | Memory | Notes |
|-----------|--------|-------|
| Event struct | 256 bytes | Fixed size, cache-line friendly |
| EventRing (default) | 16 MB | 65,536 events x 256 bytes |
| ArenaPool | 64 MB max | 16 arenas x 4 MB, generation-tagged |

The EventRing uses power-of-2 capacity for bitwise modulo indexing (`index & (capacity - 1)` instead of `index % capacity`). This eliminates a division instruction in the per-event hot path.

### Statistical engine

| Structure | Memory |
|-----------|--------|
| CountMinSketch | < 64 KiB |
| HyperLogLog | 16 KiB (exactly 16,384 registers) |
| TDigest | ~4 KiB (256 centroids) |
| EWMA (x2) | 96 bytes |
| StreamingStats (x2) | 64 bytes |
| TimeWindow | < 32 KiB |
| **Total** | **< 1 MiB** |

### Pattern grouping

| Structure | Memory | Notes |
|-----------|--------|-------|
| GroupTable | scales with unique templates | typically 1-5 MiB |
| DrainTree | 4,096 cluster slots | fixed allocation |

### Anomaly detection

| Structure | Memory |
|-----------|--------|
| RateDetector | ~200 bytes |
| CusumDetector | ~200 bytes |
| SignalAggregator (128 slots) | ~32 KiB |

### Trace reconstruction

| Structure | Memory |
|-----------|--------|
| TraceStore active (256 traces) | ~512 KiB |
| TraceStore finalized (512 traces) | ~1 MiB |

### Correlation

| Structure | Memory |
|-----------|--------|
| TemporalProximity (256 signals) | ~64 KiB |

## Allocation strategy

tailx uses three allocation strategies:

1. **Arena allocation** for event data (messages, fields, strings). Generation-tagged arenas allow bulk free on window expiry. Zero per-event free calls.

2. **General-purpose allocation** for long-lived singletons (EventRing, DrainTree, GroupTable, TraceStore). Allocated once at startup, freed at shutdown.

3. **Stack allocation** for small fixed-size buffers (< 4 KiB). No heap involvement.

After initialization, the per-event hot path performs zero heap allocations. All event data is copied into the current arena, which is a bump allocator (pointer increment only).

## Per-operation targets

| Operation | Target | Achieved |
|-----------|--------|----------|
| Event struct size | 256 bytes | 256 bytes |
| EventRing push+get | 1M events correct | Tested |
| Drain template extraction | 0.5 us/line | On target |
| Filter evaluation (3 predicates) | 100 ns/event | On target |
| Group classify (hash lookup) | O(1) | O(1) |
| Anomaly detector tick | 10 ms/tick | < 1 ms |
| Correlation engine tick | 10 ms/tick | < 1 ms |

## What makes it fast

1. **No GC, no runtime**: Zig compiles to native code with no runtime overhead. No stop-the-world pauses.

2. **Arena allocation**: event data is bump-allocated (pointer increment). No per-event malloc/free.

3. **Power-of-2 ring buffer**: bitwise AND instead of modulo division for index wrapping.

4. **Fixed-size Event struct**: 256 bytes, fits in 4 cache lines. No pointer chasing for common fields.

5. **Boyer-Moore-Horspool**: substring search for `--grep` uses a bad-character table for O(n/m) average-case matching.

6. **FNV-1a template hash**: fast, well-distributed hash for template fingerprinting.

7. **Inline everything**: hot path functions are small enough for the compiler to inline. No virtual dispatch.

8. **No external dependencies**: the entire binary is self-contained Zig code. No FFI overhead, no dynamic linking.
