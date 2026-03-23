const std = @import("std");
const core = @import("../core.zig");

const Event = core.Event;
const EventArena = core.EventArena;
const Severity = core.Severity;
const Field = core.field.Field;
const FieldValue = core.field.FieldValue;
const FieldMap = core.field.FieldMap;

/// Hand-written JSON scanner optimized for log event parsing.
/// Extracts known fields into Event struct, collects rest into FieldMap.
pub const JsonParser = struct {
    const max_fields = 64;

    /// Parse a JSON line into Event fields. Arena-allocates extracted strings.
    pub fn parse(raw: []const u8, event: *Event, arena: *EventArena) void {
        var fields_buf: [max_fields]Field = undefined;
        var field_count: usize = 0;

        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len < 2 or trimmed[0] != '{') return;

        var pos: usize = 1; // skip '{'

        while (pos < trimmed.len) {
            pos = skipWhitespace(trimmed, pos);
            if (pos >= trimmed.len or trimmed[pos] == '}') break;

            // Skip comma between pairs.
            if (trimmed[pos] == ',') {
                pos += 1;
                pos = skipWhitespace(trimmed, pos);
            }

            // Parse key.
            if (pos >= trimmed.len or trimmed[pos] != '"') break;
            const key = parseString(trimmed, pos + 1) orelse break;
            pos = key.end_pos;

            // Skip colon.
            pos = skipWhitespace(trimmed, pos);
            if (pos >= trimmed.len or trimmed[pos] != ':') break;
            pos += 1;
            pos = skipWhitespace(trimmed, pos);

            // Parse value and map to event fields or generic fields.
            if (pos >= trimmed.len) break;

            if (mapKnownField(key.data, trimmed, pos, event, arena)) |new_pos| {
                pos = new_pos;
            } else {
                // Generic field.
                const val_result = parseValue(trimmed, pos) orelse break;
                pos = val_result.end_pos;

                if (field_count < max_fields) {
                    const owned_key = arena.dupeString(key.data) catch break;
                    fields_buf[field_count] = .{
                        .key = owned_key,
                        .value = dupeFieldValue(val_result.value, arena) catch break,
                    };
                    field_count += 1;
                }
            }
        }

        // Commit fields to arena.
        if (field_count > 0) {
            const owned_fields = arena.alloc(Field, field_count) catch return;
            @memcpy(owned_fields, fields_buf[0..field_count]);
            event.fields = FieldMap{ .fields = owned_fields };
        }
    }

    /// Try to map a JSON key to a known Event field. Returns new pos if matched.
    fn mapKnownField(key: []const u8, data: []const u8, pos: usize, event: *Event, arena: *EventArena) ?usize {
        if (isTimestampKey(key)) {
            // Parse timestamp value.
            if (data[pos] == '"') {
                const str = parseString(data, pos + 1) orelse return null;
                // Try ISO 8601 parse.
                if (parseIso8601Nanos(str.data)) |nanos| {
                    event.timestamp.nanos = nanos;
                }
                return str.end_pos;
            } else {
                // Numeric timestamp (epoch millis/seconds).
                const num = parseNumber(data, pos) orelse return null;
                switch (num.value) {
                    .int => |v| {
                        if (v > 946684800000) {
                            // Epoch millis.
                            event.timestamp.nanos = @as(i128, v) * std.time.ns_per_ms;
                        } else if (v > 946684800) {
                            // Epoch seconds.
                            event.timestamp.nanos = @as(i128, v) * std.time.ns_per_s;
                        }
                    },
                    .float => |v| {
                        // Epoch seconds with fraction.
                        event.timestamp.nanos = @intFromFloat(v * @as(f64, @floatFromInt(std.time.ns_per_s)));
                    },
                    else => {},
                }
                return num.end_pos;
            }
        }

        if (isSeverityKey(key)) {
            if (data[pos] == '"') {
                const str = parseString(data, pos + 1) orelse return null;
                event.severity = Severity.parse(str.data);
                return str.end_pos;
            } else {
                const val = parseValue(data, pos) orelse return null;
                return val.end_pos;
            }
        }

        if (isMessageKey(key)) {
            if (data[pos] == '"') {
                const str = parseString(data, pos + 1) orelse return null;
                event.message = arena.dupeString(str.data) catch return null;
                return str.end_pos;
            } else {
                const val = parseValue(data, pos) orelse return null;
                return val.end_pos;
            }
        }

        if (isTraceIdKey(key)) {
            if (data[pos] == '"') {
                const str = parseString(data, pos + 1) orelse return null;
                event.trace_id = arena.dupeString(str.data) catch return null;
                return str.end_pos;
            } else {
                const val = parseValue(data, pos) orelse return null;
                return val.end_pos;
            }
        }

        if (isServiceKey(key)) {
            if (data[pos] == '"') {
                const str = parseString(data, pos + 1) orelse return null;
                event.service = arena.dupeString(str.data) catch return null;
                return str.end_pos;
            } else {
                const val = parseValue(data, pos) orelse return null;
                return val.end_pos;
            }
        }

        return null;
    }

    fn isTimestampKey(key: []const u8) bool {
        return eqlAny(key, &.{ "timestamp", "ts", "time", "@timestamp", "datetime", "t" });
    }

    fn isSeverityKey(key: []const u8) bool {
        return eqlAny(key, &.{ "level", "severity", "lvl", "loglevel", "log_level" });
    }

    fn isMessageKey(key: []const u8) bool {
        return eqlAny(key, &.{ "message", "msg", "log", "text", "body" });
    }

    fn isTraceIdKey(key: []const u8) bool {
        return eqlAny(key, &.{ "trace_id", "traceId", "trace", "x-trace-id", "request_id" });
    }

    fn isServiceKey(key: []const u8) bool {
        return eqlAny(key, &.{ "service", "service_name", "app", "application", "component" });
    }

    fn eqlAny(key: []const u8, candidates: []const []const u8) bool {
        for (candidates) |c| {
            if (std.mem.eql(u8, key, c)) return true;
        }
        return false;
    }

    const StringResult = struct { data: []const u8, end_pos: usize };

    fn parseString(data: []const u8, start: usize) ?StringResult {
        // start is the position AFTER the opening quote.
        var pos = start;
        while (pos < data.len) {
            if (data[pos] == '\\') {
                pos += 2; // skip escaped char
                continue;
            }
            if (data[pos] == '"') {
                return .{
                    .data = data[start..pos],
                    .end_pos = pos + 1,
                };
            }
            pos += 1;
        }
        return null;
    }

    const ValueResult = struct { value: FieldValue, end_pos: usize };

    fn parseValue(data: []const u8, pos: usize) ?ValueResult {
        if (pos >= data.len) return null;

        return switch (data[pos]) {
            '"' => {
                const str = parseString(data, pos + 1) orelse return null;
                return .{ .value = .{ .string = str.data }, .end_pos = str.end_pos };
            },
            't' => {
                if (pos + 4 <= data.len and std.mem.eql(u8, data[pos..][0..4], "true")) {
                    return .{ .value = .{ .boolean = true }, .end_pos = pos + 4 };
                }
                return null;
            },
            'f' => {
                if (pos + 5 <= data.len and std.mem.eql(u8, data[pos..][0..5], "false")) {
                    return .{ .value = .{ .boolean = false }, .end_pos = pos + 5 };
                }
                return null;
            },
            'n' => {
                if (pos + 4 <= data.len and std.mem.eql(u8, data[pos..][0..4], "null")) {
                    return .{ .value = .{ .null_val = {} }, .end_pos = pos + 4 };
                }
                return null;
            },
            '{' => {
                // Skip nested object — don't parse deeply.
                const end = skipNested(data, pos, '{', '}') orelse return null;
                return .{ .value = .{ .string = data[pos..end] }, .end_pos = end };
            },
            '[' => {
                // Skip array.
                const end = skipNested(data, pos, '[', ']') orelse return null;
                return .{ .value = .{ .string = data[pos..end] }, .end_pos = end };
            },
            else => {
                // Number.
                const num = parseNumber(data, pos) orelse return null;
                return num;
            },
        };
    }

    fn parseNumber(data: []const u8, start: usize) ?ValueResult {
        var pos = start;
        var has_dot = false;
        if (pos < data.len and (data[pos] == '-' or data[pos] == '+')) pos += 1;
        if (pos >= data.len or (data[pos] < '0' or data[pos] > '9')) return null;

        while (pos < data.len) {
            if (data[pos] >= '0' and data[pos] <= '9') {
                pos += 1;
            } else if (data[pos] == '.' and !has_dot) {
                has_dot = true;
                pos += 1;
            } else if (data[pos] == 'e' or data[pos] == 'E') {
                has_dot = true; // treat as float
                pos += 1;
                if (pos < data.len and (data[pos] == '-' or data[pos] == '+')) pos += 1;
            } else {
                break;
            }
        }

        const slice = data[start..pos];
        if (has_dot) {
            const v = std.fmt.parseFloat(f64, slice) catch return null;
            return .{ .value = .{ .float = v }, .end_pos = pos };
        } else {
            const v = std.fmt.parseInt(i64, slice, 10) catch return null;
            return .{ .value = .{ .int = v }, .end_pos = pos };
        }
    }

    fn skipNested(data: []const u8, start: usize, open: u8, close: u8) ?usize {
        var depth: u32 = 0;
        var pos = start;
        var in_str = false;
        while (pos < data.len) {
            if (in_str) {
                if (data[pos] == '\\') {
                    pos += 1;
                } else if (data[pos] == '"') {
                    in_str = false;
                }
            } else {
                if (data[pos] == '"') {
                    in_str = true;
                } else if (data[pos] == open) {
                    depth += 1;
                } else if (data[pos] == close) {
                    depth -= 1;
                    if (depth == 0) return pos + 1;
                }
            }
            pos += 1;
        }
        return null;
    }

    fn skipWhitespace(data: []const u8, start: usize) usize {
        var pos = start;
        while (pos < data.len and (data[pos] == ' ' or data[pos] == '\t' or data[pos] == '\n' or data[pos] == '\r')) {
            pos += 1;
        }
        return pos;
    }

    fn dupeFieldValue(value: FieldValue, arena: *EventArena) !FieldValue {
        return switch (value) {
            .string => |s| FieldValue{ .string = try arena.dupeString(s) },
            else => value,
        };
    }

    fn parseIso8601Nanos(s: []const u8) ?i128 {
        // Reuse the logic from quick_timestamp but on an already-extracted string.
        const qt = @import("../ingestion/quick_timestamp.zig").QuickTimestamp;
        return qt.extract(s);
    }
};

