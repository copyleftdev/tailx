const std = @import("std");

/// Detected log format for a source.
pub const Format = enum(u8) {
    json,
    json_lines,
    syslog_bsd,
    syslog_ietf,
    clf,
    kv_pairs,
    logfmt,
    unstructured,
};

/// Auto-detect log format from the first N lines of a source.
/// Votes on format using simple heuristics, locks after 8 samples.
pub const FormatDetector = struct {
    votes: [format_count]u8 = [_]u8{0} ** format_count,
    samples_seen: u8 = 0,
    locked: ?Format = null,

    const sample_target = 8;
    const format_count = std.meta.fields(Format).len;

    /// Feed a line for format detection.
    pub fn feed(self: *FormatDetector, line: []const u8) void {
        if (self.locked != null) return;
        if (line.len == 0) return;

        self.samples_seen += 1;

        // Check JSON: starts with { and ends with }
        if (isJson(line)) {
            self.votes[@intFromEnum(Format.json)] += 1;
            self.votes[@intFromEnum(Format.json_lines)] += 1;
        }
        // Check syslog: starts with <digits>
        else if (isSyslog(line)) {
            if (isSyslogIetf(line)) {
                self.votes[@intFromEnum(Format.syslog_ietf)] += 1;
            } else {
                self.votes[@intFromEnum(Format.syslog_bsd)] += 1;
            }
        }
        // Check CLF: IP - - [date] "METHOD
        else if (isClf(line)) {
            self.votes[@intFromEnum(Format.clf)] += 1;
        }
        // Check key=value / logfmt
        else if (isKvPairs(line)) {
            // Distinguish logfmt (has level= and msg=) from generic kv
            if (isLogfmt(line)) {
                self.votes[@intFromEnum(Format.logfmt)] += 1;
            } else {
                self.votes[@intFromEnum(Format.kv_pairs)] += 1;
            }
        } else {
            self.votes[@intFromEnum(Format.unstructured)] += 1;
        }

        if (self.samples_seen >= sample_target) {
            self.locked = self.result();
        }
    }

    /// Return the detected format. Best guess if not yet locked.
    pub fn result(self: *const FormatDetector) Format {
        if (self.locked) |fmt| return fmt;

        var best: Format = .unstructured;
        var best_votes: u8 = 0;

        inline for (std.meta.fields(Format)) |f| {
            const idx = f.value;
            const v = self.votes[idx];
            if (v > best_votes) {
                best_votes = v;
                best = @enumFromInt(idx);
            } else if (v == best_votes and v > 0) {
                // Prefer more structured format on tie.
                const candidate: Format = @enumFromInt(idx);
                if (structuredness(candidate) > structuredness(best)) {
                    best = candidate;
                }
            }
        }

        return best;
    }

    fn structuredness(fmt: Format) u8 {
        return switch (fmt) {
            .json, .json_lines => 6,
            .logfmt => 5,
            .kv_pairs => 4,
            .syslog_ietf => 3,
            .syslog_bsd => 3,
            .clf => 3,
            .unstructured => 0,
        };
    }

    fn isJson(line: []const u8) bool {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len < 2) return false;
        return trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}';
    }

    fn isSyslog(line: []const u8) bool {
        if (line.len < 4) return false;
        if (line[0] != '<') return false;
        // Check for <digits>
        var i: usize = 1;
        while (i < line.len and i < 5 and line[i] >= '0' and line[i] <= '9') i += 1;
        return i > 1 and i < line.len and line[i] == '>';
    }

    fn isSyslogIetf(line: []const u8) bool {
        // RFC 5424: <PRI>VERSION — version digit after >
        if (!isSyslog(line)) return false;
        // Find >
        var i: usize = 1;
        while (i < line.len and line[i] != '>') i += 1;
        if (i + 1 >= line.len) return false;
        return line[i + 1] >= '1' and line[i + 1] <= '9';
    }

    fn isClf(line: []const u8) bool {
        // Look for: IP followed by ' - ' and then '[' somewhere in first 80 bytes.
        if (line.len < 20) return false;
        // First token should look like an IP or hostname.
        var i: usize = 0;
        while (i < line.len and line[i] != ' ') i += 1;
        if (i == 0 or i >= line.len) return false;
        // Look for ' - ' pattern.
        const search_end = @min(line.len, 80);
        return std.mem.indexOf(u8, line[0..search_end], " - ") != null and
            std.mem.indexOf(u8, line[0..search_end], "[") != null and
            std.mem.indexOf(u8, line[0..search_end], "\"") != null;
    }

    fn isKvPairs(line: []const u8) bool {
        // Count key=value occurrences. Need 3+ to qualify.
        var count: u8 = 0;
        var i: usize = 0;
        while (i < line.len) {
            // Find '='
            if (line[i] == '=' and i > 0 and line[i - 1] != ' ' and line[i - 1] != '=') {
                count += 1;
                if (count >= 3) return true;
            }
            i += 1;
        }
        return false;
    }

    fn isLogfmt(line: []const u8) bool {
        // Logfmt specifically has level= and msg= or message=.
        const has_level = std.mem.indexOf(u8, line, "level=") != null or
            std.mem.indexOf(u8, line, "lvl=") != null;
        const has_msg = std.mem.indexOf(u8, line, "msg=") != null or
            std.mem.indexOf(u8, line, "message=") != null;
        return has_level and has_msg;
    }
};

test "format detector json" {
    var d = FormatDetector{};
    for (0..8) |_| {
        d.feed("{\"level\":\"info\",\"msg\":\"test\",\"ts\":123}");
    }
    try std.testing.expectEqual(Format.json, d.result());
    try std.testing.expect(d.locked != null);
}

test "format detector syslog bsd" {
    var d = FormatDetector{};
    for (0..8) |_| {
        d.feed("<134>Mar 15 14:23:01 web01 nginx[1234]: GET /api 200 0.012");
    }
    try std.testing.expectEqual(Format.syslog_bsd, d.result());
}

test "format detector logfmt" {
    var d = FormatDetector{};
    for (0..8) |_| {
        d.feed("ts=2024-03-15T14:23:01Z level=warn msg=\"disk usage high\" host=db01 usage=0.92");
    }
    try std.testing.expectEqual(Format.logfmt, d.result());
}

test "format detector clf" {
    var d = FormatDetector{};
    for (0..8) |_| {
        d.feed("10.0.0.1 - frank [10/Oct/2000:13:55:36 -0700] \"GET /apache_pb.gif HTTP/1.1\" 200 2326");
    }
    try std.testing.expectEqual(Format.clf, d.result());
}

test "format detector unstructured" {
    var d = FormatDetector{};
    for (0..8) |_| {
        d.feed("2024-03-15 14:23:01 ERROR [PaymentService] Connection refused");
    }
    try std.testing.expectEqual(Format.unstructured, d.result());
}

test "format detector mixed prefers structured" {
    var d = FormatDetector{};
    // 4 JSON, 4 unstructured → JSON wins (more structured).
    for (0..4) |_| d.feed("{\"msg\":\"test\"}");
    for (0..4) |_| d.feed("plain text log line");
    const fmt = d.result();
    try std.testing.expect(fmt == .json or fmt == .json_lines);
}
