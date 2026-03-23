# Filters & Queries

All filters are display-only. Filtered events still feed the pattern groups, anomaly detectors, and correlation engine. This is a deliberate design decision: you always get the full statistical picture, even when displaying a subset.

Filters combine with AND by default. Every clause must match for an event to be displayed.

## Severity filter

```bash
tailx --severity warn app.log
tailx -l error app.log
```

Sets a minimum severity threshold. Only events at or above the given level are displayed. Severity levels in order:

| Level | Numeric | Typical meaning |
|-------|---------|-----------------|
| `trace` | 0 | Detailed debug tracing |
| `debug` | 1 | Debug information |
| `info` | 2 | Normal operations |
| `warn` | 3 | Potential issues |
| `error` | 4 | Failures |
| `fatal` | 5 | Unrecoverable errors |

Example: `--severity warn` shows warn, error, and fatal events. Debug and info events are hidden but still processed.

## Message substring filter

```bash
tailx --grep timeout app.log
tailx -g "connection refused" app.log
```

Filters events whose message contains the given substring. Uses Boyer-Moore-Horspool for fast matching. Case-sensitive.

```bash
# Only events mentioning "OOM"
tailx -g OOM /var/log/syslog

# Combine with severity
tailx -l error -g timeout app.log
```

## Service filter

```bash
tailx --service payments app.log
```

Exact match on the service name. The service name is extracted automatically by the parser:

- **JSON**: from `service`, `service_name`, `app`, `application`, or `component` fields
- **Syslog**: from the app name before the PID (`nginx[1234]` -> `nginx`)
- **Unstructured**: from bracketed text (`[PaymentService]` -> `PaymentService`)

## Trace ID filter

```bash
tailx --trace-id req-abc-123 app.log
```

Exact match on the trace ID field. Combined with `--trace` mode, this lets you inspect a single request flow:

```bash
tailx --trace --trace-id req-abc-123 app.log
```

## Field equality filter

```bash
tailx --field status=500 app.log
tailx --field user_id=42 app.log
```

Matches events with a specific field value. Supports both string and integer comparison -- if the field contains an integer and the filter value parses as an integer, numeric comparison is used.

```bash
# Filter by HTTP status code
tailx --field status=500 access.log

# Filter by host
tailx --field hostname=web01 app.log
```

## Time window filter

```bash
tailx --last 5m /var/log/syslog
tailx --last 1h app.log
tailx --last 30s app.log
tailx --last 2d /var/log/syslog
```

Only displays events from within the given time window relative to now. Supported units:

| Suffix | Unit |
|--------|------|
| `s` | seconds |
| `m` | minutes |
| `h` | hours |
| `d` | days |

## Combining filters

All filters are ANDed together. An event must pass every filter to be displayed:

```bash
# Errors from payments service in the last hour
tailx -l error --service payments --last 1h app.log

# Timeout errors from any service
tailx -l error -g timeout app.log

# Specific field value with severity threshold
tailx -l warn --field region=us-east-1 app.log
```

## Important: filtering does not affect counting

This bears repeating: filtered events are still fully processed. They feed template extraction, pattern grouping, anomaly detection, and correlation. The pattern summary reflects all events, not just displayed ones.

This means you can filter the display to errors while still getting accurate group counts and anomaly detection based on the full event stream.
