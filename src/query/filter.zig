const std = @import("std");
const core = @import("../core.zig");

const Event = core.Event;
const Severity = core.Severity;
const FieldValue = core.field.FieldValue;

/// A compiled filter predicate. Evaluated per-event in the hot path.
/// Target: ≤ 100ns per event with up to 3 predicates.
pub const FilterPredicate = struct {
    clauses: [max_clauses]Clause = undefined,
    clause_count: u8 = 0,
    combinator: Combinator = .@"and",

    const max_clauses = 32;

    pub const Combinator = enum { @"and", @"or" };

    pub const Clause = struct {
        kind: ClauseKind,
        negated: bool = false,
    };

    pub const ClauseKind = union(enum) {
        severity_gte: Severity,
        severity_eq: Severity,
        service_eq: FixedString,
        trace_id_eq: FixedString,
        message_contains: SubstringSearcher,
        field_eq: FieldEq,
        field_gt: FieldCmp,
        field_lt: FieldCmp,
        template_hash_eq: u64,
    };

    pub const FixedString = struct {
        buf: [64]u8 = undefined,
        len: u8 = 0,

        pub fn from(s: []const u8) FixedString {
            var fs = FixedString{};
            const copy_len = @min(s.len, 64);
            @memcpy(fs.buf[0..copy_len], s[0..copy_len]);
            fs.len = @intCast(copy_len);
            return fs;
        }

        pub fn slice(self: *const FixedString) []const u8 {
            return self.buf[0..self.len];
        }
    };

    pub const FieldEq = struct {
        key: FixedString,
        value: FixedString,
    };

    pub const FieldCmp = struct {
        key: FixedString,
        threshold: f64,
    };

    /// Add a clause to this predicate.
    pub fn addClause(self: *FilterPredicate, clause: Clause) bool {
        if (self.clause_count >= max_clauses) return false;
        self.clauses[self.clause_count] = clause;
        self.clause_count += 1;
        return true;
    }

    /// Evaluate this predicate against an event.
    pub fn matches(self: *const FilterPredicate, event: *const Event) bool {
        if (self.clause_count == 0) return true;

        for (self.clauses[0..self.clause_count]) |clause| {
            const result = evaluateClause(&clause, event);
            const effective = if (clause.negated) !result else result;

            switch (self.combinator) {
                .@"and" => {
                    if (!effective) return false;
                },
                .@"or" => {
                    if (effective) return true;
                },
            }
        }

        return switch (self.combinator) {
            .@"and" => true,
            .@"or" => false,
        };
    }

    fn evaluateClause(clause: *const Clause, event: *const Event) bool {
        return switch (clause.kind) {
            .severity_gte => |min_sev| event.severity.numeric() >= min_sev.numeric(),
            .severity_eq => |sev| event.severity == sev,
            .service_eq => |fs| {
                if (event.service) |svc| {
                    return std.mem.eql(u8, svc, fs.slice());
                }
                return false;
            },
            .trace_id_eq => |fs| {
                if (event.trace_id) |tid| {
                    return std.mem.eql(u8, tid, fs.slice());
                }
                return false;
            },
            .message_contains => |searcher| searcher.search(event.message),
            .field_eq => |feq| {
                if (event.fields.getString(feq.key.slice())) |val| {
                    return std.mem.eql(u8, val, feq.value.slice());
                }
                // Try numeric comparison for integer fields.
                if (event.fields.get(feq.key.slice())) |val| {
                    switch (val) {
                        .int => |v| {
                            const expected = std.fmt.parseInt(i64, feq.value.slice(), 10) catch return false;
                            return v == expected;
                        },
                        else => return false,
                    }
                }
                return false;
            },
            .field_gt => |fcmp| {
                const val = event.fields.getFloat(fcmp.key.slice()) orelse return false;
                return val > fcmp.threshold;
            },
            .field_lt => |fcmp| {
                const val = event.fields.getFloat(fcmp.key.slice()) orelse return false;
                return val < fcmp.threshold;
            },
            .template_hash_eq => |hash| event.template_hash == hash,
        };
    }
};

/// Boyer-Moore-Horspool substring searcher for fast message matching.
pub const SubstringSearcher = struct {
    needle: [256]u8 = undefined,
    needle_len: u16 = 0,
    bad_char_table: [256]u16 = [_]u16{0} ** 256,

    pub fn init(needle: []const u8) SubstringSearcher {
        var s = SubstringSearcher{};
        const copy_len = @min(needle.len, 256);
        @memcpy(s.needle[0..copy_len], needle[0..copy_len]);
        s.needle_len = @intCast(copy_len);

        // Build bad character table.
        @memset(&s.bad_char_table, s.needle_len);
        if (copy_len > 0) {
            for (0..copy_len - 1) |i| {
                s.bad_char_table[needle[i]] = @intCast(copy_len - 1 - i);
            }
        }
        return s;
    }

    /// Search for needle in haystack using Boyer-Moore-Horspool.
    pub fn search(self: *const SubstringSearcher, haystack: []const u8) bool {
        if (self.needle_len == 0) return true;
        if (haystack.len < self.needle_len) return false;

        const n = self.needle_len;
        const needle = self.needle[0..n];
        var pos: usize = 0;

        while (pos + n <= haystack.len) {
            // Compare from right to left.
            var j: usize = n;
            while (j > 0) {
                j -= 1;
                if (haystack[pos + j] != needle[j]) break;
                if (j == 0) return true;
            }
            // Shift by bad character table.
            pos += self.bad_char_table[haystack[pos + n - 1]];
        }

        return false;
    }
};

