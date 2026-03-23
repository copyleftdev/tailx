# Your First Triage

This walkthrough demonstrates tailx against a typical production web stack — mixed JSON and syslog logs from an API gateway, payment service, database, and background worker.

## The command

```bash
tailx -s -n app.log api.log db.log worker.log
```

- `-s` (`--from-start`): read from the beginning of each file
- `-n` (`--no-follow`): read to EOF and stop (don't tail)

## What happened

In 3.1 seconds, tailx processed 47,000 events across four files:

```
tailx: 47283 events, 92 groups, 38 templates, 0 drops
```

That is over 15,000 events per second on a single core, with full parsing, template extraction, grouping, anomaly detection, and correlation.

## The pattern summary

The pattern summary ranked 92 groups by severity, frequency, and trend. The top groups told the story immediately:

```
──────────────────────────────────────────────────────────────
 Pattern Summary  47283 events  92 groups  38 templates  15252 ev/s  3.1s
──────────────────────────────────────────────────────────────
  ✗ [db] connection pool exhausted, <*> connections available  (x8241) ↑ rising
  ✗ [payments] connection timeout to <*>  (x6102) ↑ rising
  ⚠ [worker] retry queue depth exceeding threshold  (x2847) ↑ rising
  🔥 [payments] circuit breaker opened for <*>  (x312) ✨ new
  ● [api] GET <*> <*>  (x18420) → stable
  ● [auth] token validated for user <*>  (x9102) → stable
  ...
──────────────────────────────────────────────────────────────
```

## The root cause

Look at the top groups. They form a cascade:

1. **Database pool exhaustion** — the database connection pool hit zero available connections. This is the highest-severity rising group: 8,241 events.

2. **Payment service timeouts** — with no database connections available, the payment service can't complete transactions. Downstream calls to Stripe start timing out. 6,102 events.

3. **Worker retry storm** — failed payments get queued for retry. The retry queue grows past threshold. 2,847 events.

4. **Circuit breaker trips** — after sustained timeouts, the circuit breaker opens, cutting off all payment processing. 312 events — low count but FATAL severity.

Meanwhile, the healthy traffic continues: API requests (18,420) and auth token validations (9,102) are stable. The problem is isolated to the database → payment → worker path.

One connection pool exhaustion caused 71% of all error volume, cascading through three services.

## The "aha" moment

Without tailx, you would read 47,000 lines across four files. Manually. You would notice the timeout messages are frequent. You might eventually connect them to the database errors. After 30 minutes, you might piece together the cascade.

With tailx: one command, 3 seconds, and the ranked pattern summary shows you the cascade directly. The highest-count error groups are all related. The database pool is the root cause. The fix is either increasing pool size, fixing the connection leak, or adding connection timeout limits.

## Getting the JSON triage

For programmatic access to the same analysis:

```bash
tailx --json -s -n app.log db.log | tail -1
```

The last line of JSON output is always the `triage_summary` object — the full structured analysis including stats, top groups, anomalies, hypotheses, and traces. See [JSON Output](../ai/json-output.md) for the full schema.
