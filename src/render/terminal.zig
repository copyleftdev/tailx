const std = @import("std");
const core = @import("../core.zig");
const pipeline_mod = @import("../pipeline.zig");
const pattern_mod = @import("../pattern.zig");
const anomaly_mod = @import("../anomaly.zig");
const correlation_mod = @import("../correlation.zig");
const trace_mod = @import("../trace.zig");
const EventRing = @import("../core.zig").ring.EventRing;

const Event = core.Event;
const Severity = core.Severity;
const EventGroup = pattern_mod.EventGroup;
const GroupTable = pattern_mod.GroupTable;
const Trend = pattern_mod.Trend;

/// ANSI color codes.
pub const ansi = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const italic = "\x1b[3m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const white = "\x1b[37m";
    pub const bg_red = "\x1b[41m";
    pub const bg_yellow = "\x1b[43m";
};

/// Display mode.
pub const DisplayMode = enum {
    raw,       // classic tail — line by line
    pattern,   // default — line by line + group summary
    trace,     // trace tree view — group by trace_id
    incident,  // only alerts + top rising groups
};

/// Terminal renderer for processed events.
pub const Renderer = struct {
    writer: std.fs.File.Writer,
    colorize: bool,
    mode: DisplayMode,
    events_rendered: u64,
    last_summary_count: u64,
    summary_interval: u64, // print summary every N events in follow mode

    pub fn init(writer: std.fs.File.Writer) Renderer {
        return .{
            .writer = writer,
            .colorize = true,
            .mode = .pattern,
            .events_rendered = 0,
            .last_summary_count = 0,
            .summary_interval = 500,
        };
    }

    /// Render a single processed event (raw and pattern modes).
    pub fn renderEvent(self: *Renderer, event: *const Event, source_name: ?[]const u8) void {
        if (self.mode == .incident) return; // incident mode suppresses normal events
        self.writeEvent(event, source_name);
        self.events_rendered += 1;
    }

    fn writeEvent(self: *Renderer, event: *const Event, source_name: ?[]const u8) void {
        const w = self.writer;

        if (self.colorize) {
            // Severity badge.
            if (event.severity != .unknown) {
                w.print("{s}", .{severityBadge(event.severity)}) catch return;
            }
            if (source_name) |name| {
                w.print("{s}{s}{s} ", .{ ansi.dim, name, ansi.reset }) catch return;
            }
            if (event.service) |svc| {
                w.print("{s}[{s}]{s} ", .{ ansi.cyan, svc, ansi.reset }) catch return;
            }
            w.print("{s}{s}{s}\n", .{ severityColor(event.severity), event.message, ansi.reset }) catch return;
        } else {
            if (event.severity != .unknown) {
                w.print("{s} ", .{event.severity.label()}) catch return;
            }
            if (source_name) |name| {
                w.print("{s} ", .{name}) catch return;
            }
            if (event.service) |svc| {
                w.print("[{s}] ", .{svc}) catch return;
            }
            w.print("{s}\n", .{event.message}) catch return;
        }
    }

    /// Render an anomaly alert inline.
    pub fn renderAlert(self: *Renderer, alert: *const anomaly_mod.AnomalyAlert) void {
        const w = self.writer;
        const kind_str = switch (alert.kind) {
            .rate_spike => "rate spike",
            .rate_drop => "rate drop",
            .latency_spike => "latency spike",
            .distribution_shift => "distribution shift",
            .change_point_up => "change point (up)",
            .change_point_down => "change point (down)",
            .cardinality_spike => "cardinality spike",
            .new_pattern_burst => "new pattern burst",
        };

        if (self.colorize) {
            w.print("\n{s}{s} !! ANOMALY: {s}{s} — observed {d:.1} vs expected {d:.1} (deviation: {d:.1}){s}\n\n", .{
                ansi.bg_yellow, ansi.bold,
                kind_str, ansi.reset ++ ansi.yellow,
                alert.observed,
                alert.expected,
                alert.deviation,
                ansi.reset,
            }) catch return;
        } else {
            w.print("\n!! ANOMALY: {s} — observed {d:.1} vs expected {d:.1} (deviation: {d:.1})\n\n", .{
                kind_str,
                alert.observed,
                alert.expected,
                alert.deviation,
            }) catch return;
        }
    }

    /// Render the pattern summary — top groups by score.
    pub fn renderPatternSummary(self: *Renderer, group_table: *const GroupTable, pipeline_stats: pipeline_mod.Pipeline.Stats) void {
        const w = self.writer;

        // Get top groups.
        var top: [20]GroupTable.TopGroupEntry = undefined;
        const count = group_table.topGroups(&top);
        if (count == 0) return;

        const elapsed_ms = @divTrunc(pipeline_stats.elapsed_ns, std.time.ns_per_ms);
        const elapsed_display: f64 = if (elapsed_ms > 1000)
            @as(f64, @floatFromInt(elapsed_ms)) / 1000.0
        else
            @as(f64, @floatFromInt(elapsed_ms));
        const elapsed_unit: []const u8 = if (elapsed_ms > 1000) "s" else "ms";

        if (self.colorize) {
            w.print("\n{s}──────────────────────────────────────────────────────────────{s}\n", .{ ansi.dim, ansi.reset }) catch return;
            w.print("{s}{s} Pattern Summary{s}  {s}{d} events  {d} groups  {d} templates  {d:.0} ev/s  {d:.1}{s}{s}\n", .{
                ansi.bold,   ansi.white, ansi.reset,
                ansi.dim,
                pipeline_stats.events_total,
                pipeline_stats.active_groups,
                pipeline_stats.drain_clusters,
                pipeline_stats.events_per_sec,
                elapsed_display,
                elapsed_unit,
                ansi.reset,
            }) catch return;
            w.print("{s}──────────────────────────────────────────────────────────────{s}\n", .{ ansi.dim, ansi.reset }) catch return;
        } else {
            w.print("\n--------------------------------------------------------------\n", .{}) catch return;
            w.print(" Pattern Summary  {d} events  {d} groups  {d} templates  {d:.0} ev/s  {d:.1}{s}\n", .{
                pipeline_stats.events_total,
                pipeline_stats.active_groups,
                pipeline_stats.drain_clusters,
                pipeline_stats.events_per_sec,
                elapsed_display,
                elapsed_unit,
            }) catch return;
            w.print("--------------------------------------------------------------\n", .{}) catch return;
        }

        for (top[0..count]) |entry| {
            if (group_table.groups[entry.index]) |group| {
                self.renderGroupLine(&group);
            }
        }

        if (pipeline_stats.drop_count > 0) {
            if (self.colorize) {
                w.print("{s}{s}  !! {d} events dropped (arena OOM){s}\n", .{
                    ansi.yellow, ansi.bold, pipeline_stats.drop_count, ansi.reset,
                }) catch return;
            } else {
                w.print("  !! {d} events dropped (arena OOM)\n", .{pipeline_stats.drop_count}) catch return;
            }
        }

        if (self.colorize) {
            w.print("{s}──────────────────────────────────────────────────────────────{s}\n\n", .{ ansi.dim, ansi.reset }) catch return;
        } else {
            w.print("--------------------------------------------------------------\n\n", .{}) catch return;
        }
    }

    fn renderGroupLine(self: *Renderer, group: *const EventGroup) void {
        const w = self.writer;
        const trend_icon = trendIcon(group.trend);
        const sev_icon = severityIcon(group.severity);
        const exemplar = group.getExemplar();
        const service = group.getService();

        // Truncate exemplar for display.
        const max_display = @min(exemplar.len, 72);
        const display = exemplar[0..max_display];
        const ellipsis: []const u8 = if (exemplar.len > 72) "..." else "";

        if (self.colorize) {
            const sev_color = severityColor(group.severity);
            // Severity icon + optional service + message + count + trend.
            w.print("  {s}{s}{s} ", .{ sev_color, sev_icon, ansi.reset }) catch return;
            if (service) |svc| {
                w.print("{s}[{s}]{s} ", .{ ansi.cyan, svc, ansi.reset }) catch return;
            }
            w.print("{s}{s}{s}{s} {s}(x{d}){s} {s}{s}{s}\n", .{
                sev_color,
                display,
                ellipsis,
                ansi.reset,
                ansi.bold,
                group.count,
                ansi.reset,
                ansi.dim,
                trend_icon,
                ansi.reset,
            }) catch return;

            // Source count if > 1.
            const src_count = group.sources.count();
            if (src_count > 1) {
                w.print("    {s}from {d} sources{s}\n", .{ ansi.dim, src_count, ansi.reset }) catch return;
            }
        } else {
            w.print("  {s} ", .{sev_icon}) catch return;
            if (service) |svc| {
                w.print("[{s}] ", .{svc}) catch return;
            }
            w.print("{s}{s} (x{d}) {s}\n", .{
                display,
                ellipsis,
                group.count,
                trend_icon,
            }) catch return;
        }
    }

    /// Check if it's time for an inline summary (follow mode).
    pub fn shouldSummarize(self: *const Renderer) bool {
        if (self.mode != .pattern) return false;
        return self.events_rendered >= self.last_summary_count + self.summary_interval;
    }

    pub fn markSummarized(self: *Renderer) void {
        self.last_summary_count = self.events_rendered;
    }

    /// Render active alerts from the signal aggregator.
    pub fn renderActiveAlerts(self: *Renderer, signal_agg: *const anomaly_mod.SignalAggregator) void {
        for (signal_agg.alerts) |slot| {
            if (slot) |alert| {
                if (alert.state == .active) {
                    self.renderAlert(&alert);
                }
            }
        }
    }

    /// Render correlation hypotheses ("why" layer).
    pub fn renderHypotheses(self: *Renderer, hypotheses: []const correlation_mod.Hypothesis) void {
        if (hypotheses.len == 0) return;
        const w = self.writer;

        for (hypotheses) |hyp| {
            if (hyp.cause_count == 0) continue;

            if (self.colorize) {
                w.print("\n  {s}{s}Likely related:{s}\n", .{ ansi.magenta, ansi.bold, ansi.reset }) catch return;
            } else {
                w.print("\n  Likely related:\n", .{}) catch return;
            }

            for (hyp.causes[0..hyp.cause_count]) |cause| {
                const lag_ms = @divTrunc(cause.lag_ns, std.time.ns_per_ms);
                const label = cause.signal.label.slice();
                const strength_pct = @as(u32, @intFromFloat(cause.strength * 100));

                if (self.colorize) {
                    w.print("    {s}- {s}{s} ({d}ms earlier, {d}%% confidence){s}\n", .{
                        ansi.magenta, label, ansi.dim,
                        lag_ms, strength_pct, ansi.reset,
                    }) catch return;
                } else {
                    w.print("    - {s} ({d}ms earlier, {d}%% confidence)\n", .{
                        label, lag_ms, strength_pct,
                    }) catch return;
                }
            }
        }
    }

    /// Render all traces as tree views.
    pub fn renderTraces(self: *Renderer, trace_store: *const trace_mod.TraceStore, ring: *const EventRing) void {
        const w = self.writer;
        var trace_count: u32 = 0;

        // Render active traces.
        for (trace_store.active) |slot| {
            if (slot) |trace| {
                if (trace.event_count > 0) {
                    self.renderOneTrace(&trace, ring);
                    trace_count += 1;
                }
            }
        }

        // Render finalized traces.
        for (trace_store.finalized) |slot| {
            if (slot) |trace| {
                if (trace.event_count > 0) {
                    self.renderOneTrace(&trace, ring);
                    trace_count += 1;
                }
            }
        }

        if (trace_count > 0) {
            if (self.colorize) {
                w.print("{s}({d} traces){s}\n", .{ ansi.dim, trace_count, ansi.reset }) catch return;
            } else {
                w.print("({d} traces)\n", .{trace_count}) catch return;
            }
        }
    }

    fn renderOneTrace(self: *Renderer, trace: *const trace_mod.Trace, ring: *const EventRing) void {
        const w = self.writer;
        var id_buf: [36]u8 = undefined;
        const id_display = trace.id.writeTo(&id_buf);
        const duration_ms = @divTrunc(trace.durationNs(), std.time.ns_per_ms);

        const outcome_str: []const u8 = switch (trace.outcome) {
            .success => "success",
            .failure => "FAILURE",
            .timeout => "TIMEOUT",
            .unknown => "unknown",
        };
        const outcome_color: []const u8 = if (self.colorize) switch (trace.outcome) {
            .success => ansi.green,
            .failure => ansi.red ++ ansi.bold,
            .timeout => ansi.yellow ++ ansi.bold,
            .unknown => ansi.dim,
        } else "";

        // Trace header.
        if (self.colorize) {
            w.print("\n{s}{s}TRACE {s}{s} {s}{d}ms {s}{s}{s}\n", .{
                ansi.bold, ansi.cyan,
                id_display, ansi.reset,
                ansi.dim, duration_ms,
                outcome_color, outcome_str, ansi.reset,
            }) catch return;
        } else {
            w.print("\nTRACE {s}  {d}ms  {s}\n", .{ id_display, duration_ms, outcome_str }) catch return;
        }

        // Trace events as tree.
        for (trace.event_refs[0..trace.event_count], 0..) |ref, i| {
            const is_last = i == trace.event_count - 1;
            const connector: []const u8 = if (is_last) "\xe2\x94\x94\xe2\x94\x80 " else "\xe2\x94\x9c\xe2\x94\x80 "; // └─ or ├─

            // Look up the actual event from the ring.
            if (ring.get(ref.ring_idx)) |event| {
                const sev_badge = if (self.colorize) severityBadge(ref.severity) else ref.severity.label();

                if (self.colorize) {
                    w.print(" {s}{s}{s}", .{ ansi.dim, connector, ansi.reset }) catch return;
                    w.print("{s}", .{sev_badge}) catch return;
                    if (event.service) |svc| {
                        w.print("{s}[{s}]{s} ", .{ ansi.cyan, svc, ansi.reset }) catch return;
                    }
                    w.print("{s}{s}{s}\n", .{ severityColor(ref.severity), event.message, ansi.reset }) catch return;
                } else {
                    w.print(" {s}{s} ", .{ connector, sev_badge }) catch return;
                    if (event.service) |svc| {
                        w.print("[{s}] ", .{svc}) catch return;
                    }
                    w.print("{s}\n", .{event.message}) catch return;
                }
            } else {
                // Event was evicted from ring — show what we know.
                if (self.colorize) {
                    w.print(" {s}{s}{s} {s}(evicted from ring){s}\n", .{
                        ansi.dim, connector, ansi.reset,
                        ansi.dim, ansi.reset,
                    }) catch return;
                } else {
                    w.print(" {s}(evicted from ring)\n", .{connector}) catch return;
                }
            }
        }
    }

    fn severityBadge(sev: Severity) []const u8 {
        return switch (sev) {
            .trace => ansi.dim ++ "TRC " ++ ansi.reset,
            .debug => ansi.dim ++ "DBG " ++ ansi.reset,
            .info => ansi.green ++ "INF " ++ ansi.reset,
            .warn => ansi.yellow ++ ansi.bold ++ "WRN " ++ ansi.reset,
            .err => ansi.red ++ ansi.bold ++ "ERR " ++ ansi.reset,
            .fatal => ansi.bg_red ++ ansi.bold ++ " FTL " ++ ansi.reset ++ " ",
            .unknown => "",
        };
    }

    fn severityColor(sev: Severity) []const u8 {
        return switch (sev) {
            .trace, .debug => ansi.dim,
            .info => "",
            .warn => ansi.yellow,
            .err => ansi.red,
            .fatal => ansi.red ++ ansi.bold,
            .unknown => "",
        };
    }

    fn severityIcon(sev: Severity) []const u8 {
        return switch (sev) {
            .trace, .debug => " ",
            .info => "\xe2\x97\x8f", // ●
            .warn => "\xe2\x9a\xa0", // ⚠
            .err => "\xe2\x9c\x97",  // ✗
            .fatal => "\xf0\x9f\x94\xa5", // 🔥
            .unknown => " ",
        };
    }

    fn trendIcon(trend: Trend) []const u8 {
        return switch (trend) {
            .rising => "\xe2\x86\x91 rising",    // ↑
            .stable => "\xe2\x86\x92 stable",    // →
            .falling => "\xe2\x86\x93 falling",  // ↓
            .new_group => "\xe2\x9c\xa8 new",    // ✨
            .gone => "\xe2\x80\xa2 idle",        // •
        };
    }
};

test "renderer init" {
    const stdout = std.io.getStdOut().writer();
    const r = Renderer.init(stdout);
    try std.testing.expectEqual(@as(u64, 0), r.events_rendered);
    try std.testing.expect(r.colorize);
}
