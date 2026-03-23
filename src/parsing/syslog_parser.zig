const std = @import("std");
const core = @import("../core.zig");

const Event = core.Event;
const EventArena = core.EventArena;
const Severity = core.Severity;
const Field = core.field.Field;
const FieldValue = core.field.FieldValue;
const FieldMap = core.field.FieldMap;

/// Syslog BSD (RFC 3164) parser.
/// Format: <PRI>Mon DD HH:MM:SS hostname app[pid]: message
/// Also handles journalctl output: Mon DD HH:MM:SS hostname app[pid]: message
pub const SyslogBsdParser = struct {
    const max_fields = 8;

    pub fn parse(raw: []const u8, event: *Event, arena: *EventArena) void {
        var pos: usize = 0;
        var fields_buf: [max_fields]Field = undefined;
        var field_count: usize = 0;

        // 1. Optional PRI: <digits>
        if (pos < raw.len and raw[pos] == '<') {
            const pri_result = parsePri(raw, pos);
            if (pri_result.severity != .unknown) {
                event.severity = pri_result.severity;
            }
            pos = pri_result.end_pos;
        }

        // 2. Timestamp: "Mon DD HH:MM:SS" or ISO 8601
        pos = skipWhitespace(raw, pos);
        const ts_result = parseTimestamp(raw, pos);
        pos = ts_result.end_pos;

        // 3. Hostname.
        pos = skipWhitespace(raw, pos);
        const hostname_start = pos;
        while (pos < raw.len and raw[pos] != ' ') pos += 1;
        const hostname = raw[hostname_start..pos];

        if (hostname.len > 0 and field_count < max_fields) {
            if (arena.dupeString(hostname)) |h| {
                fields_buf[field_count] = .{ .key = "hostname", .value = .{ .string = h } };
                field_count += 1;
            } else |_| {}
        }

        // 4. App[pid]: or App:
        pos = skipWhitespace(raw, pos);
        const app_start = pos;
        var pid_str: ?[]const u8 = null;

        while (pos < raw.len and raw[pos] != ':' and raw[pos] != ' ' and raw[pos] != '[') pos += 1;

        const app_name = raw[app_start..pos];

        // Parse [pid] if present.
        if (pos < raw.len and raw[pos] == '[') {
            const pid_start = pos + 1;
            pos += 1;
            while (pos < raw.len and raw[pos] != ']') pos += 1;
            pid_str = raw[pid_start..pos];
            if (pos < raw.len) pos += 1; // skip ']'
        }

        // Skip ':' and whitespace after app.
        if (pos < raw.len and raw[pos] == ':') pos += 1;
        pos = skipWhitespace(raw, pos);

        // Set service from app name.
        if (app_name.len > 0) {
            event.service = arena.dupeString(app_name) catch null;
        }

        // Store PID as field.
        if (pid_str) |pid| {
            if (field_count < max_fields) {
                if (arena.dupeString(pid)) |p| {
                    // Try to parse as integer.
                    if (std.fmt.parseInt(i64, p, 10)) |pid_int| {
                        fields_buf[field_count] = .{ .key = "pid", .value = .{ .int = pid_int } };
                    } else |_| {
                        fields_buf[field_count] = .{ .key = "pid", .value = .{ .string = p } };
                    }
                    field_count += 1;
                } else |_| {}
            }
        }

        // 5. Remainder is message.
        if (pos < raw.len) {
            event.message = arena.dupeString(raw[pos..]) catch raw[pos..];

            // Try to infer severity from message if not set from PRI.
            if (event.severity == .unknown) {
                event.severity = inferSeverityFromMessage(raw[pos..]);
            }
        }

        // Commit fields.
        if (field_count > 0) {
            const owned_fields = arena.alloc(Field, field_count) catch return;
            @memcpy(owned_fields, fields_buf[0..field_count]);
            event.fields = FieldMap{ .fields = owned_fields };
        }
    }

    const PriResult = struct { severity: Severity, end_pos: usize };

    fn parsePri(raw: []const u8, start: usize) PriResult {
        if (start >= raw.len or raw[start] != '<') return .{ .severity = .unknown, .end_pos = start };
        var pos = start + 1;
        while (pos < raw.len and raw[pos] >= '0' and raw[pos] <= '9') pos += 1;
        if (pos >= raw.len or raw[pos] != '>') return .{ .severity = .unknown, .end_pos = start };

        const pri_str = raw[start + 1 .. pos];
        const pri = std.fmt.parseInt(u8, pri_str, 10) catch return .{ .severity = .unknown, .end_pos = pos + 1 };
        const sev_val = pri & 0x07; // lowest 3 bits = severity

        const severity: Severity = switch (sev_val) {
            0, 1, 2 => .fatal, // emergency, alert, critical
            3 => .err,
            4 => .warn,
            5 => .info, // notice
            6 => .info,
            7 => .debug,
            else => .unknown,
        };

        return .{ .severity = severity, .end_pos = pos + 1 };
    }

    const TimestampResult = struct { end_pos: usize };

    fn parseTimestamp(raw: []const u8, start: usize) TimestampResult {
        var pos = start;

        // ISO 8601: 2024-03-15T...
        if (pos + 19 <= raw.len and raw[pos + 4] == '-' and raw[pos + 7] == '-') {
            while (pos < raw.len and raw[pos] != ' ') pos += 1;
            return .{ .end_pos = pos };
        }

        // BSD: Mon DD HH:MM:SS (15 chars typical)
        // Month abbreviation (3 chars).
        if (pos + 15 <= raw.len and raw[pos + 3] == ' ') {
            // Skip "Mon DD HH:MM:SS"
            pos += 3; // month
            pos = skipWhitespace(raw, pos);
            while (pos < raw.len and raw[pos] != ' ') pos += 1; // day
            pos = skipWhitespace(raw, pos);
            // HH:MM:SS
            if (pos + 8 <= raw.len and raw[pos + 2] == ':' and raw[pos + 5] == ':') {
                pos += 8;
                return .{ .end_pos = pos };
            }
        }

        return .{ .end_pos = start };
    }

    fn inferSeverityFromMessage(msg: []const u8) Severity {
        // Quick scan for common severity indicators in syslog messages.
        if (msg.len < 3) return .unknown;

        // Check for <level> prefixes common in NetworkManager, etc.
        if (msg[0] == '<') {
            if (std.mem.startsWith(u8, msg, "<error>")) return .err;
            if (std.mem.startsWith(u8, msg, "<warn>")) return .warn;
            if (std.mem.startsWith(u8, msg, "<info>")) return .info;
            if (std.mem.startsWith(u8, msg, "<debug>")) return .debug;
        }

        // Check for ERROR/WARN/INFO prefix.
        const upper4 = if (msg.len >= 5) msg[0..5] else msg;
        if (std.ascii.startsWithIgnoreCase(upper4, "error") or std.ascii.startsWithIgnoreCase(upper4, "err:")) return .err;
        if (std.ascii.startsWithIgnoreCase(upper4, "warn")) return .warn;

        return .unknown;
    }

    fn skipWhitespace(raw: []const u8, start: usize) usize {
        var pos = start;
        while (pos < raw.len and (raw[pos] == ' ' or raw[pos] == '\t')) pos += 1;
        return pos;
    }
};

