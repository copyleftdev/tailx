# Anomaly Detection

tailx uses two complementary anomaly detectors that tick every second. Together they catch both sudden spikes and sustained shifts in event rate.

## RateDetector

Dual EWMA (Exponentially Weighted Moving Average) with z-score thresholding.

### Architecture

```
event rate (events/sec)
  │
  ├─ EWMA fast  (10s halflife)  → "current" rate
  ├─ EWMA slow  (5min halflife) → "baseline" rate
  └─ StreamingStats (Welford)   → historical mean/variance → z-score
```

### How it works

1. Each tick (1 second), the current event count is fed as a sample.
2. The sample's z-score is computed against the running historical statistics (before updating them).
3. Both EWMAs are updated with the sample.
4. After the warmup period (30 samples), if the z-score >= 3.0 AND the absolute delta between fast and slow EWMA exceeds the minimum threshold (1.0), an anomaly fires.

### Spike vs. drop

- **z-score >= 3.0**: `rate_spike` -- the event rate is significantly above the historical norm.
- **z-score <= -3.0** (and baseline > minimum threshold): `rate_drop` -- the event rate has significantly dropped. Only fires when the baseline is meaningful (above minimum absolute delta).

### Warmup

The first 30 samples are used to build the baseline. No anomalies fire during warmup, preventing false positives from cold start.

### Score normalization

The raw z-score is mapped to a 0.0 - 1.0 severity score using a logistic-like function:

```
score = 1.0 - 1.0 / (1.0 + 0.1 * z^2)
```

This gives:
- z = 3.0 -> score ~0.47
- z = 5.0 -> score ~0.71
- z = 10.0 -> score ~0.91

## CusumDetector

Cumulative Sum (CUSUM) change-point detector. Catches sustained shifts that individual z-scores miss.

### The problem CUSUM solves

Imagine the event rate gradually climbs from 100/s to 200/s over 30 seconds. No single tick has a z-score >= 3.0 because each increase is small. But the cumulative shift is significant. CUSUM catches this.

### How it works

1. Each tick, the sample is normalized: `(sample - mean) / stddev`.
2. Two cumulative sums are maintained:
   - `s_high`: accumulates upward deviations minus an allowance (0.5)
   - `s_low`: accumulates downward deviations minus the same allowance
3. Both sums are clamped to >= 0 (they cannot go negative).
4. If `s_high` exceeds the threshold (5.0 standard deviations), fire `change_point_up` and reset `s_high` to 0.
5. If `s_low` exceeds the threshold, fire `change_point_down` and reset `s_low` to 0.

### Cooldown

After firing, a 30-tick cooldown prevents re-firing on the same shift. This avoids alert storms when a new baseline is establishing.

### Score

The CUSUM score is:

```
score = min(1.0, cumulative_sum / (threshold * 2.0))
```

Capped at 1.0. Higher cumulative sums (larger or longer shifts) produce higher scores.

## SignalAggregator

The `SignalAggregator` manages anomaly alerts across both detectors.

### Deduplication

If a detector fires with the same method (e.g., `rate_spike`) as an existing active alert, the existing alert is updated instead of creating a new one:
- `last_fired_ns` is updated
- `fire_count` is incremented
- `score` is set to the max of old and new

### Resolution

An active alert transitions to `resolved` after 30 seconds of not being re-fired. This means the anomalous condition has ended.

### Eviction

Resolved alerts are evicted after 5 minutes. This keeps the alert table clean while retaining recent history for the triage summary.

### Capacity

The aggregator holds up to 128 alerts simultaneously.

## Correlation Engine

The `TemporalProximity` analyzer connects anomaly signals to possible causes.

### Signal sources

Three types of signals feed the correlation engine:

1. **Anomaly alerts** from the RateDetector and CusumDetector
2. **Rising groups** -- pattern groups whose trend is `rising` in the current window
3. **Rate changes** from detector results

### Finding causes

For each active anomaly alert, the engine searches for signals that occurred within a 5-minute window before the anomaly. Candidate causes are ranked by:

```
strength = (1.0 - normalized_lag) * magnitude
```

Where `normalized_lag` is the time lag as a fraction of the 5-minute window. Closer signals with higher magnitude rank higher.

### Hypothesis building

The ranked causes form a `Hypothesis` with:
- `causes[]`: up to 8 candidate causes, ordered by strength
- `confidence`: the maximum cause strength (a measure of how strongly correlated the top cause is)

### Example

```
t=10s: DB latency spike (anomaly_alert, magnitude=0.8)
t=12s: "Connection refused" group rising (group_spike, magnitude=0.6)
t=15s: Error rate spike (anomaly_alert, magnitude=0.9)  ← the effect
```

The hypothesis for the error rate spike would include:
1. DB latency spike (5s lag, strength = 0.73) -- closest and high magnitude
2. "Connection refused" rising (3s lag, strength = 0.57)

This tells the operator (or AI agent): "The error rate spike is likely related to the DB latency spike that started 5 seconds earlier."
