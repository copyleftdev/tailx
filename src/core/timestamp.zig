const std = @import("std");

pub const Timestamp = struct {
    /// Nanoseconds since Unix epoch (UTC).
    nanos: i128,

    /// Monotonic counter for total ordering when nanos collide.
    /// Assigned by the ingestion merge layer.
    seq: u64,

    pub fn order(a: Timestamp, b: Timestamp) std.math.Order {
        if (a.nanos < b.nanos) return .lt;
        if (a.nanos > b.nanos) return .gt;
        return std.math.order(a.seq, b.seq);
    }

    pub fn lessThan(_: void, a: Timestamp, b: Timestamp) bool {
        return a.order(b) == .lt;
    }

    pub fn now() Timestamp {
        return .{
            .nanos = std.time.nanoTimestamp(),
            .seq = 0,
        };
    }

    pub fn fromNanos(nanos: i128) Timestamp {
        return .{ .nanos = nanos, .seq = 0 };
    }

    pub fn elapsedNs(self: Timestamp, other: Timestamp) i128 {
        return self.nanos - other.nanos;
    }
};

test "timestamp ordering" {
    const a = Timestamp{ .nanos = 100, .seq = 0 };
    const b = Timestamp{ .nanos = 100, .seq = 1 };
    const c = Timestamp{ .nanos = 200, .seq = 0 };

    try std.testing.expectEqual(std.math.Order.lt, a.order(b));
    try std.testing.expectEqual(std.math.Order.lt, b.order(c));
    try std.testing.expectEqual(std.math.Order.gt, c.order(a));
    try std.testing.expectEqual(std.math.Order.eq, a.order(a));
}

test "timestamp lessThan for sorting" {
    var timestamps = [_]Timestamp{
        .{ .nanos = 300, .seq = 0 },
        .{ .nanos = 100, .seq = 1 },
        .{ .nanos = 100, .seq = 0 },
        .{ .nanos = 200, .seq = 0 },
    };
    std.mem.sort(Timestamp, &timestamps, {}, Timestamp.lessThan);
    try std.testing.expectEqual(@as(i128, 100), timestamps[0].nanos);
    try std.testing.expectEqual(@as(u64, 0), timestamps[0].seq);
    try std.testing.expectEqual(@as(i128, 100), timestamps[1].nanos);
    try std.testing.expectEqual(@as(u64, 1), timestamps[1].seq);
    try std.testing.expectEqual(@as(i128, 200), timestamps[2].nanos);
    try std.testing.expectEqual(@as(i128, 300), timestamps[3].nanos);
}
