const std = @import("std");

/// HyperLogLog cardinality estimator.
/// Estimates the number of distinct values in a stream using ~16 KiB of memory.
/// Precision p=14 gives 16384 registers with ~3% standard error.
pub const HyperLogLog = struct {
    registers: [register_count]u8,

    const precision = 14;
    const register_count: u32 = 1 << precision; // 16384
    const alpha: f64 = 0.7213 / (1.0 + 1.079 / @as(f64, @floatFromInt(register_count)));

    /// Create a zeroed HyperLogLog.
    pub fn init() HyperLogLog {
        return .{ .registers = [_]u8{0} ** register_count };
    }

    /// Add a byte-string key to the sketch.
    pub fn add(self: *HyperLogLog, key: []const u8) void {
        self.addHash(std.hash.Wyhash.hash(0, key));
    }

    /// Add a pre-hashed 64-bit value.
    pub fn addHash(self: *HyperLogLog, h: u64) void {
        // Upper `precision` bits select the register.
        const shift: u6 = 64 - precision;
        const idx = h >> shift;
        // Count leading zeros of the remaining bits + 1.
        const remaining = (h << precision) | (@as(u64, 1) << (precision - 1));
        const leading_zeros: u8 = @clz(remaining) + 1;
        self.registers[@intCast(idx)] = @max(self.registers[@intCast(idx)], leading_zeros);
    }

    /// Estimate the number of distinct keys added.
    pub fn estimate(self: *const HyperLogLog) u64 {
        var sum: f64 = 0;
        var zeros: u32 = 0;
        for (self.registers) |r| {
            sum += std.math.pow(f64, 2.0, -@as(f64, @floatFromInt(r)));
            if (r == 0) zeros += 1;
        }

        const m: f64 = @floatFromInt(register_count);
        var est = alpha * m * m / sum;

        // Small range correction: linear counting when many registers are zero.
        if (est <= 2.5 * m and zeros > 0) {
            est = m * @log(m / @as(f64, @floatFromInt(zeros)));
        }

        return @intFromFloat(@round(est));
    }

    /// Merge another HLL into this one (register-wise max).
    pub fn merge(self: *HyperLogLog, other: *const HyperLogLog) void {
        for (&self.registers, other.registers) |*s, o| {
            s.* = @max(s.*, o);
        }
    }

    /// Reset all registers to zero.
    pub fn reset(self: *HyperLogLog) void {
        @memset(&self.registers, 0);
    }
};

test "hyperloglog cardinality estimation" {
    var hll = HyperLogLog.init();

    // Add 10,000 distinct strings.
    var buf: [32]u8 = undefined;
    for (0..10_000) |i| {
        const len = std.fmt.formatIntBuf(&buf, i, 10, .lower, .{});
        hll.add(buf[0..len]);
    }

    const est = hll.estimate();
    // Within 3% of 10,000 → [9700, 10300].
    try std.testing.expect(est >= 9700);
    try std.testing.expect(est <= 10300);
}

test "hyperloglog merge" {
    var hll_a = HyperLogLog.init();
    var hll_b = HyperLogLog.init();

    var buf: [32]u8 = undefined;

    // Add 5,000 distinct keys to A (0..5000).
    for (0..5_000) |i| {
        const len = std.fmt.formatIntBuf(&buf, i, 10, .lower, .{});
        hll_a.add(buf[0..len]);
    }

    // Add 5,000 distinct keys to B (5000..10000) — no overlap.
    for (5_000..10_000) |i| {
        const len = std.fmt.formatIntBuf(&buf, i, 10, .lower, .{});
        hll_b.add(buf[0..len]);
    }

    hll_a.merge(&hll_b);
    const est = hll_a.estimate();
    // Merged estimate within 3% of 10,000.
    try std.testing.expect(est >= 9700);
    try std.testing.expect(est <= 10300);
}

test "hyperloglog reset" {
    var hll = HyperLogLog.init();

    var buf: [32]u8 = undefined;
    for (0..1_000) |i| {
        const len = std.fmt.formatIntBuf(&buf, i, 10, .lower, .{});
        hll.add(buf[0..len]);
    }
    try std.testing.expect(hll.estimate() > 0);

    hll.reset();
    try std.testing.expectEqual(@as(u64, 0), hll.estimate());
}

test "hyperloglog size" {
    // Verify HLL uses ~16 KiB.
    try std.testing.expectEqual(@as(usize, 16384), @sizeOf(HyperLogLog));
}
