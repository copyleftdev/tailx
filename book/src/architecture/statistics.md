# Statistical Structures

All statistical data structures in tailx are O(1) memory and O(1) per-event update. The total statistical engine uses less than 1 MiB of memory.

## CountMinSketch

Probabilistic frequency estimator. Answers "how many times have I seen this key?" without storing every key.

### Structure

A `depth x width` matrix of `u32` counters. Each row uses a different hash function (wyhash with different seeds). To estimate the count of a key, hash it with each row's function, look up the counter, and return the minimum across all rows.

### Properties

- **Memory**: fixed at `depth * width * 4` bytes
- **Update**: O(depth) -- hash and increment one counter per row
- **Query**: O(depth) -- hash and read one counter per row, return min
- **Error**: overestimates only, never undercounts
- **Decay**: supports multiplicative decay for sliding window expiry

### Usage

Used internally for frequency tracking in the pattern grouping layer.

## HyperLogLog

Probabilistic cardinality estimator. Answers "how many distinct values have I seen?" using ~16 KiB of memory.

### Configuration

- **Precision**: p = 14
- **Registers**: 2^14 = 16,384
- **Memory**: exactly 16,384 bytes (~16 KiB)
- **Standard error**: ~3%

### Algorithm

1. Hash the input key with wyhash -> 64-bit hash
2. Upper 14 bits select the register index
3. Count leading zeros of the remaining bits + 1
4. Store the max of (current register value, leading zeros count)
5. Estimate: harmonic mean of 2^(-register) values, with bias correction

### Merge

Two HyperLogLog sketches merge by taking the register-wise maximum. This makes it composable across sources.

### Small range correction

When many registers are still zero, the standard HLL formula overestimates. Linear counting is used instead: `m * ln(m / zeros)`.

## TDigest

Streaming percentile estimator. Computes approximate p50, p95, p99 from a stream without storing all values.

### Configuration

- **Max centroids**: 256
- **Memory**: ~4 KiB (256 centroids x 16 bytes each)
- **Compression parameter**: 100

### How it works

The TDigest maintains a sorted list of (mean, weight) centroids. New values are merged into the nearest centroid, subject to a compression constraint that keeps more centroids at the tails (for accurate extreme percentiles) and fewer in the middle.

### Supported queries

- `quantile(0.50)` -- median
- `quantile(0.95)` -- 95th percentile
- `quantile(0.99)` -- 99th percentile
- Any quantile between 0.0 and 1.0

### Accuracy

Higher accuracy at the tails (p1, p99) where it matters most for latency monitoring. The compression parameter (100) trades memory for accuracy -- higher values retain more centroids.

## EWMA

Exponentially Weighted Moving Average. Tracks a smoothed rate that adapts to changes.

### Configuration

```zig
// Fast EWMA: 10-second halflife, 1-second tick interval
EWMA.initWithHalflife(10 * std.time.ns_per_s, std.time.ns_per_s)

// Slow EWMA: 5-minute halflife, 1-second tick interval
EWMA.initWithHalflife(300 * std.time.ns_per_s, std.time.ns_per_s)
```

### Alpha computation

The smoothing factor alpha is computed from the halflife:

```
alpha = 1 - exp(-tick_interval / halflife * ln(2))
```

A 10-second halflife means after 10 seconds, the influence of old values has decayed by 50%.

### Time-weighted updates

The EWMA handles irregular update intervals by adjusting the effective alpha based on the actual elapsed time since the last update. This prevents drift when ticks are not perfectly regular.

### Dual EWMA in anomaly detection

The `RateDetector` uses two EWMAs:
- **Fast** (10s halflife): tracks the "current" rate -- responds quickly to changes
- **Slow** (5min halflife): tracks the "baseline" -- represents the normal rate

When the fast EWMA diverges significantly from the slow EWMA, something has changed.

## StreamingStats

Welford's online algorithm for running mean, variance, standard deviation, and z-score.

### What it computes

- **Mean**: running average
- **Variance**: running population variance
- **Standard deviation**: sqrt(variance)
- **Z-score**: (value - mean) / stddev

### Properties

- Single-pass, numerically stable
- O(1) memory (stores count, mean, M2)
- O(1) per update
- No stored samples -- cannot compute percentiles (use TDigest for that)

### Usage

Used by both the `RateDetector` and `CusumDetector` to compute z-scores of event rate samples against their historical distribution.

## TimeWindow

Circular bucket array for time-bucketed statistics.

### Structure

```zig
TimeWindow {
    buckets: []Bucket,     // circular array
    bucket_count: u16,     // number of buckets
    duration_ns: i128,     // total window span
    bucket_duration_ns: i128, // duration per bucket
    head: u16,             // current bucket index
}
```

Each `Bucket` stores:
- `count`: number of records
- `sum`: sum of values
- `min`: minimum value
- `max`: maximum value
- `start_ns`: bucket start time

### Operations

- **advance(now_ns)**: advance the head to the bucket covering `now_ns`, clearing expired buckets
- **record(value)**: add a value to the current bucket
- **rate()**: compute the overall rate across all buckets

### Usage

Used for time-windowed rate calculations and trend detection in the pattern grouping layer.

## Memory budget

| Structure | Size | Count | Total |
|-----------|------|-------|-------|
| CountMinSketch (per instance) | depth x width x 4 bytes | varies | < 64 KiB |
| HyperLogLog | 16,384 bytes | 1 | 16 KiB |
| TDigest | ~4 KiB | varies | < 16 KiB |
| EWMA | 48 bytes | 2 (rate detector) | 96 bytes |
| StreamingStats | 32 bytes | 2 (detectors) | 64 bytes |
| TimeWindow | varies by bucket count | varies | < 32 KiB |
| **Total statistical engine** | | | **< 1 MiB** |
