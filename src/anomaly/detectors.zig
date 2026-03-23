const std = @import("std");
const stats = @import("../stats.zig");

const EWMA = stats.EWMA;
const StreamingStats = stats.StreamingStats;

/// Result from an anomaly detector.
pub const DetectorResult = struct {
    fired: bool,
    score: f64,
    method: DetectorKind,
    observed: f64,
    expected: f64,
    deviation: f64,
};

/// Type of anomaly detected.
pub const DetectorKind = enum {
    rate_spike,
    rate_drop,
    latency_spike,
    distribution_shift,
    change_point_up,
    change_point_down,
    cardinality_spike,
    new_pattern_burst,
};

/// Map z-score to 0.0–1.0 severity score.
pub fn normalizeZScore(z: f64) f64 {
    return 1.0 - 1.0 / (1.0 + 0.1 * z * z);
}

/// Rate detector using dual EWMA + z-score.
/// Fast EWMA (10s halflife) tracks current rate.
/// Slow EWMA (5min halflife) tracks baseline.
pub const RateDetector = struct {
    baseline: EWMA,
    current: EWMA,
    detector_stats: StreamingStats,
    warmup_samples: u32,
    samples_seen: u32,
    zscore_threshold: f64,
    min_absolute_delta: f64,

    pub fn init() RateDetector {
        return .{
            .baseline = EWMA.initWithHalflife(300 * std.time.ns_per_s, std.time.ns_per_s), // 5min
            .current = EWMA.initWithHalflife(10 * std.time.ns_per_s, std.time.ns_per_s), // 10s
            .detector_stats = StreamingStats{},
            .warmup_samples = 30,
            .samples_seen = 0,
            .zscore_threshold = 3.0,
            .min_absolute_delta = 1.0,
        };
    }

    pub fn initWithThresholds(zscore_threshold: f64, min_absolute_delta: f64, warmup: u32) RateDetector {
        var rd = init();
        rd.zscore_threshold = zscore_threshold;
        rd.min_absolute_delta = min_absolute_delta;
        rd.warmup_samples = warmup;
        return rd;
    }

    /// Feed a sample (typically rate in events/sec) and check for anomaly.
    pub fn tick(self: *RateDetector, sample: f64, now_ns: i128) ?DetectorResult {
        self.samples_seen += 1;
        self.current.update(sample, now_ns);

        // Compute z-score of raw sample against historical stats BEFORE updating.
        const z = self.detector_stats.zscore(sample);
        self.detector_stats.update(sample);
        self.baseline.update(sample, now_ns);

        if (self.samples_seen < self.warmup_samples) return null;

        const current_val = self.current.current() orelse return null;
        const baseline_val = self.baseline.current() orelse return null;
        const z_val = z orelse return null;

        const delta = current_val - baseline_val;
        if (@abs(delta) < self.min_absolute_delta) return null;

        if (z_val >= self.zscore_threshold) {
            return .{
                .fired = true,
                .score = normalizeZScore(z_val),
                .method = .rate_spike,
                .observed = sample,
                .expected = baseline_val,
                .deviation = z_val,
            };
        }

        if (z_val <= -self.zscore_threshold and baseline_val > self.min_absolute_delta) {
            return .{
                .fired = true,
                .score = normalizeZScore(@abs(z_val)),
                .method = .rate_drop,
                .observed = sample,
                .expected = baseline_val,
                .deviation = z_val,
            };
        }

        return null;
    }

    pub fn reset(self: *RateDetector) void {
        self.baseline.reset();
        self.current.reset();
        self.detector_stats = StreamingStats{};
        self.samples_seen = 0;
    }
};

