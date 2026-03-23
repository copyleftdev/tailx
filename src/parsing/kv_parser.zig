const std = @import("std");
const core = @import("../core.zig");

const Event = core.Event;
const EventArena = core.EventArena;
const Severity = core.Severity;
const Field = core.field.Field;
const FieldValue = core.field.FieldValue;
const FieldMap = core.field.FieldMap;

/// Key-value / logfmt parser.
/// Parses lines like: level=info msg="request completed" duration=0.123 status=200
pub const KvParser = struct {
    const max_fields = 64;

    /// Parse a kv/logfmt line into Event fields.
    pub fn parse(raw: []const u8, event: *Event, arena: *EventArena) void {
        var fields_buf: [max_fields]Field = undefined;
        var field_count: usize = 0;

        var pos: usize = 0;

        while (pos < raw.len) {
            // Skip whitespace.
            while (pos < raw.len and (raw[pos] == ' ' or raw[pos] == '\t')) pos += 1;
            if (pos >= raw.len) break;

            // Find key (up to '=').
            const key_start = pos;
            while (pos < raw.len and raw[pos] != '=' and raw[pos] != ' ') pos += 1;
            if (pos >= raw.len or raw[pos] != '=') {
                // No '=' found — skip this token.
                while (pos < raw.len and raw[pos] != ' ') pos += 1;
                continue;
            }

            const key = raw[key_start..pos];
            pos += 1; // skip '='

            if (pos >= raw.len) break;

            // Parse value.
            var value: []const u8 = "";
            if (pos < raw.len and raw[pos] == '"') {
                // Quoted value.
                pos += 1;
                const val_start = pos;
                while (pos < raw.len and raw[pos] != '"') {
                    if (raw[pos] == '\\' and pos + 1 < raw.len) {
                        pos += 1; // skip escaped char
                    }
                    pos += 1;
                }
                value = raw[val_start..pos];
                if (pos < raw.len) pos += 1; // skip closing "
            } else {
                // Bare value (terminated by space).
                const val_start = pos;
                while (pos < raw.len and raw[pos] != ' ' and raw[pos] != '\t') pos += 1;
                value = raw[val_start..pos];
            }

            // Map known fields to Event struct.
            if (mapKnownField(key, value, event, arena)) continue;

            // Generic field — try to parse as number.
            if (field_count < max_fields) {
                const owned_key = arena.dupeString(key) catch break;
                fields_buf[field_count] = .{
                    .key = owned_key,
                    .value = inferValue(value, arena) catch break,
                };
                field_count += 1;
            }
        }

        if (field_count > 0) {
            const owned_fields = arena.alloc(Field, field_count) catch return;
            @memcpy(owned_fields, fields_buf[0..field_count]);
            event.fields = FieldMap{ .fields = owned_fields };
        }
    }

    fn mapKnownField(key: []const u8, value: []const u8, event: *Event, arena: *EventArena) bool {
        if (eqlAny(key, &.{ "level", "severity", "lvl", "loglevel", "log_level" })) {
            event.severity = Severity.parse(value);
            return true;
        }
        if (eqlAny(key, &.{ "message", "msg", "log", "text", "body" })) {
            event.message = arena.dupeString(value) catch return true;
            return true;
        }
        if (eqlAny(key, &.{ "trace_id", "traceId", "trace", "request_id" })) {
            event.trace_id = arena.dupeString(value) catch return true;
            return true;
        }
        if (eqlAny(key, &.{ "service", "service_name", "app", "application", "component" })) {
            event.service = arena.dupeString(value) catch return true;
            return true;
        }
        if (eqlAny(key, &.{ "timestamp", "ts", "time", "@timestamp", "datetime", "t" })) {
            // Try ISO 8601.
            const qt = @import("../ingestion/quick_timestamp.zig").QuickTimestamp;
            if (qt.extract(value)) |nanos| {
                event.timestamp.nanos = nanos;
            }
            return true;
        }
        return false;
    }

    fn inferValue(raw_value: []const u8, arena: *EventArena) !FieldValue {
        // Try integer.
        if (std.fmt.parseInt(i64, raw_value, 10)) |v| {
            return FieldValue{ .int = v };
        } else |_| {}

        // Try float.
        if (std.fmt.parseFloat(f64, raw_value)) |v| {
            return FieldValue{ .float = v };
        } else |_| {}

        // Try boolean.
        if (std.mem.eql(u8, raw_value, "true")) return FieldValue{ .boolean = true };
        if (std.mem.eql(u8, raw_value, "false")) return FieldValue{ .boolean = false };

        // String.
        return FieldValue{ .string = try arena.dupeString(raw_value) };
    }

    fn eqlAny(key: []const u8, candidates: []const []const u8) bool {
        for (candidates) |c| {
            if (std.mem.eql(u8, key, c)) return true;
        }
        return false;
    }
};

test "kv parser logfmt" {
    const allocator = std.testing.allocator;
    var arena = core.EventArena.init(allocator, 0, 0);
    defer arena.deinit();

    const raw = "ts=2024-03-15T14:23:01Z level=warn msg=\"disk usage high\" host=db01 usage=0.92";
    var event = Event.shell(raw, 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    KvParser.parse(raw, &event, &arena);

    try std.testing.expectEqual(Severity.warn, event.severity);
    try std.testing.expectEqualStrings("disk usage high", event.message);
    try std.testing.expect(event.timestamp.nanos > 0);
    try std.testing.expectEqualStrings("db01", event.fields.getString("host").?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.92), event.fields.getFloat("usage").?, 0.001);
}

test "kv parser numeric values" {
    const allocator = std.testing.allocator;
    var arena = core.EventArena.init(allocator, 0, 0);
    defer arena.deinit();

    const raw = "level=info msg=test status=200 duration=0.042 debug=true";
    var event = Event.shell(raw, 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    KvParser.parse(raw, &event, &arena);

    try std.testing.expectEqual(Severity.info, event.severity);
    try std.testing.expectEqual(@as(i64, 200), event.fields.get("status").?.int);
    try std.testing.expectApproxEqAbs(@as(f64, 0.042), event.fields.getFloat("duration").?, 0.0001);
    try std.testing.expect(event.fields.get("debug").?.boolean);
}

test "kv parser service extraction" {
    const allocator = std.testing.allocator;
    var arena = core.EventArena.init(allocator, 0, 0);
    defer arena.deinit();

    const raw = "level=error service=payments msg=\"connection refused\" trace_id=abc123";
    var event = Event.shell(raw, 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    KvParser.parse(raw, &event, &arena);

    try std.testing.expectEqual(Severity.err, event.severity);
    try std.testing.expectEqualStrings("payments", event.service.?);
    try std.testing.expectEqualStrings("abc123", event.trace_id.?);
    try std.testing.expectEqualStrings("connection refused", event.message);
}
