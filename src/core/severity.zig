const std = @import("std");

pub const Severity = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    fatal = 5,
    unknown = 255,

    pub fn gte(self: Severity, other: Severity) bool {
        return self.numeric() >= other.numeric();
    }

    pub fn numeric(self: Severity) u8 {
        return switch (self) {
            .trace => 0,
            .debug => 1,
            .info => 2,
            .warn => 3,
            .err => 4,
            .fatal => 5,
            .unknown => 0,
        };
    }

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
            .unknown => "???",
        };
    }

    /// Parse a severity string (case-insensitive). Uses first char + length
    /// for fast dispatch.
    pub fn parse(s: []const u8) Severity {
        if (s.len == 0) return .unknown;
        const lower = std.ascii.toLower(s[0]);
        return switch (lower) {
            't' => if (startsWithCI(s, "trace")) .trace else .unknown,
            'd' => if (startsWithCI(s, "debug") or eqlCI(s, "dbg")) .debug else .unknown,
            'i' => if (startsWithCI(s, "info") or eqlCI(s, "inf")) .info else
                if (s.len == 1) .info else .unknown,
            'w' => if (startsWithCI(s, "warn")) .warn else
                if (eqlCI(s, "wrn")) .warn else
                if (s.len == 1) .warn else .unknown,
            'e' => if (startsWithCI(s, "error") or eqlCI(s, "err")) .err else
                if (s.len == 1) .err else .unknown,
            'f' => if (startsWithCI(s, "fatal") or eqlCI(s, "ftl")) .fatal else .unknown,
            'c' => if (startsWithCI(s, "crit")) .fatal else .unknown,
            else => .unknown,
        };
    }

    fn eqlCI(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ac, bc| {
            if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
        }
        return true;
    }

    fn startsWithCI(haystack: []const u8, prefix: []const u8) bool {
        if (haystack.len < prefix.len) return false;
        for (haystack[0..prefix.len], prefix) |h, p| {
            if (std.ascii.toLower(h) != std.ascii.toLower(p)) return false;
        }
        return true;
    }
};

test "severity ordering" {
    try std.testing.expect(Severity.err.gte(.warn));
    try std.testing.expect(Severity.err.gte(.err));
    try std.testing.expect(!Severity.warn.gte(.err));
    try std.testing.expect(Severity.fatal.gte(.trace));
}

test "severity parsing" {
    try std.testing.expectEqual(Severity.err, Severity.parse("ERROR"));
    try std.testing.expectEqual(Severity.err, Severity.parse("error"));
    try std.testing.expectEqual(Severity.err, Severity.parse("ERR"));
    try std.testing.expectEqual(Severity.err, Severity.parse("E"));
    try std.testing.expectEqual(Severity.warn, Severity.parse("WARNING"));
    try std.testing.expectEqual(Severity.warn, Severity.parse("WARN"));
    try std.testing.expectEqual(Severity.warn, Severity.parse("WRN"));
    try std.testing.expectEqual(Severity.info, Severity.parse("INFO"));
    try std.testing.expectEqual(Severity.info, Severity.parse("INF"));
    try std.testing.expectEqual(Severity.debug, Severity.parse("DEBUG"));
    try std.testing.expectEqual(Severity.fatal, Severity.parse("FATAL"));
    try std.testing.expectEqual(Severity.fatal, Severity.parse("CRITICAL"));
    try std.testing.expectEqual(Severity.unknown, Severity.parse(""));
    try std.testing.expectEqual(Severity.unknown, Severity.parse("xyz"));
}
