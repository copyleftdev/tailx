# Parsing & Format Detection

tailx auto-detects the log format for each source independently and dispatches to the appropriate parser. No configuration required.

## Format detection

The `FormatDetector` examines lines using simple heuristics. Each source gets its own detector. After 8 samples, the format locks -- all subsequent lines from that source use the same parser without re-detection.

### Detection rules

| Format | Heuristic |
|--------|-----------|
| **JSON** | Line starts with `{` and ends with `}` (after trimming whitespace) |
| **Syslog BSD** | Line starts with `<` followed by digits and `>` |
| **Syslog IETF** | Syslog prefix + version digit after `>` |
| **CLF** | IP/hostname, then ` - `, then `[`, then `"` within first 80 bytes |
| **Logfmt** | 3+ `key=value` pairs AND contains `level=`/`lvl=` AND `msg=`/`message=` |
| **KV pairs** | 3+ `key=value` pairs (without logfmt-specific keys) |
| **Unstructured** | Everything else |

On ties (equal vote counts), the more structured format wins. Structuredness ranking: JSON (6) > logfmt (5) > KV (4) > syslog/CLF (3) > unstructured (0).

## JSON parser

Hand-written scanner (no `std.json` dependency). Parses objects one key-value pair at a time, mapping known keys to Event fields and collecting the rest into the FieldMap.

### Known field mapping

| JSON key | Maps to |
|----------|---------|
| `timestamp`, `ts`, `time`, `@timestamp`, `datetime`, `t` | `event.timestamp` |
| `level`, `severity`, `lvl`, `loglevel`, `log_level` | `event.severity` |
| `message`, `msg`, `log`, `text`, `body` | `event.message` |
| `trace_id`, `traceId`, `trace`, `x-trace-id`, `request_id` | `event.trace_id` |
| `service`, `service_name`, `app`, `application`, `component` | `event.service` |

All other keys become entries in the event's `FieldMap` with their parsed values.

### Value types

The JSON parser handles all JSON value types:

- **Strings**: extracted with escape sequence handling (`\"`, `\\`, `\n`, `\r`, `\t`, `\uXXXX`)
- **Integers**: parsed as `i64`
- **Floats**: parsed as `f64`
- **Booleans**: `true` / `false`
- **Null**: `null`

### Timestamp handling

Timestamp values can be:
- **String**: parsed as ISO 8601 (`2024-03-15T14:23:01.123Z`)
- **Integer > 946684800000**: interpreted as epoch milliseconds
- **Integer > 946684800**: interpreted as epoch seconds
- **Float**: interpreted as epoch seconds with fractional part

### Example

Input:
```json
{"level":"error","msg":"Connection refused","service":"payments","latency_ms":240,"trace_id":"req-001"}
```

Result:
- `event.severity` = ERROR
- `event.message` = "Connection refused"
- `event.service` = "payments"
- `event.trace_id` = "req-001"
- `event.fields` = `{"latency_ms": 240}`

## KV parser

Parses `key=value` pairs separated by whitespace. Values can be bare words or double-quoted strings.

### Known field mapping

Same known keys as the JSON parser. The KV parser also applies:
- Numeric inference: bare values that parse as integers become `i64`, as floats become `f64`
- Quote stripping: `msg="hello world"` extracts `hello world`

### Example

Input:
```
ts=2024-03-15T14:23:01Z level=error msg="Connection refused" service=payments latency_ms=240
```

Result:
- `event.timestamp` = 2024-03-15T14:23:01Z
- `event.severity` = ERROR
- `event.message` = "Connection refused"
- `event.service` = "payments"
- `event.fields` = `{"latency_ms": 240}`

## Syslog BSD parser

Parses RFC 3164 syslog format. Also handles journalctl output (which omits the PRI).

### Format

```
<PRI>Mon DD HH:MM:SS hostname app[pid]: message
```

### PRI to severity mapping

The PRI value encodes facility and severity per RFC 3164. The severity component (PRI mod 8) maps to:

| PRI mod 8 | Syslog severity | tailx severity |
|-----------|----------------|---------------|
| 0 | Emergency | fatal |
| 1 | Alert | fatal |
| 2 | Critical | fatal |
| 3 | Error | error |
| 4 | Warning | warn |
| 5 | Notice | info |
| 6 | Informational | info |
| 7 | Debug | debug |

### Fields extracted

- **severity**: from PRI value, or inferred from message content
- **service**: from the app name (e.g., `nginx` from `nginx[1234]`)
- **hostname**: stored as a field
- **pid**: stored as a field (integer if parseable)
- **message**: everything after `app[pid]:`

### Severity inference

If no PRI is present (e.g., journalctl output), the parser infers severity from message content by looking for keywords like `error`, `warn`, `info`, `debug`, `critical`, and `fatal` -- both bare and in brackets (e.g., `[ERROR]`).

### Example

Input:
```
<134>Mar 15 14:23:01 web01 nginx[1234]: GET /api 200 0.012
```

Result:
- `event.severity` = INFO (PRI 134 mod 8 = 6 = informational)
- `event.service` = "nginx"
- `event.message` = "GET /api 200 0.012"
- `event.fields` = `{"hostname": "web01", "pid": 1234}`

## Fallback parser

Handles unstructured text logs by extracting what it can.

### Extraction order

1. **Timestamp prefix**: skip ISO 8601 or similar date/time prefix
2. **Severity**: look for bare keywords (`ERROR`, `WARN`, etc.) or bracketed (`[ERROR]`, `[WARN]`)
3. **Service**: extract from brackets (`[PaymentService]` -> "PaymentService")
4. **Message**: everything remaining after extraction

### Example

Input:
```
2024-03-15 14:23:01 ERROR [PaymentService] Connection refused to db:5432
```

Result:
- `event.severity` = ERROR
- `event.service` = "PaymentService"
- `event.message` = "Connection refused to db:5432"

## Multi-line detection

Before parsing, the `MultiLineDetector` checks if a line is a continuation of a previous message (e.g., stack trace frames, indented continuation lines). Continuation lines are skipped and do not create new events.

This prevents a 50-line Java stack trace from becoming 50 separate events -- only the first line (the exception) becomes an event.
