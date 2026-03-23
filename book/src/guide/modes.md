# Modes

tailx has five display modes. The default is pattern mode.

## Pattern mode (default)

```bash
tailx app.log
```

Events are printed line-by-line as they arrive. At the end (or periodically every 500 events in follow mode), a ranked pattern summary is displayed showing the top groups by severity, frequency, and trend.

This is the mode you want for most triage work. It answers: "what patterns exist in these logs and which ones matter?"

```
ERR [payments] Connection refused to db-primary:5432
ERR [payments] Connection refused to db-primary:5432
INF [nginx] GET /api/health 200 0.002s

──────────────────────────────────────────────────────────────
 Pattern Summary  847 events  12 groups  8 templates  4231 ev/s  0.2s
──────────────────────────────────────────────────────────────
  ✗ [payments] Connection refused to <*>  (x34) ↑ rising
  ● [nginx] GET <*> <*> <*>  (x612) → stable
──────────────────────────────────────────────────────────────
```

## Raw mode

```bash
tailx --raw app.log
```

Classic tail behavior. Events are printed line-by-line with severity badges and service names, but no pattern summary, no anomaly alerts, no group rankings. The full pipeline still runs internally (parsing, grouping, anomaly detection), but nothing beyond the event lines is displayed.

Use this when you just want to watch logs scroll by with basic formatting.

## Trace mode

```bash
tailx --trace app.log
```

Groups events by `trace_id` and displays them as request flow trees. Each trace shows its events connected with tree connectors, the total duration, and the outcome (success, failure, timeout, or unknown).

```
TRACE req-abc-123  245ms  FAILURE
 ├─ INF [gateway] Received POST /api/checkout
 ├─ INF [auth] Token validated for user-42
 ├─ INF [payments] Processing payment $49.99
 ├─ ERR [payments] Connection refused to db-primary:5432
 └─ ERR [gateway] 500 Internal Server Error

TRACE req-def-456  12ms  success
 ├─ INF [gateway] Received GET /api/health
 └─ INF [gateway] 200 OK
(2 traces)
```

Events without a `trace_id` are not shown in trace mode. The pattern summary is still displayed at the end.

## Incident mode

```bash
tailx --incident app.log
```

Suppresses all normal event output. Only displays:

- Active anomaly alerts (rate spikes, rate drops, change points)
- The pattern summary with top groups

This is the "pager duty" mode. No noise, just the signals that something changed.

```
 !! ANOMALY: rate spike — observed 450.0 vs expected 120.3 (deviation: 4.2)

──────────────────────────────────────────────────────────────
 Pattern Summary  23907 events  118 groups  51 templates  8860 ev/s  2.7s
──────────────────────────────────────────────────────────────
  ✗ [payments] Connection refused to <*>  (x1204) ↑ rising
  ⚠ [payments] Connection pool exhausted  (x891) ↑ rising
──────────────────────────────────────────────────────────────
```

## JSON mode

```bash
tailx --json app.log
```

Outputs JSONL (one JSON object per line). Two types of objects:

1. **Event objects** -- one per processed event
2. **Triage summary** -- always the last line, contains the full analysis

```json
{"type":"event","severity":"ERROR","message":"Connection refused","service":"payments","template_hash":8234567891234}
{"type":"event","severity":"INFO","message":"GET /api/health 200","service":"nginx","template_hash":1234567890123}
{"type":"triage_summary","stats":{...},"top_groups":[...],"anomalies":[...],"hypotheses":[...],"traces":[...]}
```

JSON mode is designed for machine consumption -- pipe it to `jq`, feed it to an AI agent, or integrate it as an MCP tool. See [JSON Output](../ai/json-output.md) for the full schema.
