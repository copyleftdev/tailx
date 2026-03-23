const std = @import("std");

/// Fast timestamp extraction from the first ~48 bytes of a log line.
/// Attempts common formats in order; returns nanoseconds since epoch or null.
pub const QuickTimestamp = struct {
    /// Attempt fast timestamp extraction. Returns nanos since epoch or null.
    pub fn extract(line: []const u8) ?i128 {
        if (line.len == 0) return null;
        return extractIso8601(line) orelse
            extractEpochMillisJson(line) orelse
            extractEpochSeconds(line);
    }

    /// ISO 8601: "2024-03-15T14:23:01.123Z" or "2024-03-15T14:23:01"
    /// Checks first 30 bytes.
    fn extractIso8601(line: []const u8) ?i128 {
        if (line.len < 19) return null;

        // Quick check: YYYY-MM-DDT pattern.
        if (line[4] != '-' or line[7] != '-' or (line[10] != 'T' and line[10] != ' ')) return null;

        const year = parseDigits(line[0..4], 4) orelse return null;
        const month = parseDigits(line[5..7], 2) orelse return null;
        const day = parseDigits(line[8..10], 2) orelse return null;
        const hour = parseDigits(line[11..13], 2) orelse return null;
        const minute = parseDigits(line[14..16], 2) orelse return null;

        if (line[13] != ':' or line[16] != ':') return null;

        const second = parseDigits(line[17..19], 2) orelse return null;

        if (month < 1 or month > 12) return null;
        if (day < 1 or day > 31) return null;
        if (hour > 23 or minute > 59 or second > 60) return null; // 60 for leap second

        // Parse optional fractional seconds.
        var frac_ns: i128 = 0;
        var pos: usize = 19;
        if (pos < line.len and line[pos] == '.') {
            pos += 1;
            var frac_val: u64 = 0;
            var frac_digits: u32 = 0;
            while (pos < line.len and pos < 30 and line[pos] >= '0' and line[pos] <= '9') {
                frac_val = frac_val * 10 + (line[pos] - '0');
                frac_digits += 1;
                pos += 1;
            }
            // Normalize to nanoseconds (9 digits).
            while (frac_digits < 9) : (frac_digits += 1) {
                frac_val *= 10;
            }
            while (frac_digits > 9) : (frac_digits -= 1) {
                frac_val /= 10;
            }
            frac_ns = @intCast(frac_val);
        }

        // Convert to epoch nanos using a simple calendar calculation.
        const epoch_days = epochDays(@intCast(year), @intCast(month), @intCast(day)) orelse return null;
        const day_ns: i128 = @as(i128, epoch_days) * 86400 * std.time.ns_per_s;
        const time_ns: i128 = (@as(i128, hour) * 3600 + @as(i128, minute) * 60 + @as(i128, second)) * std.time.ns_per_s;

        return day_ns + time_ns + frac_ns;
    }

    /// JSON epoch milliseconds: {"ts":1710510181123, or {"timestamp":171...
    fn extractEpochMillisJson(line: []const u8) ?i128 {
        // Look for "ts": or "timestamp": followed by digits.
        const prefix = if (std.mem.indexOf(u8, line[0..@min(line.len, 48)], "\"ts\":")) |p|
            p + 5
        else if (std.mem.indexOf(u8, line[0..@min(line.len, 48)], "\"timestamp\":")) |p|
            p + 12
        else
            return null;

        // Skip whitespace.
        var pos = prefix;
        while (pos < line.len and line[pos] == ' ') pos += 1;

        // Parse digits.
        const start = pos;
        while (pos < line.len and line[pos] >= '0' and line[pos] <= '9') pos += 1;

        if (pos - start < 10 or pos - start > 16) return null; // not a plausible epoch

        const millis = std.fmt.parseInt(i64, line[start..pos], 10) catch return null;

        // Plausibility check: epoch millis for years 2000-2100.
        if (millis < 946684800000 or millis > 4102444800000) return null;

        return @as(i128, millis) * std.time.ns_per_ms;
    }

    /// Epoch seconds at the start of a line: "1710510181 ..."
    fn extractEpochSeconds(line: []const u8) ?i128 {
        if (line.len < 10) return null;
        if (line[0] < '1' or line[0] > '9') return null; // must start with digit 1-9

        var pos: usize = 0;
        while (pos < line.len and pos < 12 and line[pos] >= '0' and line[pos] <= '9') pos += 1;

        // Must be followed by space or end of line, and be 10 digits.
        if (pos != 10) return null;
        if (pos < line.len and line[pos] != ' ' and line[pos] != '\t' and line[pos] != '.') return null;

        const secs = std.fmt.parseInt(i64, line[0..10], 10) catch return null;

        // Plausibility: 2000-01-01 to ~2100.
        if (secs < 946684800 or secs > 4102444800) return null;

        return @as(i128, secs) * std.time.ns_per_s;
    }

    fn parseDigits(data: []const u8, comptime n: usize) ?u32 {
        var val: u32 = 0;
        for (data[0..n]) |c| {
            if (c < '0' or c > '9') return null;
            val = val * 10 + (c - '0');
        }
        return val;
    }

    /// Days from Unix epoch (1970-01-01) to the given date.
    fn epochDays(year: i32, month: i32, day: i32) ?i64 {
        // Adjust for months Jan/Feb using the "March-start" trick.
        var y = year;
        var m = month;
        if (m <= 2) {
            y -= 1;
            m += 12;
        }
        // Rata Die algorithm adapted for Unix epoch.
        const era_y: i64 = @intCast(y);
        const era_m: i64 = @intCast(m);
        const era_d: i64 = @intCast(day);
        const days = 365 * era_y + @divFloor(era_y, 4) - @divFloor(era_y, 100) + @divFloor(era_y, 400) +
            @divFloor(153 * (era_m - 3) + 2, 5) + era_d - 719469;
        return days;
    }
};