// --- Builder helpers ---

/// Build a severity >= filter.
pub fn severityFilter(min: Severity) FilterPredicate {
    var fp = FilterPredicate{};
    _ = fp.addClause(.{ .kind = .{ .severity_gte = min } });
    return fp;
}

/// Build a message substring filter.
pub fn messageFilter(needle: []const u8) FilterPredicate {
    var fp = FilterPredicate{};
    _ = fp.addClause(.{ .kind = .{ .message_contains = SubstringSearcher.init(needle) } });
    return fp;
}

/// Build a service name filter.
pub fn serviceFilter(name: []const u8) FilterPredicate {
    var fp = FilterPredicate{};
    _ = fp.addClause(.{ .kind = .{ .service_eq = FilterPredicate.FixedString.from(name) } });
    return fp;
}

/// Build a field=value filter.
pub fn fieldEqFilter(key: []const u8, value: []const u8) FilterPredicate {
    var fp = FilterPredicate{};
    _ = fp.addClause(.{ .kind = .{ .field_eq = .{
        .key = FilterPredicate.FixedString.from(key),
        .value = FilterPredicate.FixedString.from(value),
    } } });
    return fp;
}

test "filter severity gte" {
    const fp = severityFilter(.warn);

    var info_event = Event.shell("info msg", 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    info_event.severity = .info;
    try std.testing.expect(!fp.matches(&info_event));

    var warn_event = Event.shell("warn msg", 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    warn_event.severity = .warn;
    try std.testing.expect(fp.matches(&warn_event));

    var err_event = Event.shell("err msg", 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    err_event.severity = .err;
    try std.testing.expect(fp.matches(&err_event));
}

test "filter message contains" {
    const fp = messageFilter("timeout");

    var match = Event.shell("connection timeout after 30s", 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    try std.testing.expect(fp.matches(&match));

    var no_match = Event.shell("connection successful", 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    try std.testing.expect(!fp.matches(&no_match));
}

test "filter service eq" {
    const allocator = std.testing.allocator;
    var arena = core.EventArena.init(allocator, 0, 0);
    defer arena.deinit();

    const fp = serviceFilter("payments");

    var event = Event.shell("test", 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    event.service = "payments";
    try std.testing.expect(fp.matches(&event));

    var other = Event.shell("test", 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    other.service = "auth";
    try std.testing.expect(!fp.matches(&other));

    var none = Event.shell("test", 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    try std.testing.expect(!fp.matches(&none));
}

test "filter combined AND" {
    var fp = FilterPredicate{};
    _ = fp.addClause(.{ .kind = .{ .severity_gte = .err } });
    _ = fp.addClause(.{ .kind = .{ .message_contains = SubstringSearcher.init("timeout") } });

    // Both match → true.
    var both = Event.shell("timeout error", 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    both.severity = .err;
    try std.testing.expect(fp.matches(&both));

    // Severity matches, message doesn't → false.
    var sev_only = Event.shell("connection ok", 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    sev_only.severity = .err;
    try std.testing.expect(!fp.matches(&sev_only));
}

test "filter combined OR" {
    var fp = FilterPredicate{ .combinator = .@"or" };
    _ = fp.addClause(.{ .kind = .{ .severity_gte = .fatal } });
    _ = fp.addClause(.{ .kind = .{ .message_contains = SubstringSearcher.init("timeout") } });

    // Message matches → true.
    var msg = Event.shell("timeout occurred", 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    msg.severity = .info;
    try std.testing.expect(fp.matches(&msg));

    // Neither → false.
    var neither = Event.shell("all good", 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    neither.severity = .info;
    try std.testing.expect(!fp.matches(&neither));
}

test "filter negated clause" {
    var fp = FilterPredicate{};
    _ = fp.addClause(.{ .kind = .{ .severity_eq = .debug }, .negated = true });

    var debug = Event.shell("debug msg", 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    debug.severity = .debug;
    try std.testing.expect(!fp.matches(&debug)); // excluded

    var info = Event.shell("info msg", 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    info.severity = .info;
    try std.testing.expect(fp.matches(&info)); // included
}

test "substring searcher" {
    const s = SubstringSearcher.init("timeout");
    try std.testing.expect(s.search("connection timeout after 30s"));
    try std.testing.expect(s.search("timeout"));
    try std.testing.expect(!s.search("connection ok"));
    try std.testing.expect(!s.search("time"));
    try std.testing.expect(SubstringSearcher.init("").search("anything"));
}

test "filter empty predicate matches all" {
    const fp = FilterPredicate{};
    var event = Event.shell("test", 0, core.Timestamp{ .nanos = 0, .seq = 0 }, 0);
    try std.testing.expect(fp.matches(&event));
}
