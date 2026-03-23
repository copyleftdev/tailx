# Triage Summary Schema

The `triage_summary` is always the last line of `--json` output. It contains everything tailx computed about the log stream, structured for machine consumption.

## Top-level structure

```json
{
  "type": "triage_summary",
  "stats": { ... },
  "top_groups": [ ... ],
  "anomalies": [ ... ],
  "hypotheses": [ ... ],
  "traces": [ ... ]
}
```

## `stats` object

Processing statistics for the entire run.

```json
{
  "events": 23907,
  "groups": 118,
  "templates": 51,
  "drops": 0,
  "events_per_sec": 8860.4,
  "elapsed_ms": 2698
}
```

| Field | Type | Description |
|-------|------|-------------|
| `events` | integer | Total events processed |
| `groups` | integer | Active pattern groups |
| `templates` | integer | Drain template clusters |
| `drops` | integer | Events dropped (arena OOM) |
| `events_per_sec` | float | Processing throughput |
| `elapsed_ms` | integer | Wall-clock processing time |

## `top_groups[]` array

Up to 20 pattern groups, ranked by score (severity x frequency x trend). Each group represents a cluster of structurally similar log messages.

```json
{
  "exemplar": "Connection refused to <*>",
  "count": 34,
  "severity": "ERROR",
  "trend": "rising",
  "service": "payments",
  "source_count": 3
}
```

| Field | Type | Always present | Description |
|-------|------|---------------|-------------|
| `exemplar` | string | yes | Representative message for this group |
| `count` | integer | yes | Total event count in this group |
| `severity` | string | yes | Highest severity seen in the group |
| `trend` | string | yes | `rising`, `stable`, `falling`, `new`, or `gone` |
| `service` | string | no | Service name, if all events share one |
| `source_count` | integer | no | Number of distinct sources (omitted if 1) |

### Trend values

| Trend | Meaning |
|-------|---------|
| `rising` | Rate is increasing compared to previous window |
| `stable` | Rate is approximately constant |
| `falling` | Rate is decreasing |
| `new` | Group appeared in the current window |
| `gone` | No events in the current window (previously active) |

## `anomalies[]` array

Active anomaly alerts from the rate detector and CUSUM detector.

```json
{
  "kind": "rate_spike",
  "score": 0.823,
  "observed": 450.0,
  "expected": 120.3,
  "deviation": 4.2,
  "fire_count": 3
}
```

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | Anomaly type (see table below) |
| `score` | float | Severity score, 0.0 to 1.0 |
| `observed` | float | The actual measured value |
| `expected` | float | The baseline expected value |
| `deviation` | float | Z-score or normalized deviation |
| `fire_count` | integer | Number of times this alert has fired |

### Anomaly kinds

| Kind | Source | Description |
|------|--------|-------------|
| `rate_spike` | RateDetector | Event rate significantly above baseline |
| `rate_drop` | RateDetector | Event rate significantly below baseline |
| `change_point_up` | CusumDetector | Sustained upward shift in event rate |
| `change_point_down` | CusumDetector | Sustained downward shift in event rate |
| `latency_spike` | (reserved) | Latency above baseline |
| `distribution_shift` | (reserved) | Statistical distribution change |
| `cardinality_spike` | (reserved) | Sudden increase in unique values |
| `new_pattern_burst` | (reserved) | Burst of previously unseen templates |

## `hypotheses[]` array

Causal hypotheses from the correlation engine. Each hypothesis explains an anomaly by linking it to temporally proximate signals.

```json
{
  "causes": [
    {
      "label": "DB latency spike",
      "strength": 0.742,
      "lag_ms": 5000
    },
    {
      "label": "deploy detected",
      "strength": 0.381,
      "lag_ms": 15000
    }
  ],
  "confidence": 0.742
}
```

| Field | Type | Description |
|-------|------|-------------|
| `causes[]` | array | Candidate causes, ordered by strength |
| `causes[].label` | string | Description of the candidate cause |
| `causes[].strength` | float | Cause strength, 0.0 to 1.0 (closer in time + higher magnitude = stronger) |
| `causes[].lag_ms` | integer | Time between cause and effect in milliseconds |
| `confidence` | float | Overall hypothesis confidence (max cause strength) |

## `traces[]` array

Reconstructed request flows from explicit `trace_id` matching.

```json
{
  "trace_id": "req-abc-123",
  "event_count": 5,
  "duration_ms": 245,
  "outcome": "failure",
  "events": [
    {
      "severity": "INFO",
      "message": "Received POST /api/checkout",
      "service": "gateway"
    },
    {
      "severity": "ERROR",
      "message": "Connection refused to db-primary:5432",
      "service": "payments"
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `trace_id` | string | The trace identifier |
| `event_count` | integer | Number of events in this trace |
| `duration_ms` | integer | Time from first to last event |
| `outcome` | string | `success`, `failure`, `timeout`, or `unknown` |
| `events[]` | array | Events in the trace, in order |
| `events[].severity` | string | Event severity level |
| `events[].message` | string | Event message |
| `events[].service` | string | Service name (if present) |
