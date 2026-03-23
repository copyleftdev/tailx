const std = @import("std");
const core = @import("../core.zig");

const Event = core.Event;
const EventArena = core.EventArena;
const Severity = core.Severity;

/// Fallback parser for unstructured log lines.
/// Extracts timestamp prefix, severity keywords, and optional service name.
pub const FallbackParser = struct {
    /// Parse an unstructured line, extracting what we can.
    pub fn parse(raw: []const u8, event: *Event, arena: *EventArena) void {
        var pos: usize = 0;

        // 1. Try to extract and skip a timestamp prefix.
        pos = skipTimestamp(raw);

        // 2. Skip whitespace after timestamp.
        while (pos < raw.len and (raw[pos] == ' ' or raw[pos] == '\t')) pos += 1;

        // 3. Extract severity from the remaining text.
        const sev_result = extractSeverity(raw[pos..]);
        if (sev_result.severity != .unknown) {
            event.severity = sev_result.severity;
            pos += sev_result.consumed;
            while (pos < raw.len and (raw[pos] == ' ' or raw[pos] == '\t')) pos += 1;
        }

        // 4. Extract service/component from brackets: [ServiceName]
        const svc_result = extractService(raw[pos..]);
        if (svc_result.service.len > 0) {
            event.service = arena.dupeString(svc_result.service) catch null;
            pos += svc_result.consumed;
            while (pos < raw.len and (raw[pos] == ' ' or raw[pos] == '\t')) pos += 1;
        }

        // 5. Remainder is the message.
        if (pos < raw.len) {
            event.message = arena.dupeString(raw[pos..]) catch raw[pos..];
        }
    }

    /// Skip a timestamp prefix, returning the position after it.
    fn skipTimestamp(raw: []const u8) usize {
        if (raw.len < 10) return 0;

        // ISO 8601: 2024-03-15T14:23:01 or 2024-03-15 14:23:01
        if (raw.len >= 19 and raw[4] == '-' and raw[7] == '-' and
            (raw[10] == 'T' or raw[10] == ' ') and raw[13] == ':' and raw[16] == ':')
        {
            var pos: usize = 19;
            // Skip fractional seconds.
            if (pos < raw.len and raw[pos] == '.') {
                pos += 1;
                while (pos < raw.len and raw[pos] >= '0' and raw[pos] <= '9') pos += 1;
            }
            // Skip timezone (Z, +00:00, etc.)
            if (pos < raw.len and raw[pos] == 'Z') {
                pos += 1;
            } else if (pos < raw.len and (raw[pos] == '+' or raw[pos] == '-')) {
                pos += 1;
                while (pos < raw.len and (raw[pos] >= '0' and raw[pos] <= '9' or raw[pos] == ':')) pos += 1;
            }
            return pos;
        }

        // Epoch seconds: 10 digits followed by space.
        if (raw[0] >= '1' and raw[0] <= '9') {
            var i: usize = 0;
            while (i < raw.len and i < 12 and raw[i] >= '0' and raw[i] <= '9') i += 1;
            if (i == 10 and (i >= raw.len or raw[i] == ' ' or raw[i] == '\t')) {
                return i;
            }
        }

        return 0;
    }

    const SeverityResult = struct { severity: Severity, consumed: usize };

    fn extractSeverity(text: []const u8) SeverityResult {
        if (text.len == 0) return .{ .severity = .unknown, .consumed = 0 };

        // Bracketed: [ERROR], [WARN], etc.
        if (text[0] == '[') {
            var end: usize = 1;
            while (end < text.len and end < 20 and text[end] != ']') end += 1;
            if (end < text.len and text[end] == ']') {
                const inner = text[1..end];
                const sev = Severity.parse(inner);
                if (sev != .unknown) {
                    return .{ .severity = sev, .consumed = end + 1 };
                }
            }
        }

        // Bare severity word at start of text.
        const keywords = [_]struct { word: []const u8, sev: Severity }{
            .{ .word = "FATAL", .sev = .fatal },
            .{ .word = "CRITICAL", .sev = .fatal },
            .{ .word = "CRIT", .sev = .fatal },
            .{ .word = "ERROR", .sev = .err },
            .{ .word = "ERR", .sev = .err },
            .{ .word = "WARN", .sev = .warn },
            .{ .word = "WARNING", .sev = .warn },
            .{ .word = "WRN", .sev = .warn },
            .{ .word = "INFO", .sev = .info },
            .{ .word = "INF", .sev = .info },
            .{ .word = "DEBUG", .sev = .debug },
            .{ .word = "DBG", .sev = .debug },
            .{ .word = "TRACE", .sev = .trace },
        };

        for (keywords) |kw| {
            if (text.len >= kw.word.len and std.ascii.eqlIgnoreCase(text[0..kw.word.len], kw.word)) {
                // Must be followed by space, colon, or end.
                if (kw.word.len >= text.len or text[kw.word.len] == ' ' or
                    text[kw.word.len] == ':' or text[kw.word.len] == '\t' or
                    text[kw.word.len] == ']')
                {
                    var consumed = kw.word.len;
                    // Skip optional colon after severity.
                    if (consumed < text.len and text[consumed] == ':') consumed += 1;
                    return .{ .severity = kw.sev, .consumed = consumed };
                }
            }
        }

        return .{ .severity = .unknown, .consumed = 0 };
    }

    const ServiceResult = struct { service: []const u8, consumed: usize };

    fn extractService(text: []const u8) ServiceResult {
        if (text.len < 3) return .{ .service = "", .consumed = 0 };

        // Bracketed service: [ServiceName]
        if (text[0] == '[') {
            var end: usize = 1;
            while (end < text.len and end < 50 and text[end] != ']') {
                // Service names shouldn't contain spaces (that's more likely a severity bracket).
                if (text[end] == ' ') return .{ .service = "", .consumed = 0 };
                end += 1;
            }
            if (end < text.len and text[end] == ']' and end > 1) {
                return .{ .service = text[1..end], .consumed = end + 1 };
            }
        }

        return .{ .service = "", .consumed = 0 };
    }
};