/// CUSUM (Cumulative Sum) change-point detector.
/// Catches sustained shifts that individual z-scores might miss.
pub const CusumDetector = struct {
    s_high: f64,
    s_low: f64,
    target: EWMA,
    cusum_stats: StreamingStats,
    threshold: f64,
    allowance: f64,
    cooldown_remaining: u16,
    cooldown_ticks: u16,
    warmup_samples: u32,
    samples_seen: u32,

    pub fn init() CusumDetector {
        return .{
            .s_high = 0,
            .s_low = 0,
            .target = EWMA.initWithHalflife(300 * std.time.ns_per_s, std.time.ns_per_s),
            .cusum_stats = StreamingStats{},
            .threshold = 5.0,
            .allowance = 0.5,
            .cooldown_remaining = 0,
            .cooldown_ticks = 30,
            .warmup_samples = 30,
            .samples_seen = 0,
        };
    }

    pub fn initWithParams(threshold: f64, allowance: f64, warmup: u32) CusumDetector {
        var cd = init();
        cd.threshold = threshold;
        cd.allowance = allowance;
        cd.warmup_samples = warmup;
        return cd;
    }

    /// Feed a sample and check for sustained shift.
    pub fn tick(self: *CusumDetector, sample: f64, now_ns: i128) ?DetectorResult {
        self.samples_seen += 1;
        self.cusum_stats.update(sample);
        self.target.update(sample, now_ns);

        if (self.samples_seen < self.warmup_samples) return null;
        if (self.cooldown_remaining > 0) {
            self.cooldown_remaining -= 1;
            return null;
        }

        const mean = self.target.current() orelse return null;
        const sd = self.cusum_stats.stddev() orelse return null;
        if (sd == 0) return null;

        const normalized = (sample - mean) / sd;

        self.s_high = @max(0, self.s_high + normalized - self.allowance);
        self.s_low = @max(0, self.s_low - normalized - self.allowance);

        if (self.s_high > self.threshold) {
            const result = DetectorResult{
                .fired = true,
                .score = @min(1.0, self.s_high / (self.threshold * 2.0)),
                .method = .change_point_up,
                .observed = sample,
                .expected = mean,
                .deviation = normalized,
            };
            self.s_high = 0;
            self.cooldown_remaining = self.cooldown_ticks;
            return result;
        }

        if (self.s_low > self.threshold) {
            const result = DetectorResult{
                .fired = true,
                .score = @min(1.0, self.s_low / (self.threshold * 2.0)),
                .method = .change_point_down,
                .observed = sample,
                .expected = mean,
                .deviation = -normalized,
            };
            self.s_low = 0;
            self.cooldown_remaining = self.cooldown_ticks;
            return result;
        }

        return null;
    }

    pub fn reset(self: *CusumDetector) void {
        self.s_high = 0;
        self.s_low = 0;
        self.target.reset();
        self.cusum_stats = StreamingStats{};
        self.samples_seen = 0;
        self.cooldown_remaining = 0;
    }
};

/// State of an anomaly alert.
pub const AlertState = enum {
    active,
    resolved,
    suppressed,
};

/// A raised anomaly alert.
pub const AnomalyAlert = struct {
    id: u32,
    kind: DetectorKind,
    score: f64,
    observed: f64,
    expected: f64,
    deviation: f64,
    first_fired_ns: i128,
    last_fired_ns: i128,
    fire_count: u32,
    state: AlertState,
};

/// Deduplicates and manages anomaly alerts.
pub const SignalAggregator = struct {
    alerts: [max_alerts]?AnomalyAlert = [_]?AnomalyAlert{null} ** max_alerts,
    alert_count: u32 = 0,
    next_id: u32 = 1,

    const max_alerts = 128;

    /// Process detector results, creating or updating alerts.
    pub fn process(self: *SignalAggregator, results: []const DetectorResult, now_ns: i128) void {
        for (results) |result| {
            if (!result.fired) continue;

            // Dedup: find existing alert with same method.
            if (self.findExisting(result.method)) |existing| {
                existing.last_fired_ns = now_ns;
                existing.fire_count += 1;
                existing.score = @max(existing.score, result.score);
                existing.observed = result.observed;
                existing.state = .active;
                continue;
            }

            // Create new alert.
            self.createAlert(result, now_ns);
        }

        // Resolve alerts that haven't fired in 30 seconds.
        for (&self.alerts) |*slot| {
            if (slot.*) |*alert| {
                if (alert.state == .active and
                    now_ns - alert.last_fired_ns > 30 * std.time.ns_per_s)
                {
                    alert.state = .resolved;
                }
            }
        }

        // Evict resolved alerts older than 5 minutes.
        for (&self.alerts) |*slot| {
            if (slot.*) |*alert| {
                if (alert.state == .resolved and
                    now_ns - alert.last_fired_ns > 300 * std.time.ns_per_s)
                {
                    slot.* = null;
                    self.alert_count -= 1;
                }
            }
        }
    }

    /// Count of currently active alerts.
    pub fn activeCount(self: *const SignalAggregator) u32 {
        var count: u32 = 0;
        for (self.alerts) |slot| {
            if (slot) |alert| {
                if (alert.state == .active) count += 1;
            }
        }
        return count;
    }

    fn findExisting(self: *SignalAggregator, method: DetectorKind) ?*AnomalyAlert {
        for (&self.alerts) |*slot| {
            if (slot.*) |*alert| {
                if (alert.kind == method and alert.state == .active) return alert;
            }
        }
        return null;
    }

    fn createAlert(self: *SignalAggregator, result: DetectorResult, now_ns: i128) void {
        // Find empty slot.
        for (&self.alerts) |*slot| {
            if (slot.* == null) {
                slot.* = .{
                    .id = self.next_id,
                    .kind = result.method,
                    .score = result.score,
                    .observed = result.observed,
                    .expected = result.expected,
                    .deviation = result.deviation,
                    .first_fired_ns = now_ns,
                    .last_fired_ns = now_ns,
                    .fire_count = 1,
                    .state = .active,
                };
                self.next_id += 1;
                self.alert_count += 1;
                return;
            }
        }
    }
};

test "rate detector no cold start false positive" {
    var rd = RateDetector.initWithThresholds(3.0, 1.0, 30);
    const ns = std.time.ns_per_s;

    // Constant 100 events/s for 120 ticks — should never fire.
    for (0..120) |i| {
        const result = rd.tick(100.0, @intCast(i * ns));
        if (result) |r| {
            // Should not happen.
            _ = r;
            try std.testing.expect(false);
        }
    }
}

