# CLI Reference

```
tailx [OPTIONS] [FILES...] [QUERY]
```

tailx processes log files or stdin, auto-detects formats, extracts structure, groups patterns, detects anomalies, and outputs results to the terminal or as JSON.

## Modes

### `(default)` -- Pattern mode

```bash
tailx app.log
```

Events are printed line-by-line with severity badges and service names. A ranked pattern summary is displayed at the end (batch mode) or every 500 events (follow mode). This is the mode for interactive triage.

### `--raw`

```bash
tailx --raw app.log
```

Classic tail output. Events are printed with basic formatting (severity badge, service name, message) but no pattern summary, no anomaly alerts, no group rankings. The full pipeline still runs internally.

### `--trace`

```bash
tailx --trace app.log
```

Groups events by `trace_id` and displays them as tree views with duration and outcome. Events without a trace_id are not shown. The pattern summary is still displayed at the end.

### `--incident`

```bash
tailx --incident app.log
```

Suppresses normal event output. Only displays active anomaly alerts and the pattern summary. Use this for alerting and on-call scenarios where you only want to see signals.

### `--json`

```bash
tailx --json app.log
```

Outputs JSONL (one JSON object per line). Event objects are emitted as events arrive. The triage summary is always the last line. Designed for AI agents and scripts.

## Filters

### `-l, --severity <level>`

```bash
tailx --severity warn app.log
tailx -l error app.log
```

Minimum severity threshold for display. Valid levels: `trace`, `debug`, `info`, `warn`, `error`, `fatal`.

Events below the threshold are still processed by the pipeline -- filtering is display-only.

### `-g, --grep <string>`

```bash
tailx --grep timeout app.log
tailx -g "connection refused" app.log
```

Filter events whose message contains the given substring. Uses Boyer-Moore-Horspool for fast matching. Case-sensitive.

### `--service <name>`

```bash
tailx --service payments app.log
tailx --service nginx app.log
```

Filter events by exact service name match. The service is auto-detected from the log format (JSON `service` key, syslog app name, bracketed text in unstructured logs).

### `--trace-id <id>`

```bash
tailx --trace-id req-abc-123 app.log
```

Filter events by exact trace ID match. Best combined with `--trace` mode to inspect a single request flow.

### `--field <key=value>`

```bash
tailx --field status=500 app.log
tailx --field hostname=web01 app.log
tailx --field user_id=42 app.log
```

Filter events by field value. Supports string and integer comparison -- if the event field is an integer and the filter value parses as an integer, numeric comparison is used.

### `--last <duration>`

```bash
tailx --last 5m app.log
tailx --last 1h app.log
tailx --last 30s app.log
tailx --last 2d app.log
```

Only display events from within the given time window. Supported suffixes: `s` (seconds), `m` (minutes), `h` (hours), `d` (days).

## Options

### `-f, --follow`

```bash
tailx -f app.log
tailx --follow app.log
```

Follow files for new data (default behavior). tailx uses `poll()` to efficiently wait for new data. Detects file truncation (copytruncate) and rotation (new inode at same path).

### `-n, --no-follow`

```bash
tailx -n app.log
tailx --no-follow app.log
```

Read to EOF and stop. Do not wait for new data. Use this for batch analysis of complete files.

### `-s, --from-start`

```bash
tailx -s app.log
tailx --from-start app.log
```

Start reading from the beginning of the file. By default, tailx seeks to the end and only shows new data (like `tail -f`). Combine with `-n` for full file analysis:

```bash
tailx -s -n app.log
```

### `--no-color`

```bash
tailx --no-color app.log
```

Disable ANSI color codes in output. Color is also automatically disabled when stdout is not a terminal (piped to a file or another command) or when using `--json` mode.

### `--ring-size <n>`

```bash
tailx --ring-size 131072 app.log
```

Set the event ring buffer capacity. Default: 65536 (64K events). Must be a power of 2 for efficient bitwise modulo indexing. Larger values retain more history but use more memory.

### `-h, --help`

```bash
tailx --help
```

Display usage information with all modes, filters, options, and examples.

### `-V, --version`

```bash
tailx --version
# tailx v1.0.0
```

Display the version string.

## Positional arguments

### Files

```bash
tailx app.log
tailx /var/log/*.log
tailx access.log error.log
```

One or more file paths. Glob patterns (`*`, `?`) are expanded. Multiple files are merged into a single event stream, with source names displayed when more than one file is open.

### Intent queries

```bash
tailx "errors related to payments" app.log
tailx "5xx from nginx" app.log
tailx "timeout" app.log
```

If a positional argument is not an existing file path, it is treated as a natural language intent query. Keywords are mapped to filters (severity thresholds, service names, message substrings). See [Intent Queries](../guide/intent-queries.md).

## Stdin

```bash
cat app.log | tailx
journalctl -u myservice | tailx
dmesg | tailx --severity warn
```

When no files are specified and stdin is not a terminal, tailx reads from stdin. All modes and filters work with stdin input.

## Examples

```bash
# Tail a file with pattern grouping
tailx app.log

# Full file analysis
tailx -s -n app.log

# Only errors from the payments service
tailx -l error --service payments app.log

# Kernel warnings from dmesg
dmesg | tailx -l warn

# Anomaly-only view across multiple files
tailx --incident *.log

# Trace a specific request
tailx --trace --trace-id req-abc-123 app.log

# JSON output for AI consumption
tailx --json -s -n --last 5m app.log

# Natural language query
tailx "why are payments failing" app.log

# Multiple files with severity filter
tailx -l warn access.log error.log system.log
```
