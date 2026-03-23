# Supported Formats

tailx auto-detects the log format for each source independently. Detection locks after 8 samples. No configuration required.

## JSON / JSONL

```json
{"level":"error","msg":"Connection refused","service":"payments","latency_ms":240,"trace_id":"req-001"}
```

Detection: line starts with `{` and ends with `}` (after trimming whitespace).

### Known field keys

| JSON key | Maps to |
|----------|---------|
| `timestamp`, `ts`, `time`, `@timestamp`, `datetime`, `t` | event timestamp |
| `level`, `severity`, `lvl`, `loglevel`, `log_level` | event severity |
| `message`, `msg`, `log`, `text`, `body` | event message |
| `trace_id`, `traceId`, `trace`, `x-trace-id`, `request_id` | event trace_id |
| `service`, `service_name`, `app`, `application`, `component` | event service |

All other keys become structured fields on the event. Values are parsed as their JSON types: strings, integers (`i64`), floats (`f64`), booleans, and null.

### Timestamp handling

- String values: parsed as ISO 8601
- Integers > 946684800000: epoch milliseconds
- Integers > 946684800: epoch seconds
- Floats: epoch seconds with fractional part

## Logfmt

```
ts=2024-03-15T14:23:01Z level=error msg="Connection refused" service=payments latency_ms=240
```

Detection: 3+ `key=value` pairs AND contains `level=`/`lvl=` AND `msg=`/`message=`.

Same known field keys as JSON. Values can be bare words (`level=error`) or double-quoted strings (`msg="hello world"`). Bare values that parse as numbers are stored as integers or floats.

## Syslog BSD (RFC 3164)

```
<134>Mar 15 14:23:01 web01 nginx[1234]: GET /api 200 0.012
```

Detection: line starts with `<` followed by digits and `>`.

### PRI decoding

The PRI value (0-191) encodes facility and severity. Severity = PRI mod 8:

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

### Extracted fields

- **severity**: from PRI, or inferred from message keywords
- **service**: from app name (`nginx` from `nginx[1234]`)
- **hostname**: stored as a structured field
- **pid**: stored as a structured field (integer if parseable)
- **message**: everything after `app[pid]:`

### Journalctl compatibility

Journalctl output omits the PRI prefix but follows the same BSD syslog structure:

```
Mar 15 14:23:01 web01 nginx[1234]: GET /api 200 0.012
```

The parser handles this by treating the PRI as optional. When no PRI is present, severity is inferred from message content (keywords like `error`, `warn`, `[ERROR]`, etc.).

## Key-Value pairs

```
host=db01 cpu=0.85 memory=0.72 disk=0.45
```

Detection: 3+ `key=value` pairs (without the logfmt-specific `level=` and `msg=` keys).

Same known field keys as JSON. Values are bare words or quoted strings. Numeric inference applies to bare values.

## CLF (Common Log Format)

```
10.0.0.1 - frank [10/Oct/2000:13:55:36 -0700] "GET /apache_pb.gif HTTP/1.1" 200 2326
```

Detection: IP/hostname, then ` - `, then `[`, then `"` within first 80 bytes.

CLF lines are parsed by the fallback parser, which extracts what it can from the structure.

## Unstructured text

```
2024-03-15 14:23:01 ERROR [PaymentService] Connection refused to db:5432
```

Detection: everything that does not match the above formats.

The fallback parser extracts:

1. **Timestamp prefix**: ISO 8601 or similar date/time at the start of the line (skipped)
2. **Severity**: bare keywords (`ERROR`, `WARN`, `INFO`, `DEBUG`, `TRACE`, `FATAL`) or bracketed (`[ERROR]`, `[WARN]`)
3. **Service**: text in brackets (`[PaymentService]`)
4. **Message**: the remainder after extracting the above

## Format mixing

Different sources can have different formats. A single tailx invocation can process JSON from one file and syslog from another:

```bash
tailx app.log api.json.log
```

Each source locks to its detected format independently after 8 lines.

## Detection priority on ties

When two formats have equal votes after 8 samples, the more structured format wins:

1. JSON / JSONL (highest priority)
2. Logfmt
3. Key-Value pairs
4. Syslog BSD / Syslog IETF / CLF
5. Unstructured (lowest priority)
