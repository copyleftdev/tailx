const std = @import("std");
const core = @import("core.zig");
const ingestion = @import("ingestion.zig");
const parsing = @import("parsing.zig");
const pattern_mod = @import("pattern.zig");
const anomaly_mod = @import("anomaly.zig");
const trace_mod = @import("trace.zig");
const correlation_mod = @import("correlation.zig");

const Event = core.Event;
const EventRing = core.EventRing;
const ArenaPool = core.ArenaPool;
const Timestamp = core.Timestamp;
const Severity = core.Severity;
const SourceId = core.source.SourceId;

/// Full processing pipeline: ingestion → parsing → pattern → anomaly.
/// Owns all mutable state for the event processing chain.
pub const Pipeline = struct {
    // Core storage.
    ring: EventRing,
    arena_pool: ArenaPool,
    merger: ingestion.Merger,

    // Parsing.
    format_detectors: [max_sources]parsing.FormatDetector,
    schema_inferers: [max_sources]parsing.SchemaInferer,
    drain: *parsing.DrainTree,

    // Pattern detection.
    group_table: *pattern_mod.GroupTable,

    // Anomaly detection.
    rate_detector: anomaly_mod.RateDetector,
    cusum_detector: anomaly_mod.CusumDetector,
    signal_agg: anomaly_mod.SignalAggregator,

    // Trace reconstruction.
    trace_store: *trace_mod.TraceStore,

    // Correlation.
    correlation: correlation_mod.TemporalProximity,

    // Counters.
    events_total: u64,
    events_in_window: u32,
    last_tick_ns: i128,
    last_window_rotate_ns: i128,
    start_ns: i128,

    // Config.
    severity_filter: Severity,
    time_filter_start_ns: ?i128 = null,

    allocator: std.mem.Allocator,

    const max_sources = 64;
    const tick_interval_ns: i128 = 1 * std.time.ns_per_s;
    const window_interval_ns: i128 = 60 * std.time.ns_per_s;

    pub fn init(allocator: std.mem.Allocator, ring_size: u32) !Pipeline {
        var ring = try EventRing.init(allocator, ring_size);
        errdefer ring.deinit(allocator);

        var arena_pool = ArenaPool.init(allocator, 60 * std.time.ns_per_s);

        const group_table = try allocator.create(pattern_mod.GroupTable);
        group_table.* = .{};

        const drain = try allocator.create(parsing.DrainTree);
        drain.* = parsing.DrainTree.init(4, 0.5);

        const trace_store = try allocator.create(trace_mod.TraceStore);
        trace_store.* = trace_mod.TraceStore.init(30 * std.time.ns_per_s);

        return .{
            .ring = ring,
            .arena_pool = arena_pool,
            .merger = ingestion.Merger.init(&ring, &arena_pool),
            .format_detectors = [_]parsing.FormatDetector{.{}} ** max_sources,
            .schema_inferers = [_]parsing.SchemaInferer{.{}} ** max_sources,
            .drain = drain,
            .group_table = group_table,
            .rate_detector = anomaly_mod.RateDetector.init(),
            .cusum_detector = anomaly_mod.CusumDetector.init(),
            .signal_agg = anomaly_mod.SignalAggregator{},
            .trace_store = trace_store,
            .correlation = correlation_mod.TemporalProximity.init(300 * std.time.ns_per_s), // 5min window
            .events_total = 0,
            .events_in_window = 0,
            .last_tick_ns = 0,
            .last_window_rotate_ns = 0,
            .start_ns = std.time.nanoTimestamp(),
            .severity_filter = .trace,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pipeline) void {
        // Fix: we need to update merger's pointers since ring/arena_pool
        // are stored by value. Instead, just free what we own.
        self.ring.deinit(self.allocator);
        self.arena_pool.deinit();
        self.allocator.destroy(self.drain);
        self.allocator.destroy(self.group_table);
        self.allocator.destroy(self.trace_store);
        self.* = undefined;
    }

    /// Post-init fixup: merger stores pointers, need to point to our owned copies.
    pub fn fixupPointers(self: *Pipeline) void {
        self.merger.ring = &self.ring;
        self.merger.arena_pool = &self.arena_pool;
    }

    /// Process a single raw line through the full pipeline.
    /// Returns the processed event (pointer into the ring) or null if dropped.
    pub fn processLine(self: *Pipeline, raw: []const u8, source_id: SourceId) ?*Event {
        const now_ns = std.time.nanoTimestamp();

        // 0. Multi-line detection: if this is a continuation, skip it
        //    (the line is part of a stack trace / multi-line message).
        if (parsing.MultiLineDetector.isContinuation(raw)) {
            self.events_total += 1;
            return null; // continuation lines don't become new events
        }

        // 1. Timestamp extraction.
        const ts_nanos = ingestion.QuickTimestamp.extract(raw) orelse now_ns;

        // 2. Ingest: arena-dupe + push to ring.
        self.merger.ingest(raw, ts_nanos, source_id);
        self.events_total += 1;
        self.events_in_window += 1;

        // Get the event we just pushed.
        const newest_idx = self.ring.newest() orelse return null;
        const event = self.ring.getPtr(newest_idx) orelse return null;

        // 3. Format detection (per source).
        if (source_id < max_sources) {
            self.format_detectors[source_id].feed(raw);
        }

        // 4. Parse based on detected format.
        const arena = self.arena_pool.current();
        const format = if (source_id < max_sources)
            self.format_detectors[source_id].result()
        else
            parsing.Format.unstructured;

        switch (format) {
            .json, .json_lines => parsing.JsonParser.parse(raw, event, arena),
            .kv_pairs, .logfmt => parsing.KvParser.parse(raw, event, arena),
            .syslog_bsd, .syslog_ietf => parsing.SyslogBsdParser.parse(raw, event, arena),
            else => parsing.FallbackParser.parse(raw, event, arena),
        }

        // 4b. Schema inference (per source).
        if (source_id < max_sources and event.fields.len() > 0) {
            self.schema_inferers[source_id].feed(event.fields);
        }

        // 5. Drain template extraction.
        event.template_hash = self.drain.process(event.message);

        // 6. Pattern grouping.
        _ = self.group_table.classify(event);

        // 7. Trace assignment.
        self.trace_store.assignExplicit(event, newest_idx);

        // 8. Periodic tick: anomaly detection, window rotation.
        if (now_ns - self.last_tick_ns >= tick_interval_ns) {
            self.tick(now_ns);
        }

        return event;
    }

    fn tick(self: *Pipeline, now_ns: i128) void {
        // Rate anomaly detection.
        const rate = @as(f64, @floatFromInt(self.events_in_window));
        if (self.rate_detector.tick(rate, now_ns)) |result| {
            var results = [_]anomaly_mod.DetectorResult{result};
            self.signal_agg.process(&results, now_ns);
            // Feed to correlation engine.
            self.correlation.record(.{
                .kind = if (result.method == .rate_spike) .anomaly_alert else .rate_change,
                .onset_ns = now_ns,
                .peak_ns = now_ns,
                .magnitude = result.score,
                .label = correlation_mod.CorrelationSignal.Label.from("event rate anomaly"),
                .source_id = 0,
            });
        }
        if (self.cusum_detector.tick(rate, now_ns)) |result| {
            var results = [_]anomaly_mod.DetectorResult{result};
            self.signal_agg.process(&results, now_ns);
            self.correlation.record(.{
                .kind = .anomaly_alert,
                .onset_ns = now_ns,
                .peak_ns = now_ns,
                .magnitude = result.score,
                .label = correlation_mod.CorrelationSignal.Label.from("sustained rate shift"),
                .source_id = 1,
            });
        }

        // Feed rising groups as correlation signals.
        var top_buf: [5]pattern_mod.GroupTable.TopGroupEntry = undefined;
        const top_count = self.group_table.topGroups(&top_buf);
        for (top_buf[0..top_count]) |entry| {
            if (self.group_table.groups[entry.index]) |group| {
                if (group.trend == .rising) {
                    self.correlation.record(.{
                        .kind = .group_spike,
                        .onset_ns = now_ns,
                        .peak_ns = now_ns,
                        .magnitude = @min(1.0, @as(f64, @floatFromInt(group.count_short)) / 100.0),
                        .label = correlation_mod.CorrelationSignal.Label.from(group.getExemplar()),
                        .source_id = entry.index,
                    });
                }
            }
        }

        self.events_in_window = 0;
        self.last_tick_ns = now_ns;

        // Window rotation.
        if (now_ns - self.last_window_rotate_ns >= window_interval_ns) {
            self.group_table.windowRotate(now_ns);
            _ = self.trace_store.expireSweep(now_ns);
            _ = self.arena_pool.maybeRotate(now_ns);
            self.last_window_rotate_ns = now_ns;
        }
    }

    /// Get current processing stats.
    pub fn stats(self: *const Pipeline) Stats {
        const now = std.time.nanoTimestamp();
        const elapsed = now - self.start_ns;
        const elapsed_secs = @as(f64, @floatFromInt(@max(@as(i128, 1), elapsed))) / @as(f64, @floatFromInt(std.time.ns_per_s));
        return .{
            .events_total = self.events_total,
            .drop_count = self.merger.drop_count,
            .active_groups = self.group_table.group_count,
            .active_traces = self.trace_store.activeTraceCount(),
            .active_alerts = self.signal_agg.activeCount(),
            .drain_clusters = self.drain.cluster_count,
            .elapsed_ns = elapsed,
            .events_per_sec = @as(f64, @floatFromInt(self.events_total)) / elapsed_secs,
        };
    }

    /// Build hypotheses for active anomaly alerts.
    pub fn getHypotheses(self: *const Pipeline, out: []correlation_mod.Hypothesis) u32 {
        var count: u32 = 0;
        for (self.signal_agg.alerts) |slot| {
            if (slot) |alert| {
                if (alert.state == .active and count < out.len) {
                    const effect = correlation_mod.CorrelationSignal{
                        .kind = .anomaly_alert,
                        .onset_ns = alert.first_fired_ns,
                        .peak_ns = alert.last_fired_ns,
                        .magnitude = alert.score,
                        .label = correlation_mod.CorrelationSignal.Label.from("anomaly"),
                        .source_id = alert.id,
                    };
                    out[count] = self.correlation.hypothesize(effect);
                    count += 1;
                }
            }
        }
        return count;
    }

    pub const Stats = struct {
        events_total: u64,
        drop_count: u64,
        active_groups: u32,
        active_traces: u32,
        active_alerts: u32,
        drain_clusters: u16,
        elapsed_ns: i128,
        events_per_sec: f64,
    };
};

test {
    @import("std").testing.refAllDecls(@This());
}
