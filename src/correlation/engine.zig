const std = @import("std");

/// Kind of correlation signal.
pub const SignalKind = enum {
    anomaly_alert,
    group_spike,
    group_new,
    trace_failure_burst,
    deploy_detected,
    error_cascade,
    rate_change,
};

/// A normalized correlation signal from any source.
pub const CorrelationSignal = struct {
    kind: SignalKind,
    onset_ns: i128,
    peak_ns: i128,
    magnitude: f64,
    label: Label,
    source_id: u32,

    pub const Label = struct {
        buf: [128]u8 = undefined,
        len: u8 = 0,

        pub fn from(s: []const u8) Label {
            var l = Label{};
            const copy_len = @min(s.len, 128);
            @memcpy(l.buf[0..copy_len], s[0..copy_len]);
            l.len = @intCast(copy_len);
            return l;
        }

        pub fn slice(self: *const Label) []const u8 {
            return self.buf[0..self.len];
        }
    };
};

/// A ranked causal hypothesis.
pub const Hypothesis = struct {
    /// The effect being explained.
    effect: CorrelationSignal,

    /// Candidate causes, ordered by strength.
    causes: [max_causes]Cause = undefined,
    cause_count: u8 = 0,

    /// Overall confidence in the hypothesis.
    confidence: f64 = 0,

    const max_causes = 8;

    pub const Cause = struct {
        signal: CorrelationSignal,
        strength: f64,
        lag_ns: i128,
    };

    pub fn addCause(self: *Hypothesis, cause: Cause) bool {
        if (self.cause_count >= max_causes) return false;
        self.causes[self.cause_count] = cause;
        self.cause_count += 1;
        // Recompute confidence as max strength.
        if (cause.strength > self.confidence) {
            self.confidence = cause.strength;
        }
        return true;
    }
};

/// Temporal proximity analyzer.
/// Finds signals that co-occur within a time window.
pub const TemporalProximity = struct {
    window_ns: i128,
    signals: [max_signals]?CorrelationSignal = [_]?CorrelationSignal{null} ** max_signals,
    signal_count: u32 = 0,

    const max_signals = 256;

    pub fn init(window_ns: i128) TemporalProximity {
        return .{ .window_ns = window_ns };
    }

    /// Record a new signal.
    pub fn record(self: *TemporalProximity, signal: CorrelationSignal) void {
        if (self.signal_count < max_signals) {
            self.signals[self.signal_count] = signal;
            self.signal_count += 1;
        }
    }

    /// Find signals that occurred within the time window before a given signal.
    /// Returns candidate causes ordered by temporal proximity.
    pub fn findRelated(self: *const TemporalProximity, effect: *const CorrelationSignal, out: []Hypothesis.Cause) u32 {
        var count: u32 = 0;

        for (self.signals[0..self.signal_count]) |slot| {
            if (slot) |signal| {
                // Skip self.
                if (signal.onset_ns == effect.onset_ns and
                    signal.source_id == effect.source_id and
                    signal.kind == effect.kind) continue;

                // Must precede or be concurrent with the effect.
                const lag = effect.onset_ns - signal.peak_ns;
                if (lag < 0) continue; // signal is after effect
                if (lag > self.window_ns) continue; // too old

                // Strength: closer in time = stronger.
                const normalized_lag = @as(f64, @floatFromInt(lag)) / @as(f64, @floatFromInt(self.window_ns));
                const strength = (1.0 - normalized_lag) * signal.magnitude;

                if (count < out.len) {
                    out[count] = .{
                        .signal = signal,
                        .strength = strength,
                        .lag_ns = lag,
                    };
                    count += 1;
                }
            }
        }

        // Sort by strength descending.
        if (count > 1) {
            std.mem.sort(Hypothesis.Cause, out[0..count], {}, struct {
                fn cmp(_: void, a: Hypothesis.Cause, b: Hypothesis.Cause) bool {
                    return a.strength > b.strength;
                }
            }.cmp);
        }

        return count;
    }

    /// Build a hypothesis for a given effect signal.
    pub fn hypothesize(self: *const TemporalProximity, effect: CorrelationSignal) Hypothesis {
        var hyp = Hypothesis{ .effect = effect };
        var causes: [8]Hypothesis.Cause = undefined;
        const count = self.findRelated(&effect, &causes);

        for (causes[0..count]) |cause| {
            _ = hyp.addCause(cause);
        }

        return hyp;
    }

    /// Evict signals older than now_ns - retention window.
    pub fn evict(self: *TemporalProximity, now_ns: i128, retention_ns: i128) void {
        var write: u32 = 0;
        for (0..self.signal_count) |i| {
            if (self.signals[i]) |signal| {
                if (now_ns - signal.peak_ns <= retention_ns) {
                    self.signals[write] = signal;
                    write += 1;
                }
            }
        }
        // Clear remaining.
        for (write..max_signals) |i| {
            self.signals[i] = null;
        }
        self.signal_count = write;
    }
};

