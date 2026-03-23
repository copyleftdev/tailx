const std = @import("std");

/// Fixed-size accumulator for one time slice.
pub const Bucket = struct {
    count: u64,
    sum: f64,
    min: f64,
    max: f64,
    start_ns: i128,

    pub fn init() Bucket {
        return .{
            .count = 0,
            .sum = 0,
            .min = std.math.floatMax(f64),
            .max = -std.math.floatMax(f64),
            .start_ns = 0,
        };
    }

    /// Reset the bucket for reuse.
    pub fn reset(self: *Bucket) void {
        self.count = 0;
        self.sum = 0;
        self.min = std.math.floatMax(f64);
        self.max = -std.math.floatMax(f64);
        self.start_ns = 0;
    }

    /// Record a value into this bucket.
    pub fn record(self: *Bucket, value: f64) void {
        self.count += 1;
        self.sum += value;
        self.min = @min(self.min, value);
        self.max = @max(self.max, value);
    }

    /// Mean of recorded values, or null if empty.
    pub fn mean(self: Bucket) ?f64 {
        if (self.count == 0) return null;
        return self.sum / @as(f64, @floatFromInt(self.count));
    }
};

/// Sliding time window with a circular array of Buckets.
/// All statistical tracking operates over these windows.
pub const TimeWindow = struct {
    buckets: []Bucket,
    bucket_count: u16,
    duration_ns: i128,
    bucket_duration_ns: i128,
    head: u16,
    head_start_ns: i128,
    initialized: bool,
    allocator: std.mem.Allocator,

    /// Create a new TimeWindow.
    /// duration_ns: total window span.
    /// bucket_count: number of buckets to divide the window into.
    pub fn init(allocator: std.mem.Allocator, duration_ns: i128, bucket_count: u16) !TimeWindow {
        const buckets = try allocator.alloc(Bucket, bucket_count);
        for (buckets) |*b| b.* = Bucket.init();

        return .{
            .buckets = buckets,
            .bucket_count = bucket_count,
            .duration_ns = duration_ns,
            .bucket_duration_ns = @divTrunc(duration_ns, bucket_count),
            .head = 0,
            .head_start_ns = 0,
            .initialized = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TimeWindow) void {
        self.allocator.free(self.buckets);
        self.* = undefined;
    }

    /// Advance the window to cover timestamp `now_ns`.
    /// Clears any buckets that fall out of the window.
    pub fn advance(self: *TimeWindow, now_ns: i128) void {
        if (!self.initialized) {
            // First event — anchor the window.
            self.head_start_ns = now_ns - @mod(now_ns, self.bucket_duration_ns);
            self.buckets[self.head].start_ns = self.head_start_ns;
            self.initialized = true;
            return;
        }

        const elapsed = now_ns - self.head_start_ns;
        if (elapsed < self.bucket_duration_ns) return; // still in current bucket

        const steps_raw = @divTrunc(elapsed, self.bucket_duration_ns);
        const steps: u16 = if (steps_raw > self.bucket_count)
            self.bucket_count
        else
            @intCast(steps_raw);

        if (steps >= self.bucket_count) {
            // Gap exceeds the entire window — clear everything.
            for (self.buckets) |*b| b.reset();
            self.head = 0;
            self.head_start_ns = now_ns - @mod(now_ns, self.bucket_duration_ns);
            self.buckets[self.head].start_ns = self.head_start_ns;
            return;
        }

        // Advance head by `steps`, clearing recycled buckets.
        for (0..steps) |_| {
            self.head = (self.head + 1) % self.bucket_count;
            self.head_start_ns += self.bucket_duration_ns;
            self.buckets[self.head].reset();
            self.buckets[self.head].start_ns = self.head_start_ns;
        }
    }

    /// Map a timestamp to its bucket, or null if outside the window.
    pub fn bucketFor(self: *TimeWindow, ts_ns: i128) ?*Bucket {
        if (!self.initialized) return null;

        // Current bucket covers [head_start_ns, head_start_ns + bucket_duration_ns).
        const bucket_end = self.head_start_ns + self.bucket_duration_ns;
        if (ts_ns >= bucket_end) return null; // future

        // Oldest bucket start.
        const window_start = self.head_start_ns - (@as(i128, self.bucket_count - 1) * self.bucket_duration_ns);
        if (ts_ns < window_start) return null; // too old

        const offset = @divTrunc(ts_ns - window_start, self.bucket_duration_ns);
        // The oldest bucket is at (head + 1) % bucket_count.
        const oldest_idx = (self.head + 1) % self.bucket_count;
        const idx: u16 = @intCast((@as(u32, oldest_idx) + @as(u32, @intCast(offset))) % self.bucket_count);
        return &self.buckets[idx];
    }

    /// Record a value at the given timestamp. Advances window if needed.
    pub fn record(self: *TimeWindow, value: f64, ts_ns: i128) void {
        self.advance(ts_ns);
        if (self.bucketFor(ts_ns)) |bucket| {
            bucket.record(value);
        }
    }

    /// Total count across all buckets in the window.
    pub fn totalCount(self: *const TimeWindow) u64 {
        var total: u64 = 0;
        for (self.buckets) |b| total += b.count;
        return total;
    }

    /// Total sum across all buckets.
    pub fn totalSum(self: *const TimeWindow) f64 {
        var total: f64 = 0;
        for (self.buckets) |b| total += b.sum;
        return total;
    }

    /// Events per second over the entire window duration.
    pub fn rate(self: *const TimeWindow) f64 {
        const count = self.totalCount();
        if (count == 0) return 0;
        const duration_secs = @as(f64, @floatFromInt(self.duration_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        return @as(f64, @floatFromInt(count)) / duration_secs;
    }
};

test "bucket record and mean" {
    var b = Bucket.init();
    try std.testing.expectEqual(@as(?f64, null), b.mean());

    b.record(10.0);
    b.record(20.0);
    b.record(30.0);

    try std.testing.expectEqual(@as(u64, 3), b.count);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), b.mean().?, 0.001);
    try std.testing.expectEqual(@as(f64, 10.0), b.min);
    try std.testing.expectEqual(@as(f64, 30.0), b.max);
}

test "time window advance clears old buckets" {
    const ns: i128 = std.time.ns_per_s;
    var tw = try TimeWindow.init(std.testing.allocator, 60 * ns, 60);
    defer tw.deinit();

    // Record at t=1s (avoid t=0 edge case with bucket alignment).
    tw.record(1.0, 1 * ns);
    try std.testing.expectEqual(@as(u64, 1), tw.totalCount());

    // Advance by 5 buckets (5 seconds).
    tw.record(1.0, 6 * ns);
    try std.testing.expectEqual(@as(u64, 2), tw.totalCount());

    // The first event's bucket should still be in the window.
    try std.testing.expect(tw.bucketFor(1 * ns) != null);

    // Advance past the full window — old data should be cleared.
    tw.record(1.0, 62 * ns);
    // t=1s is now outside the window.
    try std.testing.expectEqual(@as(?*Bucket, null), tw.bucketFor(1 * ns));
}

test "time window timestamp outside window returns null" {
    const ns: i128 = std.time.ns_per_s;
    var tw = try TimeWindow.init(std.testing.allocator, 60 * ns, 60);
    defer tw.deinit();

    tw.record(1.0, 30 * ns);

    // Future timestamp.
    try std.testing.expectEqual(@as(?*Bucket, null), tw.bucketFor(100 * ns));

    // Past timestamp (before window start).
    try std.testing.expectEqual(@as(?*Bucket, null), tw.bucketFor(-100 * ns));
}

test "time window rate calculation" {
    const ns: i128 = std.time.ns_per_s;
    var tw = try TimeWindow.init(std.testing.allocator, 10 * ns, 10);
    defer tw.deinit();

    // Record 100 events spread across 10 seconds (0..9).
    for (0..10) |sec| {
        for (0..10) |_| {
            tw.record(1.0, @as(i128, @intCast(sec)) * ns);
        }
    }

    const r = tw.rate();
    // 100 events over 10 seconds = 10/sec.
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), r, 0.01);
}

test "time window large gap clears all" {
    const ns: i128 = std.time.ns_per_s;
    var tw = try TimeWindow.init(std.testing.allocator, 60 * ns, 60);
    defer tw.deinit();

    // Record some data.
    for (0..10) |sec| {
        tw.record(1.0, @as(i128, @intCast(sec)) * ns);
    }
    try std.testing.expectEqual(@as(u64, 10), tw.totalCount());

    // Jump ahead by 2 minutes — entire window should be cleared.
    tw.record(1.0, 120 * ns);
    try std.testing.expectEqual(@as(u64, 1), tw.totalCount());
}
