const std = @import("std");

/// Count-Min Sketch for frequency estimation.
/// Probabilistic data structure that estimates how often a key appears.
pub const CountMinSketch = struct {
    matrix: [][]u32,
    depth: u8,
    width: u32,
    seeds: []u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, depth: u8, width: u32) !CountMinSketch {
        const matrix = try allocator.alloc([]u32, depth);
        errdefer allocator.free(matrix);

        for (matrix, 0..) |*row, i| {
            row.* = try allocator.alloc(u32, width);
            errdefer {
                for (matrix[0..i]) |prev_row| allocator.free(prev_row);
            }
            @memset(row.*, 0);
        }

        const seeds = try allocator.alloc(u64, depth);
        // Use deterministic seeds based on row index for reproducibility.
        for (seeds, 0..) |*s, i| {
            s.* = @as(u64, 0x517cc1b727220a95) ^ (@as(u64, @intCast(i)) *% 0x6c62272e07bb0142);
        }

        return .{
            .matrix = matrix,
            .depth = depth,
            .width = width,
            .seeds = seeds,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CountMinSketch) void {
        for (self.matrix) |row| self.allocator.free(row);
        self.allocator.free(self.matrix);
        self.allocator.free(self.seeds);
        self.* = undefined;
    }

    /// Increment count for key.
    pub fn add(self: *CountMinSketch, key: []const u8, count: u32) void {
        for (0..self.depth) |i| {
            const idx = self.hash(key, self.seeds[i]);
            self.matrix[i][idx] +|= count; // saturating add
        }
    }

    /// Increment count for a u64 key.
    pub fn addHash(self: *CountMinSketch, key_hash: u64, count: u32) void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, key_hash, .little);
        self.add(&buf, count);
    }

    /// Estimate count for key (minimum across rows).
    pub fn estimate(self: *const CountMinSketch, key: []const u8) u32 {
        var min: u32 = std.math.maxInt(u32);
        for (0..self.depth) |i| {
            const idx = self.hash(key, self.seeds[i]);
            min = @min(min, self.matrix[i][idx]);
        }
        return min;
    }

    /// Estimate count for a u64 key.
    pub fn estimateHash(self: *const CountMinSketch, key_hash: u64) u32 {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, key_hash, .little);
        return self.estimate(&buf);
    }

    /// Decay all counts by factor (0.0–1.0).
    pub fn decay(self: *CountMinSketch, factor: f32) void {
        for (self.matrix) |row| {
            for (row) |*cell| {
                cell.* = @intFromFloat(@as(f32, @floatFromInt(cell.*)) * factor);
            }
        }
    }

    /// Reset all counts to zero.
    pub fn reset(self: *CountMinSketch) void {
        for (self.matrix) |row| @memset(row, 0);
    }

    fn hash(self: *const CountMinSketch, key: []const u8, seed: u64) u32 {
        const h = std.hash.Wyhash.hash(seed, key);
        return @intCast(h % self.width);
    }
};

test "count min sketch basic" {
    var cms = try CountMinSketch.init(std.testing.allocator, 4, 8192);
    defer cms.deinit();

    // Add "foo" 100 times.
    for (0..100) |_| cms.add("foo", 1);

    // Add "bar" once.
    cms.add("bar", 1);

    const foo_est = cms.estimate("foo");
    try std.testing.expect(foo_est >= 100);
    try std.testing.expect(foo_est <= 105); // small overcount ok

    const bar_est = cms.estimate("bar");
    try std.testing.expect(bar_est >= 1);
    try std.testing.expect(bar_est <= 5);

    // Never-seen key should have low estimate.
    const none_est = cms.estimate("never_seen");
    try std.testing.expect(none_est <= 3);
}

test "count min sketch decay" {
    var cms = try CountMinSketch.init(std.testing.allocator, 4, 1024);
    defer cms.deinit();

    for (0..1000) |_| cms.add("test", 1);
    try std.testing.expect(cms.estimate("test") >= 1000);

    cms.decay(0.5);
    const after = cms.estimate("test");
    try std.testing.expect(after >= 400);
    try std.testing.expect(after <= 600);
}

test "count min sketch hash key" {
    var cms = try CountMinSketch.init(std.testing.allocator, 4, 4096);
    defer cms.deinit();

    cms.addHash(12345, 50);
    const est = cms.estimateHash(12345);
    try std.testing.expect(est >= 50);
    try std.testing.expect(est <= 55);
}
