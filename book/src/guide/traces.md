# Trace Reconstruction

tailx reconstructs request flows by grouping events that share a `trace_id`. In `--trace` mode, these are displayed as tree views showing the full lifecycle of each request.

## How traces work

When an event has a `trace_id` field (extracted from JSON, logfmt, or any supported format), tailx assigns it to a trace in the TraceStore. All events with the same `trace_id` are grouped into a single Trace object.

Trace IDs are detected from these known field names:

- `trace_id`
- `traceId`
- `trace`
- `x-trace-id`
- `request_id`

## Viewing traces

```bash
tailx --trace app.log
```

Each trace is displayed as a tree with connectors showing the event sequence:

```
TRACE req-abc-123  245ms  FAILURE
 ├─ INF [gateway] Received POST /api/checkout
 ├─ INF [auth] Token validated for user-42
 ├─ INF [inventory] Reserved 3 items
 ├─ INF [payments] Processing payment $49.99
 ├─ ERR [payments] Connection refused to db-primary:5432
 └─ ERR [gateway] 500 Internal Server Error

TRACE req-def-456  12ms  success
 ├─ INF [gateway] Received GET /api/health
 └─ INF [gateway] 200 OK

TRACE req-ghi-789  31002ms  TIMEOUT
 ├─ INF [gateway] Received POST /api/export
 ├─ INF [export] Starting bulk export job
 └─ WRN [export] Job still running after 30s
(3 traces)
```

## Trace properties

Each trace tracks:

- **trace_id**: the explicit ID from the log events
- **event_count**: number of events in the trace (up to 64 per trace)
- **duration**: time from the first event to the last event (in milliseconds)
- **outcome**: determined automatically from the events

## Outcome detection

Trace outcomes are determined by the severity of events within the trace:

| Outcome | Condition | Display |
|---------|-----------|---------|
| **success** | No error or fatal events, trace finalized | `success` (green) |
| **failure** | Any event with severity >= error | `FAILURE` (red, bold) |
| **timeout** | Trace expired without completing | `TIMEOUT` (yellow, bold) |
| **unknown** | Trace still active, no errors yet | `unknown` (dim) |

Outcome escalation is one-way: once a trace sees an error/fatal event, its outcome is permanently set to `failure`.

## Trace lifecycle

1. **Created** when the first event with a given `trace_id` is processed
2. **Active** while events continue arriving for that `trace_id`
3. **Finalized** after 30 seconds of inactivity (no new events with that `trace_id`)

Finalized traces are moved from the active store (256 slots) to a finalized ring buffer (512 slots). Both active and finalized traces are displayed in `--trace` mode.

## Filtering traces

View a single trace by ID:

```bash
tailx --trace --trace-id req-abc-123 app.log
```

Combine with other filters:

```bash
# Only failed traces from payments service
tailx --trace --service payments -l error app.log
```

## Traces in JSON mode

In `--json` mode, traces appear in the `triage_summary` object's `traces` array. Each trace includes its ID, event count, duration, outcome, and the full list of events with their severity, message, and service. See [Triage Summary Schema](../ai/triage-schema.md) for details.
