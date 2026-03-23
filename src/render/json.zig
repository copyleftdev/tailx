const std = @import("std");
const core = @import("../core.zig");
const pipeline_mod = @import("../pipeline.zig");
const pattern_mod = @import("../pattern.zig");
const anomaly_mod = @import("../anomaly.zig");
const correlation_mod = @import("../correlation.zig");
const trace_mod = @import("../trace.zig");

const Event = core.Event;
const Severity = core.Severity;
const EventGroup = pattern_mod.EventGroup;
const GroupTable = pattern_mod.GroupTable;
const EventRing = core.ring.EventRing;

/// JSON renderer — structured JSONL output for AI tool consumption.
/// Every insight the engine computes, machine-readable.
pub const JsonRenderer = struct {
    writer: std.fs.File.Writer,
    events_rendered: u64,

    pub fn init(writer: std.fs.File.Writer) JsonRenderer {
        return .{ .writer = writer, .events_rendered = 0 };
    }

    /// Emit a single event as JSONL.
    pub fn renderEvent(self: *JsonRenderer, event: *const Event) void {
        const w = self.writer;
        w.print("{{\"type\":\"event\",\"severity\":\"{s}\",\"message\":", .{event.severity.label()}) catch return;
        writeJsonString(w, event.message);

        if (event.service) |svc| {
            w.print(",\"service\":", .{}) catch return;
            writeJsonString(w, svc);
        }

        if (event.trace_id) |tid| {
            w.print(",\"trace_id\":", .{}) catch return;
            writeJsonString(w, tid);
        }

        if (event.template_hash != 0) {
            w.print(",\"template_hash\":{d}", .{event.template_hash}) catch return;
        }

        if (event.fields.len() > 0) {
            w.print(",\"fields\":{{", .{}) catch return;
            for (event.fields.fields, 0..) |field, i| {
                if (i > 0) w.print(",", .{}) catch return;
                writeJsonString(w, field.key);
                w.print(":", .{}) catch return;
                switch (field.value) {
                    .string => |s| writeJsonString(w, s),
                    .int => |v| w.print("{d}", .{v}) catch return,
                    .float => |v| w.print("{d:.6}", .{v}) catch return,
                    .boolean => |v| w.print("{s}", .{if (v) "true" else "false"}) catch return,
                    .null_val => w.print("null", .{}) catch return,
                }
            }
            w.print("}}", .{}) catch return;
        }

        w.print("}}\n", .{}) catch return;
        self.events_rendered += 1;
    }

    /// Emit the full triage snapshot — one JSON object an LLM can reason over.
    pub fn renderTriageSummary(
        self: *JsonRenderer,
        pipeline_stats: pipeline_mod.Pipeline.Stats,
        group_table: *const GroupTable,
        signal_agg: *const anomaly_mod.SignalAggregator,
        hypotheses: []const correlation_mod.Hypothesis,
        trace_store: *const trace_mod.TraceStore,
        ring: *const EventRing,
    ) void {
        const w = self.writer;

        // Open summary object.
        w.print("{{\"type\":\"triage_summary\"", .{}) catch return;

        // Stats.
        w.print(",\"stats\":{{\"events\":{d},\"groups\":{d},\"templates\":{d},\"drops\":{d},\"events_per_sec\":{d:.1},\"elapsed_ms\":{d}}}", .{
            pipeline_stats.events_total,
            pipeline_stats.active_groups,
            pipeline_stats.drain_clusters,
            pipeline_stats.drop_count,
            pipeline_stats.events_per_sec,
            @divTrunc(pipeline_stats.elapsed_ns, std.time.ns_per_ms),
        }) catch return;

        // Top groups.
        w.print(",\"top_groups\":[", .{}) catch return;
        var top: [20]GroupTable.TopGroupEntry = undefined;
        const count = group_table.topGroups(&top);
        for (top[0..count], 0..) |entry, i| {
            if (i > 0) w.print(",", .{}) catch return;
            if (group_table.groups[entry.index]) |group| {
                self.renderGroupJson(&group);
            }
        }
        w.print("]", .{}) catch return;

        // Active anomalies.
        w.print(",\"anomalies\":[", .{}) catch return;
        var alert_idx: u32 = 0;
        for (signal_agg.alerts) |slot| {
            if (slot) |alert| {
                if (alert.state == .active) {
                    if (alert_idx > 0) w.print(",", .{}) catch return;
                    self.renderAlertJson(&alert);
                    alert_idx += 1;
                }
            }
        }
        w.print("]", .{}) catch return;

        // Hypotheses.
        w.print(",\"hypotheses\":[", .{}) catch return;
        for (hypotheses, 0..) |hyp, hi| {
            if (hyp.cause_count == 0) continue;
            if (hi > 0) w.print(",", .{}) catch return;
            self.renderHypothesisJson(&hyp);
        }
        w.print("]", .{}) catch return;

        // Traces.
        w.print(",\"traces\":[", .{}) catch return;
        var trace_idx: u32 = 0;
        for (trace_store.active) |slot| {
            if (slot) |trace| {
                if (trace.event_count > 0) {
                    if (trace_idx > 0) w.print(",", .{}) catch return;
                    self.renderTraceJson(&trace, ring);
                    trace_idx += 1;
                }
            }
        }
        for (trace_store.finalized) |slot| {
            if (slot) |trace| {
                if (trace.event_count > 0) {
                    if (trace_idx > 0) w.print(",", .{}) catch return;
                    self.renderTraceJson(&trace, ring);
                    trace_idx += 1;
                }
            }
        }
        w.print("]", .{}) catch return;

        w.print("}}\n", .{}) catch return;
    }

    fn renderGroupJson(self: *JsonRenderer, group: *const EventGroup) void {
        const w = self.writer;
        w.print("{{\"exemplar\":", .{}) catch return;
        writeJsonString(w, group.getExemplar());
        w.print(",\"count\":{d},\"severity\":\"{s}\",\"trend\":\"{s}\"", .{
            group.count,
            group.severity.label(),
            trendStr(group.trend),
        }) catch return;
        if (group.getService()) |svc| {
            w.print(",\"service\":", .{}) catch return;
            writeJsonString(w, svc);
        }
        const src_count = group.sources.count();
        if (src_count > 1) {
            w.print(",\"source_count\":{d}", .{src_count}) catch return;
        }
        w.print("}}", .{}) catch return;
    }

    fn renderAlertJson(self: *JsonRenderer, alert: *const anomaly_mod.AnomalyAlert) void {
        const w = self.writer;
        w.print("{{\"kind\":\"{s}\",\"score\":{d:.3},\"observed\":{d:.1},\"expected\":{d:.1},\"deviation\":{d:.1},\"fire_count\":{d}}}", .{
            alertKindStr(alert.kind),
            alert.score,
            alert.observed,
            alert.expected,
            alert.deviation,
            alert.fire_count,
        }) catch return;
    }

    fn renderHypothesisJson(self: *JsonRenderer, hyp: *const correlation_mod.Hypothesis) void {
        const w = self.writer;
        w.print("{{\"causes\":[", .{}) catch return;
        for (hyp.causes[0..hyp.cause_count], 0..) |cause, i| {
            if (i > 0) w.print(",", .{}) catch return;
            w.print("{{\"label\":", .{}) catch return;
            writeJsonString(w, cause.signal.label.slice());
            w.print(",\"strength\":{d:.3},\"lag_ms\":{d}}}", .{
                cause.strength,
                @divTrunc(cause.lag_ns, std.time.ns_per_ms),
            }) catch return;
        }
        w.print("],\"confidence\":{d:.3}}}", .{hyp.confidence}) catch return;
    }

    fn renderTraceJson(self: *JsonRenderer, trace: *const trace_mod.Trace, ring: *const EventRing) void {
        const w = self.writer;
        var id_buf: [36]u8 = undefined;
        const id_display = trace.id.writeTo(&id_buf);
        w.print("{{\"trace_id\":", .{}) catch return;
        writeJsonString(w, id_display);
        w.print(",\"event_count\":{d},\"duration_ms\":{d},\"outcome\":\"{s}\",\"events\":[", .{
            trace.event_count,
            @divTrunc(trace.durationNs(), std.time.ns_per_ms),
            outcomeStr(trace.outcome),
        }) catch return;

        for (trace.event_refs[0..trace.event_count], 0..) |ref, i| {
            if (i > 0) w.print(",", .{}) catch return;
            if (ring.get(ref.ring_idx)) |event| {
                w.print("{{\"severity\":\"{s}\",\"message\":", .{ref.severity.label()}) catch return;
                writeJsonString(w, event.message);
                if (event.service) |svc| {
                    w.print(",\"service\":", .{}) catch return;
                    writeJsonString(w, svc);
                }
                w.print("}}", .{}) catch return;
            }
        }
        w.print("]}}", .{}) catch return;
    }

    fn alertKindStr(kind: anomaly_mod.DetectorKind) []const u8 {
        return switch (kind) {
            .rate_spike => "rate_spike",
            .rate_drop => "rate_drop",
            .latency_spike => "latency_spike",
            .distribution_shift => "distribution_shift",
            .change_point_up => "change_point_up",
            .change_point_down => "change_point_down",
            .cardinality_spike => "cardinality_spike",
            .new_pattern_burst => "new_pattern_burst",
        };
    }

    fn trendStr(trend: pattern_mod.Trend) []const u8 {
        return switch (trend) {
            .rising => "rising",
            .stable => "stable",
            .falling => "falling",
            .new_group => "new",
            .gone => "gone",
        };
    }

    fn outcomeStr(outcome: trace_mod.TraceOutcome) []const u8 {
        return switch (outcome) {
            .success => "success",
            .failure => "failure",
            .timeout => "timeout",
            .unknown => "unknown",
        };
    }
};

/// Write a JSON-escaped string value (with quotes).
fn writeJsonString(w: std.fs.File.Writer, s: []const u8) void {
    w.writeByte('"') catch return;
    for (s) |c| {
        switch (c) {
            '"' => w.writeAll("\\\"") catch return,
            '\\' => w.writeAll("\\\\") catch return,
            '\n' => w.writeAll("\\n") catch return,
            '\r' => w.writeAll("\\r") catch return,
            '\t' => w.writeAll("\\t") catch return,
            else => {
                if (c < 0x20) {
                    w.print("\\u{x:0>4}", .{c}) catch return;
                } else {
                    w.writeByte(c) catch return;
                }
            },
        }
    }
    w.writeByte('"') catch return;
}

test "json renderer init" {
    const stdout = std.io.getStdOut().writer();
    const r = JsonRenderer.init(stdout);
    try std.testing.expectEqual(@as(u64, 0), r.events_rendered);
}