test "json parser full event" {
    const allocator = std.testing.allocator;
    var arena = core.EventArena.init(allocator, 0, 0);
    defer arena.deinit();

    const raw = "{\"timestamp\":\"2024-03-15T14:23:01.123Z\",\"level\":\"error\",\"service\":\"payments\",\"msg\":\"timeout\",\"traceId\":\"abc123\",\"latency_ms\":240}";

    var event = Event.shell(raw, 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    JsonParser.parse(raw, &event, &arena);

    try std.testing.expectEqual(Severity.err, event.severity);
    try std.testing.expectEqualStrings("timeout", event.message);
    try std.testing.expectEqualStrings("payments", event.service.?);
    try std.testing.expectEqualStrings("abc123", event.trace_id.?);
    // Timestamp should be updated.
    try std.testing.expect(event.timestamp.nanos > 0);
    // latency_ms should be in generic fields.
    try std.testing.expectEqual(@as(i64, 240), event.fields.get("latency_ms").?.int);
}

test "json parser numeric fields" {
    const allocator = std.testing.allocator;
    var arena = core.EventArena.init(allocator, 0, 0);
    defer arena.deinit();

    const raw = "{\"msg\":\"req\",\"status\":200,\"latency\":0.042,\"debug\":true}";
    var event = Event.shell(raw, 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    JsonParser.parse(raw, &event, &arena);

    try std.testing.expectEqualStrings("req", event.message);
    try std.testing.expectEqual(@as(i64, 200), event.fields.get("status").?.int);
    try std.testing.expectApproxEqAbs(@as(f64, 0.042), event.fields.get("latency").?.float, 0.0001);
    try std.testing.expect(event.fields.get("debug").?.boolean);
}

test "json parser epoch millis timestamp" {
    const allocator = std.testing.allocator;
    var arena = core.EventArena.init(allocator, 0, 0);
    defer arena.deinit();

    const raw = "{\"ts\":1710510181123,\"msg\":\"test\"}";
    var event = Event.shell(raw, 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    JsonParser.parse(raw, &event, &arena);

    // Should interpret as epoch millis.
    const expected: i128 = 1710510181123 * std.time.ns_per_ms;
    try std.testing.expectEqual(expected, event.timestamp.nanos);
}

test "json parser null and boolean values" {
    const allocator = std.testing.allocator;
    var arena = core.EventArena.init(allocator, 0, 0);
    defer arena.deinit();

    const raw = "{\"msg\":\"test\",\"extra\":null,\"flag\":false}";
    var event = Event.shell(raw, 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    JsonParser.parse(raw, &event, &arena);

    try std.testing.expectEqual(FieldValue{ .null_val = {} }, event.fields.get("extra").?);
    try std.testing.expectEqual(false, event.fields.get("flag").?.boolean);
}

test "json parser empty object" {
    const allocator = std.testing.allocator;
    var arena = core.EventArena.init(allocator, 0, 0);
    defer arena.deinit();

    const raw = "{}";
    var event = Event.shell(raw, 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    JsonParser.parse(raw, &event, &arena);
    // Should not crash, no fields added.
    try std.testing.expectEqual(@as(usize, 0), event.fields.len());
}
