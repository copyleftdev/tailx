const std = @import("std");

/// MinHash signature for near-duplicate template detection.
/// Estimates Jaccard similarity between template token sets.
pub const MinHashSignature = struct {
    hashes: [num_hashes]u64,

    const num_hashes = 64;

    /// Compute a MinHash signature from a template string.
    pub fn compute(template: []const u8) MinHashSignature {
        var sig = MinHashSignature{ .hashes = [_]u64{std.math.maxInt(u64)} ** num_hashes };

        var iter = std.mem.tokenizeAny(u8, template, " \t");
        while (iter.next()) |token| {
            for (0..num_hashes) |i| {
                // Use different seeds per hash function.
                const seed = @as(u64, 0x9e3779b97f4a7c15) ^ (@as(u64, @intCast(i)) *% 0x517cc1b727220a95);
                const h = std.hash.Wyhash.hash(seed, token);
                sig.hashes[i] = @min(sig.hashes[i], h);
            }
        }

        return sig;
    }

    /// Estimate Jaccard similarity (0.0 to 1.0).
    pub fn similarity(a: *const MinHashSignature, b: *const MinHashSignature) f32 {
        var matches: u32 = 0;
        for (a.hashes, b.hashes) |ha, hb| {
            if (ha == hb) matches += 1;
        }
        return @as(f32, @floatFromInt(matches)) / @as(f32, num_hashes);
    }

    /// Check if two signatures are near-duplicates (similarity > threshold).
    pub fn isNearDuplicate(a: *const MinHashSignature, b: *const MinHashSignature, threshold: f32) bool {
        return similarity(a, b) >= threshold;
    }
};

test "minhash identical templates" {
    const sig_a = MinHashSignature.compute("Connection to <*> timed out after <*>");
    const sig_b = MinHashSignature.compute("Connection to <*> timed out after <*>");

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), MinHashSignature.similarity(&sig_a, &sig_b), 0.001);
}

test "minhash similar templates" {
    const sig_a = MinHashSignature.compute("Connection to <*> failed");
    const sig_b = MinHashSignature.compute("Connection to <*> has failed");

    const sim = MinHashSignature.similarity(&sig_a, &sig_b);
    // These share 3/4 or 3/5 tokens → high similarity.
    try std.testing.expect(sim > 0.4);
}

test "minhash different templates" {
    const sig_a = MinHashSignature.compute("Connection to <*> timed out");
    const sig_b = MinHashSignature.compute("User logged in from <*> at <*>");

    const sim = MinHashSignature.similarity(&sig_a, &sig_b);
    // Very different → low similarity.
    try std.testing.expect(sim < 0.4);
}

test "minhash near duplicate check" {
    const sig_a = MinHashSignature.compute("Request to <*> completed in <*>");
    const sig_b = MinHashSignature.compute("Request to <*> completed in <*>");

    try std.testing.expect(MinHashSignature.isNearDuplicate(&sig_a, &sig_b, 0.75));
}
