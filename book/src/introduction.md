# tailx

**The live system cognition engine.**

tailx reimagines `tail` from "show me lines" to "what's happening, what matters, and why?"

```
23,907 syslog lines → 118 groups → 51 templates → 3 root causes → 1 diagnosis
In 2.7 seconds. Zero config.
```

## What it does

You point tailx at log files or pipe data in. Without any configuration, it:

1. **Auto-detects** the log format — JSON, logfmt, syslog, or unstructured text
2. **Parses** every line — extracts severity, service, trace ID, structured fields
3. **Fingerprints** messages using the Drain algorithm — collapses thousands of repetitive lines into structural templates
4. **Groups** events by template — ranked by severity × frequency × trend
5. **Detects anomalies** — EWMA rate baselines, CUSUM change-point detection, 3σ threshold
6. **Correlates** signals — temporal proximity analysis linking related anomalies
7. **Outputs** the result — colorized terminal display or structured JSON for AI agents

## The proof

We pointed tailx at a real Linux workstation's `/var/log/syslog` — 23,907 lines of raw log data. Without any configuration, rules, or prior knowledge of the system, it identified that a USB ethernet adapter cycling was the root cause of ~60% of all log volume, cascading through four services: NetworkManager → Avahi → wsdd → dbus.

**Without tailx:** manually reading logs, mentally correlating timestamps, recognizing patterns by eye. A 30-minute task for an experienced SRE.

**With tailx:** one command.

```bash
tailx --json -s -n /var/log/syslog | tail -1
```

## The numbers

| Metric | Value |
|--------|-------|
| Binary size (stripped) | 144 KB |
| Throughput | 69,000 events/sec |
| Memory (statistical engine) | < 1 MiB |
| Startup time | < 1ms |
| External dependencies | 0 |
| Lines of Zig | 8,347 |
| Tests | 219 |
| Config files required | 0 |

## Design principles

- **Zero config to start.** Point it at a file. It works.
- **Local-first.** No cloud. No telemetry. No network calls.
- **Statistical-first.** No LLM in the hot path. Math is fast, deterministic, explainable.
- **Zero dependencies.** Zig standard library only.
- **144 KB binary.** Fits in L2 cache. Starts in microseconds.