test "quick timestamp iso 8601" {
    const ns = QuickTimestamp.extract("2024-03-15T14:23:01.123Z some log message");
    try std.testing.expect(ns != null);
    // 2024-03-15T14:23:01.123Z → verify roughly correct (March 2024).
    const secs = @divTrunc(ns.?, std.time.ns_per_s);
    // 2024-03-15 should be around 1710500000.
    try std.testing.expect(secs > 1710000000 and secs < 1711000000);
}

test "quick timestamp iso 8601 space separator" {
    const ns = QuickTimestamp.extract("2024-03-15 14:23:01 ERROR something");
    try std.testing.expect(ns != null);
    const secs = @divTrunc(ns.?, std.time.ns_per_s);
    try std.testing.expect(secs > 1710000000 and secs < 1711000000);
}

test "quick timestamp epoch millis json" {
    const ns = QuickTimestamp.extract("{\"ts\":1710510181123,\"msg\":\"test\"}");
    try std.testing.expect(ns != null);
    const millis = @divTrunc(ns.?, std.time.ns_per_ms);
    try std.testing.expectEqual(@as(i128, 1710510181123), millis);
}

test "quick timestamp epoch seconds" {
    const ns = QuickTimestamp.extract("1710510181 ERROR something");
    try std.testing.expect(ns != null);
    const secs = @divTrunc(ns.?, std.time.ns_per_s);
    try std.testing.expectEqual(@as(i128, 1710510181), secs);
}

test "quick timestamp no match returns null" {
    try std.testing.expectEqual(@as(?i128, null), QuickTimestamp.extract("just a plain log line"));
    try std.testing.expectEqual(@as(?i128, null), QuickTimestamp.extract(""));
    try std.testing.expectEqual(@as(?i128, null), QuickTimestamp.extract("ERROR no timestamp here"));
}

test "quick timestamp json timestamp key" {
    const ns = QuickTimestamp.extract("{\"timestamp\":1710510181123,\"level\":\"info\"}");
    try std.testing.expect(ns != null);
    const millis = @divTrunc(ns.?, std.time.ns_per_ms);
    try std.testing.expectEqual(@as(i128, 1710510181123), millis);
}
