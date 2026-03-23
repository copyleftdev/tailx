# JSON Output

The `--json` flag switches tailx to JSONL output mode. Every line is a valid JSON object. This is the primary integration point for AI agents, scripts, and tooling.

## Two object types

### 1. Event objects

One per processed event, emitted as events arrive:

```json
{
  "type": "event",
  "severity": "ERROR",
  "message": "Connection refused to db-primary:5432",
  "service": "payments",
  "trace_id": "req-abc-123",
  "template_hash": 8234567891234,
  "fields": {
    "latency_ms": 240,
    "hostname": "web01",
    "pid": 1234
  }
}
```

Fields present in an event object:

| Field | Type | Always present | Description |
|-------|------|---------------|-------------|
| `type` | string | yes | Always `"event"` |
| `severity` | string | yes | TRACE, DEBUG, INFO, WARN, ERROR, FATAL, or UNKNOWN |
| `message` | string | yes | The log message (parsed or raw) |
| `service` | string | no | Service name, if detected |
| `trace_id` | string | no | Trace ID, if detected |
| `template_hash` | integer | no | Drain template hash (0 is omitted) |
| `fields` | object | no | Extracted structured fields (omitted if empty) |

Field values in the `fields` object can be strings, integers, floats, booleans, or null.

### 2. Triage summary

Always the last line of output. Contains the full analysis:

```json
{
  "type": "triage_summary",
  "stats": {
    "events": 47283,
    "groups": 92,
    "templates": 38,
    "drops": 0,
    "events_per_sec": 15252.0,
    "elapsed_ms": 3100
  },
  "top_groups": [...],
  "anomalies": [...],
  "hypotheses": [...],
  "traces": [...]
}
```

The triage summary is the "money shot" for AI integration. It contains everything the engine computed, structured for machine reasoning. See [Triage Summary Schema](triage-schema.md) for the full schema.

## Usage patterns

### Read full file to JSON

```bash
tailx --json -s -n app.log
```

- `--json`: JSONL output
- `-s` (`--from-start`): start at beginning of file
- `-n` (`--no-follow`): read to EOF and stop

### Get just the triage summary

```bash
tailx --json -s -n app.log | tail -1
```

The last line is always the `triage_summary`. Use `tail -1` to extract it.

### Filter events in JSON mode

```bash
tailx --json -l error --service payments -s -n app.log
```

Filters work the same in JSON mode. Only matching events are emitted as event objects, but the triage summary still reflects the full pipeline (all events, not just filtered ones).

### Stream processing with jq

```bash
# Extract all error messages
tailx --json -s -n app.log | jq -r 'select(.type=="event" and .severity=="ERROR") | .message'

# Get top group exemplars from the triage summary
tailx --json -s -n app.log | tail -1 | jq '.top_groups[].exemplar'

# Count events per service
tailx --json -s -n app.log | jq -r 'select(.type=="event") | .service // "unknown"' | sort | uniq -c | sort -rn
```

## Real triage summary example

From the production log test (47,283 events):

```json
{
  "type": "triage_summary",
  "stats": {
    "events": 47283,
    "groups": 92,
    "templates": 38,
    "drops": 0,
    "events_per_sec": 15252.0,
    "elapsed_ms": 3100
  },
  "top_groups": [
    {
      "exemplar": "Connection pool exhausted, waiting for available connection",
      "count": 5765,
      "severity": "WARN",
      "trend": "rising",
      "service": "db"
    },
    {
      "exemplar": "<*> carrier <*> ...",
      "count": 4812,
      "severity": "WARN",
      "trend": "rising",
      "service": "NetworkManager"
    }
  ],
  "anomalies": [],
  "hypotheses": [],
  "traces": []
}
```

## Every event goes through the full pipeline

Whether you filter by severity, service, or grep -- every event is always:

1. Parsed (format detection, field extraction)
2. Template-fingerprinted (Drain algorithm)
3. Grouped (pattern table)
4. Assigned to traces (if trace_id present)
5. Fed to anomaly detectors
6. Fed to the correlation engine

Filters only control what gets emitted as event objects. The triage summary always reflects the complete picture.