test "temporal proximity finds related signals" {
    const ns = std.time.ns_per_s;
    var tp = TemporalProximity.init(60 * ns); // 60s window

    // Record a DB latency spike at t=10.
    tp.record(.{
        .kind = .anomaly_alert,
        .onset_ns = 10 * ns,
        .peak_ns = 10 * ns,
        .magnitude = 0.8,
        .label = CorrelationSignal.Label.from("DB latency spike"),
        .source_id = 1,
    });

    // Record a deploy at t=5.
    tp.record(.{
        .kind = .deploy_detected,
        .onset_ns = 5 * ns,
        .peak_ns = 5 * ns,
        .magnitude = 0.5,
        .label = CorrelationSignal.Label.from("deploy detected"),
        .source_id = 2,
    });

    // Effect: error rate spike at t=15.
    const effect = CorrelationSignal{
        .kind = .anomaly_alert,
        .onset_ns = 15 * ns,
        .peak_ns = 15 * ns,
        .magnitude = 0.9,
        .label = CorrelationSignal.Label.from("error rate spike"),
        .source_id = 3,
    };

    var causes: [8]Hypothesis.Cause = undefined;
    const count = tp.findRelated(&effect, &causes);

    try std.testing.expectEqual(@as(u32, 2), count);
    // DB latency spike (5s lag, higher magnitude) should rank first.
    try std.testing.expect(causes[0].strength > causes[1].strength);
}

test "hypothesis building" {
    const ns = std.time.ns_per_s;
    var tp = TemporalProximity.init(60 * ns);

    tp.record(.{
        .kind = .anomaly_alert,
        .onset_ns = 10 * ns,
        .peak_ns = 10 * ns,
        .magnitude = 0.8,
        .label = CorrelationSignal.Label.from("DB latency"),
        .source_id = 1,
    });

    const effect = CorrelationSignal{
        .kind = .group_spike,
        .onset_ns = 12 * ns,
        .peak_ns = 12 * ns,
        .magnitude = 0.9,
        .label = CorrelationSignal.Label.from("error group rising"),
        .source_id = 2,
    };

    const hyp = tp.hypothesize(effect);
    try std.testing.expectEqual(@as(u8, 1), hyp.cause_count);
    try std.testing.expect(hyp.confidence > 0);
}

test "temporal proximity eviction" {
    const ns = std.time.ns_per_s;
    var tp = TemporalProximity.init(60 * ns);

    tp.record(.{
        .kind = .anomaly_alert,
        .onset_ns = 1 * ns,
        .peak_ns = 1 * ns,
        .magnitude = 0.5,
        .label = CorrelationSignal.Label.from("old signal"),
        .source_id = 1,
    });
    tp.record(.{
        .kind = .anomaly_alert,
        .onset_ns = 50 * ns,
        .peak_ns = 50 * ns,
        .magnitude = 0.5,
        .label = CorrelationSignal.Label.from("recent signal"),
        .source_id = 2,
    });

    try std.testing.expectEqual(@as(u32, 2), tp.signal_count);

    // Evict signals older than 30s from now=55s.
    tp.evict(55 * ns, 30 * ns);
    try std.testing.expectEqual(@as(u32, 1), tp.signal_count);
}
