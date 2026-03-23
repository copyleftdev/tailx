const std = @import("std");

/// Exponentially Weighted Moving Average.
/// Tracks a smoothed rate or value that adapts to recent changes.
pub const EWMA = struct {
    value: f64 = 0,
    initialized: bool = false,
    alpha: f64,
    last_update_ns: i128 = 0,
    interval_ns: i128,

    /// Create with explicit alpha.
    pub fn init(alpha: f64, interval_ns: i128) EWMA {
        return .{
            .alpha = alpha,
            .interval_ns = interval_ns,
        };
    }

    /// Create from halflife: alpha = 1 - exp(-interval / halflife).
    pub fn initWithHalflife(halflife_ns: i128, interval_ns: i128) EWMA {
        const ratio = @as(f64, @floatFromInt(interval_ns)) /
            @as(f64, @floatFromInt(halflife_ns));
        const alpha = 1.0 - @exp(-ratio);
        return init(alpha, interval_ns);
    }

    pub fn update(self: *EWMA, sample: f64, now_ns: i128) void {
        if (!self.initialized) {
            self.value = sample;
            self.initialized = true;
            self.last_update_ns = now_ns;
            return;
        }

        const elapsed = now_ns - self.last_update_ns;
        if (elapsed <= 0) {
            // Same timestamp — just use instantaneous alpha.
            self.value = self.alpha * sample + (1.0 - self.alpha) * self.value;
            return;
        }

        // Time-weighted alpha for irregular update intervals.
        const periods = @as(f64, @floatFromInt(elapsed)) /
            @as(f64, @floatFromInt(self.interval_ns));
        const effective_alpha = 1.0 - std.math.pow(f64, 1.0 - self.alpha, periods);

        self.value = effective_alpha * sample + (1.0 - effective_alpha) * self.value;
        self.last_update_ns = now_ns;
    }

    pub fn current(self: EWMA) ?f64 {
        if (!self.initialized) return null;
        return self.value;
    }

    pub fn reset(self: *EWMA) void {
        self.initialized = false;
        self.value = 0;
        self.last_update_ns = 0;
    }
};

test "ewma constant value converges" {
    var ewma = EWMA.initWithHalflife(10 * std.time.ns_per_s, std.time.ns_per_s);

    // Feed constant value 50 for 100 updates.
    for (0..100) |i| {
        ewma.update(50.0, @intCast(i * std.time.ns_per_s));
    }

    const val = ewma.current().?;
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), val, 0.01);
}

test "ewma adapts to step change" {
    var ewma = EWMA.initWithHalflife(10 * std.time.ns_per_s, std.time.ns_per_s);

    // Baseline at 100.
    for (0..50) |i| {
        ewma.update(100.0, @intCast(i * std.time.ns_per_s));
    }
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), ewma.current().?, 0.1);

    // Step change to 200.
    for (50..100) |i| {
        ewma.update(200.0, @intCast(i * std.time.ns_per_s));
    }

    // After 50s with halflife=10s, should be very close to 200.
    const val = ewma.current().?;
    try std.testing.expect(val > 195.0);
}

test "ewma initial value" {
    var ewma = EWMA.init(0.1, std.time.ns_per_s);
    try std.testing.expectEqual(@as(?f64, null), ewma.current());
    ewma.update(42.0, 0);
    try std.testing.expectEqual(@as(f64, 42.0), ewma.current().?);
}
