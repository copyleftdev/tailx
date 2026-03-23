# tailx

**The live system cognition engine.**

tailx reimagines `tail` from "show me lines" to "what's happening, what matters, and why?"

```
47,000 log lines → 92 groups → 38 templates → 2 root causes → 1 diagnosis
In 3.1 seconds. Zero config.
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

We pointed tailx at a production web stack's logs — 47,000 lines across four services. Without any configuration, rules, or prior knowledge of the system, it identified that a database connection pool exhaustion was the root cause of 71% of all error volume, cascading through the API gateway → payment service → notification service.

**Without tailx:** manually reading logs, mentally correlating timestamps, recognizing patterns by eye. A 30-minute task for an experienced SRE.

**With tailx:** one command.

```bash
tailx --json -s -n app.log | tail -1
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
