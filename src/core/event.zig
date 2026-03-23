const std = @import("std");
const Timestamp = @import("timestamp.zig").Timestamp;
const Severity = @import("severity.zig").Severity;
const FieldMap = @import("field.zig").FieldMap;

pub const SourceId = u16;

pub const Event = struct {
    /// When it happened (total-ordered).
    timestamp: Timestamp,

    /// Severity level (parsed or inferred).
    severity: Severity,

    /// Which source produced this event.
    source: SourceId,

    /// The raw, unparsed line. Slice into ingestion buffer or arena.
    raw: []const u8,

    /// The extracted message body (may alias raw or be a sub-slice).
    message: []const u8,

    /// Trace ID if present.
    trace_id: ?[]const u8,

    /// Service/component name if identified.
    service: ?[]const u8,

    /// Structured fields extracted from JSON or parsed formats.
    fields: FieldMap,

    /// Fingerprint hash of the log template (set by Drain).
    /// 0 means not yet fingerprinted.
    template_hash: u64,

    /// Arena generation that owns this event's variable-length data.
    arena_generation: u32,

    /// Create a shell event from a raw line (pre-parsing).
    pub fn shell(raw: []const u8, source: SourceId, ts: Timestamp, arena_gen: u32) Event {
        return .{
            .timestamp = ts,
            .severity = .unknown,
            .source = source,
            .raw = raw,
            .message = raw,
            .trace_id = null,
            .service = null,
            .fields = FieldMap.empty,
            .template_hash = 0,
            .arena_generation = arena_gen,
        };
    }
};

test "event shell creation" {
    const raw = "2024-03-15 ERROR something broke";
    const ts = Timestamp{ .nanos = 1000, .seq = 0 };
    const event = Event.shell(raw, 0, ts, 1);

    try std.testing.expectEqualStrings(raw, event.raw);
    try std.testing.expectEqualStrings(raw, event.message);
    try std.testing.expectEqual(Severity.unknown, event.severity);
    try std.testing.expectEqual(@as(SourceId, 0), event.source);
    try std.testing.expectEqual(@as(?[]const u8, null), event.trace_id);
    try std.testing.expectEqual(@as(?[]const u8, null), event.service);
    try std.testing.expectEqual(@as(u64, 0), event.template_hash);
    try std.testing.expectEqual(@as(u32, 1), event.arena_generation);
}

test "event size" {
    // Verify the event struct is reasonably sized for cache efficiency.
    const size = @sizeOf(Event);
    try std.testing.expect(size <= 256);
}