test "syslog BSD with PRI" {
    const allocator = std.testing.allocator;
    var arena = core.EventArena.init(allocator, 0, 0);
    defer arena.deinit();

    const raw = "<134>Mar 15 14:23:01 web01 nginx[1234]: GET /api 200 0.012";
    var event = Event.shell(raw, 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    SyslogBsdParser.parse(raw, &event, &arena);

    try std.testing.expectEqual(Severity.info, event.severity); // PRI 134 = facility 16, sev 6 = info
    try std.testing.expectEqualStrings("nginx", event.service.?);
    try std.testing.expectEqualStrings("GET /api 200 0.012", event.message);
    try std.testing.expectEqual(@as(i64, 1234), event.fields.get("pid").?.int);
    try std.testing.expectEqualStrings("web01", event.fields.getString("hostname").?);
}

test "syslog journalctl format (no PRI)" {
    const allocator = std.testing.allocator;
    var arena = core.EventArena.init(allocator, 0, 0);
    defer arena.deinit();

    const raw = "Mar 23 06:28:13 4ubox ghostty[136440]: info(page_list): adjusting page capacity";
    var event = Event.shell(raw, 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    SyslogBsdParser.parse(raw, &event, &arena);

    try std.testing.expectEqualStrings("ghostty", event.service.?);
    try std.testing.expectEqualStrings("info(page_list): adjusting page capacity", event.message);
    try std.testing.expectEqual(@as(i64, 136440), event.fields.get("pid").?.int);
}

test "syslog with NetworkManager severity inference" {
    const allocator = std.testing.allocator;
    var arena = core.EventArena.init(allocator, 0, 0);
    defer arena.deinit();

    const raw = "Mar 23 06:28:13 host1 NetworkManager[2876]: <warn>  device (eth0): link disconnected";
    var event = Event.shell(raw, 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    SyslogBsdParser.parse(raw, &event, &arena);

    try std.testing.expectEqual(Severity.warn, event.severity);
    try std.testing.expectEqualStrings("NetworkManager", event.service.?);
}

test "syslog app without PID" {
    const allocator = std.testing.allocator;
    var arena = core.EventArena.init(allocator, 0, 0);
    defer arena.deinit();

    const raw = "Mar 23 10:00:00 myhost systemd: Started daily cleanup.";
    var event = Event.shell(raw, 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    SyslogBsdParser.parse(raw, &event, &arena);

    try std.testing.expectEqualStrings("systemd", event.service.?);
    try std.testing.expectEqualStrings("Started daily cleanup.", event.message);
}
