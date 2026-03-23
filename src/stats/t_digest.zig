const std = @import("std");

/// T-Digest streaming percentile estimator.
/// Estimates arbitrary quantiles (p50, p95, p99) from a stream without
/// storing all values. Uses at most 256 centroids (~4 KiB).
pub const TDigest = struct {
    centroids: [max_centroids]Centroid,
    count: u16,
    total_weight: f64,
    min_val: f64,
    max_val: f64,
    compression: f64,

    const max_centroids = 256;

    pub const Centroid = struct {
        mean: f64 = 0,
        weight: f64 = 0,
    };

    /// Create a new TDigest with the given compression parameter.
    /// Higher compression = more centroids retained = better accuracy.
    /// Default: 100.
    pub fn init(compression: f64) TDigest {
        return .{
            .centroids = [_]Centroid{.{}} ** max_centroids,
            .count = 0,
            .total_weight = 0,
            .min_val = std.math.floatMax(f64),
            .max_val = -std.math.floatMax(f64),
            .compression = compression,
        };
    }

    /// Add a single value to the digest.
    pub fn add(self: *TDigest, value: f64) void {
        self.addWeighted(value, 1.0);
    }

    /// Add a weighted value to the digest.
    pub fn addWeighted(self: *TDigest, value: f64, weight: f64) void {
        self.min_val = @min(self.min_val, value);
        self.max_val = @max(self.max_val, value);
        self.total_weight += weight;

        if (self.count == 0) {
            self.centroids[0] = .{ .mean = value, .weight = weight };
            self.count = 1;
            return;
        }

        // Find the nearest centroid.
        var nearest_idx: u16 = 0;
        var nearest_dist: f64 = std.math.floatMax(f64);
        for (self.centroids[0..self.count], 0..) |c, i| {
            const dist = @abs(c.mean - value);
            if (dist < nearest_dist) {
                nearest_dist = dist;
                nearest_idx = @intCast(i);
            }
        }

        // Check if we can merge into the nearest centroid.
        const q = self.cumulativeWeight(nearest_idx) / self.total_weight;
        const max_weight = self.maxWeight(q);

        if (self.centroids[nearest_idx].weight + weight <= max_weight) {
            // Merge: update weighted mean.
            const c = &self.centroids[nearest_idx];
            c.mean = (c.mean * c.weight + value * weight) / (c.weight + weight);
            c.weight += weight;
        } else if (self.count < max_centroids) {
            // Insert new centroid, keeping sorted order.
            self.insertCentroid(value, weight);
        } else {
            // At capacity — compress then insert.
            self.compress();
            if (self.count < max_centroids) {
                self.insertCentroid(value, weight);
            } else {
                // Force merge into nearest as last resort.
                const c = &self.centroids[nearest_idx];
                c.mean = (c.mean * c.weight + value * weight) / (c.weight + weight);
                c.weight += weight;
            }
        }
    }

    /// Estimate the value at quantile q (0.0 to 1.0).
    pub fn quantile(self: *const TDigest, q: f64) f64 {
        if (self.count == 0) return 0;
        if (self.count == 1) return self.centroids[0].mean;

        const target = q * self.total_weight;

        // Walk centroids accumulating weight.
        var cumulative: f64 = 0;
        for (self.centroids[0..self.count], 0..) |c, i| {
            const lower = cumulative;
            const upper = cumulative + c.weight;
            const mid = lower + c.weight / 2.0;

            if (target < mid) {
                if (i == 0) {
                    // Interpolate between min and first centroid.
                    if (c.weight == 1) return c.mean;
                    const inner_q = target / (c.weight / 2.0);
                    return self.min_val + inner_q * (c.mean - self.min_val);
                }
                // Interpolate between previous centroid and this one.
                const prev = self.centroids[i - 1];
                const prev_mid = lower - prev.weight / 2.0;
                const frac = (target - prev_mid) / (mid - prev_mid);
                return prev.mean + frac * (c.mean - prev.mean);
            }

            if (target <= upper and i == self.count - 1) {
                // In the last centroid — interpolate to max.
                if (c.weight == 1) return c.mean;
                const inner_q = (target - mid) / (c.weight / 2.0);
                return c.mean + inner_q * (self.max_val - c.mean);
            }

            cumulative = upper;
        }

        return self.max_val;
    }

    pub fn p50(self: *const TDigest) f64 {
        return self.quantile(0.50);
    }

    pub fn p95(self: *const TDigest) f64 {
        return self.quantile(0.95);
    }

    pub fn p99(self: *const TDigest) f64 {
        return self.quantile(0.99);
    }

    /// Merge another digest into this one.
    pub fn merge(self: *TDigest, other: *const TDigest) void {
        if (other.count == 0) return;
        self.min_val = @min(self.min_val, other.min_val);
        self.max_val = @max(self.max_val, other.max_val);

        for (other.centroids[0..other.count]) |c| {
            self.addWeighted(c.mean, c.weight);
        }
    }

    /// Reset the digest.
    pub fn reset(self: *TDigest) void {
        self.count = 0;
        self.total_weight = 0;
        self.min_val = std.math.floatMax(f64);
        self.max_val = -std.math.floatMax(f64);
    }

    // --- Internal ---

    /// Cumulative weight up to (but not including) centroid at idx.
    fn cumulativeWeight(self: *const TDigest, idx: u16) f64 {
        var sum: f64 = 0;
        for (self.centroids[0..idx]) |c| {
            sum += c.weight;
        }
        // Add half of the centroid's own weight for the midpoint.
        return sum + self.centroids[idx].weight / 2.0;
    }

    /// Maximum weight for a centroid at quantile position q.
    /// Based on the scale function k1: k(q) = (compression/2) * asin(2q - 1) / pi.
    fn maxWeight(self: *const TDigest, q: f64) f64 {
        const clamped = std.math.clamp(q, 0.0, 1.0);
        // Derivative of k1 scale function determines max weight.
        const denom = @sqrt(clamped * (1.0 - clamped));
        if (denom < 1e-15) return 1.0;
        return @max(1.0, 4.0 * self.total_weight * denom / self.compression);
    }

    /// Insert a new centroid in sorted order by mean.
    fn insertCentroid(self: *TDigest, mean: f64, weight: f64) void {
        // Find insertion point.
        var pos: u16 = self.count;
        for (self.centroids[0..self.count], 0..) |c, i| {
            if (mean < c.mean) {
                pos = @intCast(i);
                break;
            }
        }

        // Shift right.
        var j: u16 = self.count;
        while (j > pos) : (j -= 1) {
            self.centroids[j] = self.centroids[j - 1];
        }

        self.centroids[pos] = .{ .mean = mean, .weight = weight };
        self.count += 1;
    }

    /// Compress by merging adjacent centroids that are under the weight bound.
    fn compress(self: *TDigest) void {
        if (self.count <= 1) return;

        var new_centroids: [max_centroids]Centroid = undefined;
        var new_count: u16 = 0;
        var cumulative: f64 = 0;

        var i: u16 = 0;
        while (i < self.count) {
            var c = self.centroids[i];
            cumulative += c.weight;

            // Try to merge with subsequent centroids.
            while (i + 1 < self.count) {
                const next = self.centroids[i + 1];
                const q = cumulative / self.total_weight;
                const max_w = self.maxWeight(q);

                if (c.weight + next.weight <= max_w) {
                    // Merge.
                    const total_w = c.weight + next.weight;
                    c.mean = (c.mean * c.weight + next.mean * next.weight) / total_w;
                    c.weight = total_w;
                    cumulative += next.weight;
                    i += 1;
                } else {
                    break;
                }
            }

            new_centroids[new_count] = c;
            new_count += 1;
            i += 1;
        }

        @memcpy(self.centroids[0..new_count], new_centroids[0..new_count]);
        self.count = new_count;
    }
};