test "fallback parser unstructured with all parts" {
    const allocator = std.testing.allocator;
    var arena = core.EventArena.init(allocator, 0, 0);
    defer arena.deinit();

    const raw = "2024-03-15 14:23:01 ERROR [PaymentService] Connection refused";
    var event = Event.shell(raw, 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    FallbackParser.parse(raw, &event, &arena);

    try std.testing.expectEqual(Severity.err, event.severity);
    try std.testing.expectEqualStrings("PaymentService", event.service.?);
    try std.testing.expectEqualStrings("Connection refused", event.message);
}

test "fallback parser severity only" {
    const allocator = std.testing.allocator;
    var arena = core.EventArena.init(allocator, 0, 0);
    defer arena.deinit();

    const raw = "WARN something happened";
    var event = Event.shell(raw, 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    FallbackParser.parse(raw, &event, &arena);

    try std.testing.expectEqual(Severity.warn, event.severity);
    try std.testing.expectEqualStrings("something happened", event.message);
}

test "fallback parser iso timestamp with timezone" {
    const allocator = std.testing.allocator;
    var arena = core.EventArena.init(allocator, 0, 0);
    defer arena.deinit();

    const raw = "2024-03-15T14:23:01.123Z INFO startup complete";
    var event = Event.shell(raw, 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    FallbackParser.parse(raw, &event, &arena);

    try std.testing.expectEqual(Severity.info, event.severity);
    try std.testing.expectEqualStrings("startup complete", event.message);
}

test "fallback parser plain message" {
    const allocator = std.testing.allocator;
    var arena = core.EventArena.init(allocator, 0, 0);
    defer arena.deinit();

    const raw = "just a plain log message";
    var event = Event.shell(raw, 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    FallbackParser.parse(raw, &event, &arena);

    try std.testing.expectEqual(Severity.unknown, event.severity);
    try std.testing.expectEqualStrings("just a plain log message", event.message);
}

test "fallback parser bracketed severity" {
    const allocator = std.testing.allocator;
    var arena = core.EventArena.init(allocator, 0, 0);
    defer arena.deinit();

    const raw = "2024-03-15 10:00:00 [FATAL] system crash";
    var event = Event.shell(raw, 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    FallbackParser.parse(raw, &event, &arena);

    try std.testing.expectEqual(Severity.fatal, event.severity);
    try std.testing.expectEqualStrings("system crash", event.message);
}
