# Quick Start

## Basic usage

Tail a file with automatic pattern grouping:

```bash
tailx app.log
```

This follows the file (like `tail -f`), auto-detects the log format, parses every line, groups events by structural template, and prints a ranked pattern summary when done or periodically during follow mode.

## Pipe from stdin

```bash
cat app.log | tailx
```

Any command that produces log lines works:

```bash
journalctl -u myservice | tailx
docker logs myapp | tailx
kubectl logs pod/api-7f8b9 | tailx
```

## Multiple files with globs

```bash
tailx /var/log/*.log
```

tailx expands globs, opens all matching files, and merges events across sources. When multiple files are open, each event line is prefixed with the source file path.

## Read a full file (no follow)

```bash
tailx --from-start --no-follow file.log
# Short form:
tailx -s -n file.log
```

Reads the entire file from the beginning, processes every line through the full pipeline, prints the events and pattern summary, then exits.

## Filter by severity

```bash
dmesg | tailx --severity warn
# Short form:
dmesg | tailx -l warn
```

Only displays events at `warn` level or above (warn, error, fatal). Events below the threshold are still processed internally -- they feed the pattern groups and anomaly detectors. Filtering is display-only.

## What the output looks like

In default pattern mode, tailx prints events line-by-line as they arrive, then a pattern summary:

```
INF [nginx] GET /api/health 200 0.003s
INF [nginx] GET /api/users 200 0.045s
WRN [payments] Connection pool exhausted, waiting
ERR [payments] Connection refused to db-primary:5432
ERR [payments] Transaction failed: connection timeout
INF [nginx] GET /api/health 200 0.002s

──────────────────────────────────────────────────────────────
 Pattern Summary  847 events  12 groups  8 templates  4231 ev/s  0.2s
──────────────────────────────────────────────────────────────
  ✗ [payments] Connection refused to <*>  (x34) ↑ rising
  ⚠ [payments] Connection pool exhausted, waiting  (x28) ↑ rising
  ● [nginx] GET <*> <*> <*>  (x612) → stable
  ● [auth] Token refreshed for user <*>  (x89) → stable
  ● [nginx] GET /api/health <*> <*>  (x84) ↓ falling
──────────────────────────────────────────────────────────────

tailx: 847 events, 12 groups, 8 templates, 0 drops
```

Each group line shows:

- **Severity icon**: `●` info, `⚠` warn, `✗` error, a fire icon for fatal
- **Service name** in brackets (if detected)
- **Template** with `<*>` wildcards replacing variable parts
- **Count** in parentheses
- **Trend**: `↑ rising`, `→ stable`, `↓ falling`, or `✨ new`