test "tdigest percentiles on normal distribution" {
    var td = TDigest.init(100);

    // Generate 10,000 values from approximate N(100, 15) using
    // simple additive uniform random (central limit theorem approximation).
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    for (0..10_000) |_| {
        // Sum of 12 uniform [0,1) → approx N(6, 1), scale to N(100, 15).
        var sum: f64 = 0;
        for (0..12) |_| {
            sum += random.float(f64);
        }
        const value = (sum - 6.0) * 15.0 + 100.0;
        td.add(value);
    }

    const median = td.p50();
    const p99 = td.p99();

    // p50 within 2 of 100.
    try std.testing.expect(@abs(median - 100.0) < 2.0);
    // p99 within 5 of 135 (100 + 2.326 * 15 ≈ 134.9).
    try std.testing.expect(@abs(p99 - 135.0) < 5.0);
}

test "tdigest uniform distribution" {
    var td = TDigest.init(100);

    // Add values 1..1000.
    for (1..1001) |i| {
        td.add(@floatFromInt(i));
    }

    const median = td.p50();
    const p95 = td.p95();

    // Median should be ~500.
    try std.testing.expect(@abs(median - 500.0) < 15.0);
    // p95 should be ~950.
    try std.testing.expect(@abs(p95 - 950.0) < 15.0);
}

test "tdigest edge cases" {
    var td = TDigest.init(100);

    // Empty digest.
    try std.testing.expectEqual(@as(f64, 0), td.quantile(0.5));

    // Single value.
    td.add(42.0);
    try std.testing.expectEqual(@as(f64, 42.0), td.p50());

    // Two values.
    td.add(100.0);
    const med = td.p50();
    try std.testing.expect(med >= 42.0 and med <= 100.0);
}

test "tdigest merge" {
    var td_a = TDigest.init(100);
    var td_b = TDigest.init(100);

    for (1..501) |i| td_a.add(@floatFromInt(i));
    for (501..1001) |i| td_b.add(@floatFromInt(i));

    td_a.merge(&td_b);
    const median = td_a.p50();
    try std.testing.expect(@abs(median - 500.0) < 20.0);
}

test "tdigest reset" {
    var td = TDigest.init(100);
    for (0..100) |i| td.add(@floatFromInt(i));
    try std.testing.expect(td.count > 0);

    td.reset();
    try std.testing.expectEqual(@as(u16, 0), td.count);
    try std.testing.expectEqual(@as(f64, 0), td.total_weight);
}