test "rate detector spike detection" {
    var rd = RateDetector.initWithThresholds(3.0, 1.0, 20);
    const ns = std.time.ns_per_s;

    // Baseline with slight noise to build up stddev.
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    for (0..60) |i| {
        const noise = 95.0 + random.float(f64) * 10.0; // 95–105
        _ = rd.tick(noise, @intCast(i * ns));
    }

    // Spike to 500 — well beyond 3σ of the ~100 baseline.
    var fired = false;
    for (60..80) |i| {
        if (rd.tick(500.0, @intCast(i * ns))) |result| {
            try std.testing.expectEqual(DetectorKind.rate_spike, result.method);
            try std.testing.expect(result.score > 0);
            fired = true;
        }
    }
    try std.testing.expect(fired);
}

test "rate detector drop detection" {
    var rd = RateDetector.initWithThresholds(3.0, 1.0, 20);
    const ns = std.time.ns_per_s;

    // Baseline with slight noise.
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    for (0..60) |i| {
        const noise = 95.0 + random.float(f64) * 10.0;
        _ = rd.tick(noise, @intCast(i * ns));
    }

    // Drop to 5.
    var fired = false;
    for (60..80) |i| {
        if (rd.tick(5.0, @intCast(i * ns))) |result| {
            try std.testing.expectEqual(DetectorKind.rate_drop, result.method);
            fired = true;
        }
    }
    try std.testing.expect(fired);
}

test "cusum detects sustained shift" {
    var cd = CusumDetector.initWithParams(4.0, 0.5, 20);
    const ns = std.time.ns_per_s;

    // Baseline at 100.
    for (0..50) |i| {
        _ = cd.tick(100.0, @intCast(i * ns));
    }

    // Gradual shift upward: each tick adds +2 on top of baseline.
    var fired = false;
    for (50..100) |i| {
        const sample = 100.0 + @as(f64, @floatFromInt(i - 50)) * 2.0;
        if (cd.tick(sample, @intCast(i * ns))) |result| {
            try std.testing.expectEqual(DetectorKind.change_point_up, result.method);
            fired = true;
            break;
        }
    }
    try std.testing.expect(fired);
}

test "cusum cooldown prevents re-fire" {
    var cd = CusumDetector.initWithParams(4.0, 0.5, 10);
    cd.cooldown_ticks = 10;
    const ns = std.time.ns_per_s;

    // Quick warmup.
    for (0..15) |i| {
        _ = cd.tick(100.0, @intCast(i * ns));
    }

    // Force a fire.
    var fire_count: u32 = 0;
    for (15..50) |i| {
        if (cd.tick(200.0, @intCast(i * ns))) |_| {
            fire_count += 1;
        }
    }
    // Should fire at most a few times (with cooldown between).
    try std.testing.expect(fire_count <= 4);
}

test "signal aggregator dedup" {
    var agg = SignalAggregator{};
    const ns = std.time.ns_per_s;

    var results = [_]DetectorResult{
        .{ .fired = true, .score = 0.5, .method = .rate_spike, .observed = 200, .expected = 100, .deviation = 3.0 },
    };

    // First process: creates alert.
    agg.process(&results, 1 * ns);
    try std.testing.expectEqual(@as(u32, 1), agg.alert_count);
    try std.testing.expectEqual(@as(u32, 1), agg.activeCount());

    // Second process with same method: updates, doesn't create new.
    agg.process(&results, 2 * ns);
    try std.testing.expectEqual(@as(u32, 1), agg.alert_count);

    // Check fire count incremented.
    for (agg.alerts) |slot| {
        if (slot) |alert| {
            if (alert.kind == .rate_spike) {
                try std.testing.expectEqual(@as(u32, 2), alert.fire_count);
            }
        }
    }
}

test "signal aggregator resolution" {
    var agg = SignalAggregator{};
    const ns = std.time.ns_per_s;

    var results = [_]DetectorResult{
        .{ .fired = true, .score = 0.5, .method = .rate_spike, .observed = 200, .expected = 100, .deviation = 3.0 },
    };

    agg.process(&results, 1 * ns);
    try std.testing.expectEqual(@as(u32, 1), agg.activeCount());

    // Process with no new results after 31 seconds → resolved.
    var empty = [_]DetectorResult{};
    agg.process(&empty, 32 * ns);
    try std.testing.expectEqual(@as(u32, 0), agg.activeCount());
}

test "normalize z-score" {
    // z=0 → 0.0
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), normalizeZScore(0), 0.01);
    // z=3 → ~0.47
    try std.testing.expect(normalizeZScore(3.0) > 0.4);
    try std.testing.expect(normalizeZScore(3.0) < 0.6);
    // z=10 → ~0.91
    try std.testing.expect(normalizeZScore(10.0) > 0.9);
    // Monotonically increasing.
    try std.testing.expect(normalizeZScore(5.0) > normalizeZScore(3.0));
}
