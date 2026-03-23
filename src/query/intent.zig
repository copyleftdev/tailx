const std = @import("std");
const filter_mod = @import("filter.zig");
const core = @import("../core.zig");

const FilterPredicate = filter_mod.FilterPredicate;
const SubstringSearcher = filter_mod.SubstringSearcher;
const Severity = core.Severity;

/// Parse a natural-language intent query into filter predicates.
/// Examples:
///   "errors related to payments" → severity>=error AND message contains "payments"
///   "slow requests over 2s"      → message contains "slow" AND field latency>2000
///   "timeout"                    → message contains "timeout"
///   "5xx from nginx"             → message contains "5xx" AND service="nginx"
///   "why are payments failing"   → severity>=error AND message contains "payments"
pub const IntentParser = struct {
    /// Parse an intent query string into a FilterPredicate.
    pub fn parse(query: []const u8) FilterPredicate {
        var fp = FilterPredicate{};

        var iter = std.mem.tokenizeAny(u8, query, " \t");

        while (iter.next()) |token| {
            // Skip filler words.
            if (isFillerWord(token)) continue;

            // Severity keywords.
            if (isSeverityKeyword(token)) |sev| {
                _ = fp.addClause(.{ .kind = .{ .severity_gte = sev } });
                continue;
            }

            // "from <service>" pattern.
            if (std.ascii.eqlIgnoreCase(token, "from")) {
                if (iter.next()) |service_name| {
                    if (!isFillerWord(service_name)) {
                        _ = fp.addClause(.{ .kind = .{ .service_eq = FilterPredicate.FixedString.from(service_name) } });
                    }
                }
                continue;
            }

            // "service:<name>" pattern.
            if (std.mem.startsWith(u8, token, "service:")) {
                _ = fp.addClause(.{ .kind = .{ .service_eq = FilterPredicate.FixedString.from(token[8..]) } });
                continue;
            }

            // "over <N>s" / "above <N>ms" — numeric threshold (treat as message filter for now).
            if (std.ascii.eqlIgnoreCase(token, "over") or std.ascii.eqlIgnoreCase(token, "above")) {
                if (iter.next()) |_| {
                    // Could parse numeric threshold; for now skip.
                }
                continue;
            }

            // Everything else becomes a message substring filter.
            // Basic stemming: strip trailing 's' for plurals.
            const search_term = if (token.len > 3 and token[token.len - 1] == 's')
                token[0 .. token.len - 1]
            else
                token;
            _ = fp.addClause(.{ .kind = .{ .message_contains = SubstringSearcher.init(search_term) } });
        }

        // If no severity set but query contains error-ish words, add severity filter.
        if (!hasSeverityClause(&fp) and queryImpliesErrors(query)) {
            // Insert at beginning.
            _ = fp.addClause(.{ .kind = .{ .severity_gte = .err } });
        }

        // If query produced an AND of multiple message_contains, that's fine.
        // Each word must appear in the message.
        return fp;
    }

    fn isSeverityKeyword(word: []const u8) ?Severity {
        if (std.ascii.eqlIgnoreCase(word, "errors") or std.ascii.eqlIgnoreCase(word, "error")) return .err;
        if (std.ascii.eqlIgnoreCase(word, "warnings") or std.ascii.eqlIgnoreCase(word, "warning")) return .warn;
        if (std.ascii.eqlIgnoreCase(word, "fatal") or std.ascii.eqlIgnoreCase(word, "critical")) return .fatal;
        if (std.ascii.eqlIgnoreCase(word, "5xx")) return .err;
        if (std.ascii.eqlIgnoreCase(word, "4xx")) return .warn;
        return null;
    }

    fn isFillerWord(word: []const u8) bool {
        const fillers = [_][]const u8{
            "the", "a", "an", "is", "are", "was", "were", "in", "on", "at",
            "to", "for", "of", "with", "and", "or", "but", "not", "related",
            "about", "why", "what", "how", "when", "where", "show", "me",
            "find", "get", "all", "any", "some", "that", "this", "those",
            "requests", "logs", "events", "messages",
        };
        for (fillers) |f| {
            if (std.ascii.eqlIgnoreCase(word, f)) return true;
        }
        return false;
    }

    fn hasSeverityClause(fp: *const FilterPredicate) bool {
        for (fp.clauses[0..fp.clause_count]) |clause| {
            switch (clause.kind) {
                .severity_gte, .severity_eq => return true,
                else => {},
            }
        }
        return false;
    }

    fn queryImpliesErrors(query: []const u8) bool {
        // Check if the query semantically implies errors.
        const error_words = [_][]const u8{ "fail", "crash", "down", "broken", "bug" };
        const lower_buf_len = @min(query.len, 256);
        var lower_buf: [256]u8 = undefined;
        for (query[0..lower_buf_len], 0..) |c, i| {
            lower_buf[i] = std.ascii.toLower(c);
        }
        const lower = lower_buf[0..lower_buf_len];

        for (error_words) |word| {
            if (std.mem.indexOf(u8, lower, word) != null) return true;
        }
        return false;
    }
};

test "intent: errors related to payments" {
    const fp = IntentParser.parse("errors related to payments");
    const Event = core.Event;
    const Timestamp = core.Timestamp;

    // Should match: error severity + message contains "payments".
    var e1 = Event.shell("payment service timeout", 0, Timestamp{ .nanos = 0, .seq = 0 }, 0);
    e1.severity = .err;
    try std.testing.expect(fp.matches(&e1));

    // Should not match: info severity.
    var e2 = Event.shell("payment received", 0, Timestamp{ .nanos = 0, .seq = 0 }, 0);
    e2.severity = .info;
    try std.testing.expect(!fp.matches(&e2));
}

test "intent: simple keyword" {
    const fp = IntentParser.parse("timeout");
    const Event = core.Event;
    const Timestamp = core.Timestamp;

    var e1 = Event.shell("connection timeout after 30s", 0, Timestamp{ .nanos = 0, .seq = 0 }, 0);
    try std.testing.expect(fp.matches(&e1));

    var e2 = Event.shell("connection successful", 0, Timestamp{ .nanos = 0, .seq = 0 }, 0);
    try std.testing.expect(!fp.matches(&e2));
}

test "intent: from service" {
    const fp = IntentParser.parse("5xx from nginx");
    const Event = core.Event;
    const Timestamp = core.Timestamp;

    // Severity >= err + service = nginx.
    var e1 = Event.shell("502 bad gateway", 0, Timestamp{ .nanos = 0, .seq = 0 }, 0);
    e1.severity = .err;
    e1.service = "nginx";
    try std.testing.expect(fp.matches(&e1));

    // Wrong service.
    var e2 = Event.shell("502 bad gateway", 0, Timestamp{ .nanos = 0, .seq = 0 }, 0);
    e2.severity = .err;
    e2.service = "apache";
    try std.testing.expect(!fp.matches(&e2));
}

test "intent: why are payments failing" {
    const fp = IntentParser.parse("why are payments failing");
    const Event = core.Event;
    const Timestamp = core.Timestamp;

    // "failing" implies errors (via queryImpliesErrors), "payment" (stemmed) is a keyword.
    var e1 = Event.shell("payment service is failing badly", 0, Timestamp{ .nanos = 0, .seq = 0 }, 0);
    e1.severity = .err;
    try std.testing.expect(fp.matches(&e1));
}
