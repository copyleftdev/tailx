# Processing Pipeline

Every log line that enters tailx passes through a 12-stage pipeline. The pipeline is synchronous and single-threaded -- no locks, no channels, no thread pools.

## Pipeline stages

```
raw bytes
  │
  ├─ 1. ReadBuffer        64 KiB per-source, in-place line splitting
  ├─ 2. QuickTimestamp     Fast timestamp extraction
  ├─ 3. MultiLineDetector  Continuation line detection
  ├─ 4. Merger             Arena-dupe + push to EventRing
  ├─ 5. FormatDetector     Vote on format, lock after 8 samples
  ├─ 6. Parser dispatch    JSON / KV / Syslog / Fallback
  ├─ 7. SchemaInferer      Track field types/frequencies (first 64 events)
  ├─ 8. DrainTree          Template fingerprinting → template_hash
  ├─ 9. GroupTable          Classify into groups, update counts/trend
  ├─ 10. TraceStore        Assign to trace via trace_id
  ├─ 11. Anomaly tick      RateDetector + CusumDetector (every 1s)
  ├─ 12. Correlation       Feed signals, build hypotheses
  │
  └─ Event (in ring buffer, ready for rendering)
```

## Stage details

### 1. ReadBuffer

Each file source gets a 64 KiB `ReadBuffer`. Raw bytes from `read()` are appended to the buffer. The buffer yields complete lines (terminated by `\n`), handling `\r\n` line endings and partial lines across reads. If the buffer fills without a newline, the entire buffer is yielded as a single long line.

### 2. QuickTimestamp

Before any parsing, `QuickTimestamp.extract()` does a fast scan for timestamps at the beginning of the line. Supports:

- ISO 8601: `2024-03-15T14:23:01.123Z`
- Epoch milliseconds: `1710510181123`
- Epoch seconds: `1710510181`

If no timestamp is found, the current wall clock time is used.

### 3. MultiLineDetector

Checks if a line is a continuation of the previous message (stack traces, indented text). Continuation lines are skipped -- they do not become new events. This prevents stack trace frames from inflating event counts.

### 4. Merger (Ingest)

The raw line is copied into the current arena (`EventArena`) and an `Event` struct is pushed onto the `EventRing`. The event starts with the raw line as its message, the extracted timestamp, and the source ID.

### 5. FormatDetector

Per-source format detection. Each source has its own `FormatDetector` that votes on the format based on simple heuristics. After 8 samples, the format locks and all future lines from that source use the same parser.

Detection rules:
- **JSON**: starts with `{`, ends with `}`
- **Syslog BSD**: starts with `<digits>`
- **CLF**: IP followed by ` - ` and `[date]` and `"`
- **Logfmt**: 3+ `key=value` pairs AND has `level=` AND `msg=`/`message=`
- **KV pairs**: 3+ `key=value` pairs
- **Unstructured**: everything else

On tie, the more structured format wins.

### 6. Parser dispatch

Based on the detected format, one of four parsers extracts structured fields from the raw line:

- `JsonParser` -- hand-written JSON scanner with known field mapping
- `KvParser` -- key=value pair extraction with quoting support
- `SyslogBsdParser` -- PRI, BSD timestamp, hostname, app[pid], message
- `FallbackParser` -- timestamp prefix skip, severity extraction, bracketed service

Each parser populates the event's `severity`, `message`, `service`, `trace_id`, and `fields`.

### 7. SchemaInferer

Per-source schema inference from the first 64 events. Tracks field names, types, and frequencies. This information is available for downstream consumers (e.g., adaptive parsing).

### 8. DrainTree

The Drain algorithm extracts a structural template from the event's message. Variable parts (tokens containing digits, quoted strings) become `<*>` wildcards. The template is hashed with FNV-1a to produce a `template_hash`. Events with the same template hash are structurally identical despite different parameters.

### 9. GroupTable

The event is classified into a pattern group based on its `template_hash`. The group's count, severity, trend, and score are updated. Groups are ranked by a composite score of severity, frequency, and trend direction.

### 10. TraceStore

If the event has a `trace_id`, it is assigned to an active trace in the `TraceStore`. The trace tracks event references (ring buffer indices), duration, and outcome. Active traces expire after 30 seconds of inactivity and are moved to the finalized store.

### 11. Anomaly tick (periodic)

Every 1 second (by wall clock), the pipeline ticks the anomaly detectors:

- **RateDetector**: feeds the current event rate to a dual EWMA (10s fast, 5min slow) and computes a z-score against historical statistics. Fires if z-score >= 3.0 and absolute delta exceeds threshold.
- **CusumDetector**: accumulates normalized deviations. Fires on sustained shifts that z-scores miss. 30-tick cooldown after firing.

Detector results are processed by the `SignalAggregator` (deduplication, resolution, eviction) and fed to the correlation engine.

### 12. Correlation

Rising groups and anomaly alerts are recorded as `CorrelationSignal` objects. The `TemporalProximity` analyzer finds signals that co-occur within a 5-minute window and ranks them by proximity and magnitude to build `Hypothesis` objects.

## Periodic maintenance

Every 60 seconds, the pipeline runs a window rotation:

- `GroupTable.windowRotate()` -- updates trend calculations
- `TraceStore.expireSweep()` -- finalizes inactive traces
- `ArenaPool.maybeRotate()` -- rotates arena generations for bulk memory freeing

## Pipeline state

The `Pipeline` struct owns all mutable state:

- `EventRing` (ring buffer of events)
- `ArenaPool` (generation-tagged arena allocators)
- `FormatDetector[64]` (one per source)
- `SchemaInferer[64]` (one per source)
- `DrainTree` (template extraction)
- `GroupTable` (pattern grouping)
- `RateDetector` + `CusumDetector` (anomaly detection)
- `SignalAggregator` (alert management)
- `TraceStore` (trace reconstruction)
- `TemporalProximity` (correlation engine)

All state is allocated once at startup. No allocations occur in the per-event hot path after initialization.
