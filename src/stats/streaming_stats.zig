const std = @import("std");

/// Welford's online algorithm for running mean, variance, and z-scores.
pub const StreamingStats = struct {
    count: u64 = 0,
    mean: f64 = 0,
    m2: f64 = 0,
    min: f64 = std.math.floatMax(f64),
    max: f64 = -std.math.floatMax(f64),

    pub fn update(self: *StreamingStats, value: f64) void {
        self.count += 1;
        const delta = value - self.mean;
        self.mean += delta / @as(f64, @floatFromInt(self.count));
        const delta2 = value - self.mean;
        self.m2 += delta * delta2;
        self.min = @min(self.min, value);
        self.max = @max(self.max, value);
    }

    pub fn variance(self: StreamingStats) ?f64 {
        if (self.count < 2) return null;
        return self.m2 / @as(f64, @floatFromInt(self.count - 1));
    }

    pub fn stddev(self: StreamingStats) ?f64 {
        const v = self.variance() orelse return null;
        return @sqrt(v);
    }

    pub fn zscore(self: StreamingStats, value: f64) ?f64 {
        const sd = self.stddev() orelse return null;
        if (sd == 0) return null;
        return (value - self.mean) / sd;
    }

    pub fn reset(self: *StreamingStats) void {
        self.* = .{};
    }
};

test "streaming stats basic" {
    var stats = StreamingStats{};

    // Dataset: [2, 4, 4, 4, 5, 5, 7, 9]
    const data = [_]f64{ 2, 4, 4, 4, 5, 5, 7, 9 };
    for (data) |v| stats.update(v);

    try std.testing.expectEqual(@as(u64, 8), stats.count);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), stats.mean, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), stats.min, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), stats.max, 0.001);

    // Variance = 4.571..., stddev ≈ 2.138
    const sd = stats.stddev().?;
    try std.testing.expectApproxEqAbs(@as(f64, 2.138), sd, 0.01);

    // z-score of 9: (9-5)/2.138 ≈ 1.87
    const z = stats.zscore(9.0).?;
    try std.testing.expectApproxEqAbs(@as(f64, 1.87), z, 0.05);
}

test "streaming stats empty" {
    const stats = StreamingStats{};
    try std.testing.expectEqual(@as(?f64, null), stats.variance());
    try std.testing.expectEqual(@as(?f64, null), stats.stddev());
    try std.testing.expectEqual(@as(?f64, null), stats.zscore(5.0));
}

test "streaming stats single value" {
    var stats = StreamingStats{};
    stats.update(42.0);
    try std.testing.expectEqual(@as(?f64, null), stats.variance()); // need >= 2
}

test "streaming stats constant value" {
    var stats = StreamingStats{};
    for (0..100) |_| stats.update(7.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), stats.stddev().?, 0.0001);
    try std.testing.expectEqual(@as(?f64, null), stats.zscore(8.0)); // stddev=0 → null
}
