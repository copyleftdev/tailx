const std = @import("std");

/// Drain log template extraction.
/// Assigns structural fingerprints to log messages. Lines with the same
/// template but different parameters get the same hash.
///
/// Example:
///   "Connection to 10.0.0.1:5432 timed out after 30s"
///   "Connection to 10.0.0.2:5432 timed out after 45s"
///   → template: "Connection to <*> timed out after <*>"
///   → same template_hash
pub const DrainTree = struct {
    clusters: [max_clusters]?Cluster = [_]?Cluster{null} ** max_clusters,
    cluster_count: u16 = 0,
    max_depth: u8,
    sim_threshold: f32,

    pub const max_clusters = 4096;

    pub const Cluster = struct {
        template_hash: u64,
        tokens: [max_tokens]Token,
        token_count: u8,
        count: u32,

        const max_tokens = 64;

        const Token = struct {
            data: [48]u8,
            len: u8,
            is_wildcard: bool,

            fn from(s: []const u8) Token {
                var t = Token{ .data = undefined, .len = 0, .is_wildcard = false };
                const copy_len = @min(s.len, 48);
                @memcpy(t.data[0..copy_len], s[0..copy_len]);
                t.len = @intCast(copy_len);
                return t;
            }

            fn wildcard() Token {
                var t = Token{ .data = undefined, .len = 3, .is_wildcard = true };
                @memcpy(t.data[0..3], "<*>");
                return t;
            }

            fn slice(self: *const Token) []const u8 {
                return self.data[0..self.len];
            }
        };
    };

    /// Create a new DrainTree.
    pub fn init(max_depth: u8, sim_threshold: f32) DrainTree {
        return .{
            .max_depth = max_depth,
            .sim_threshold = sim_threshold,
        };
    }

    /// Process a message and return its template hash.
    pub fn process(self: *DrainTree, message: []const u8) u64 {
        // 1. Tokenize by spaces (limited to max_tokens).
        var tokens: [Cluster.max_tokens][]const u8 = undefined;
        var token_count: u8 = 0;
        var iter = std.mem.tokenizeAny(u8, message, " \t");
        while (iter.next()) |tok| {
            if (token_count >= Cluster.max_tokens) break;
            tokens[token_count] = tok;
            token_count += 1;
        }

        if (token_count == 0) return 0;

        // 2. Classify tokens — decide which are wildcards.
        var classified: [Cluster.max_tokens]Cluster.Token = undefined;
        for (0..token_count) |i| {
            if (isVariable(tokens[i])) {
                classified[i] = Cluster.Token.wildcard();
            } else {
                classified[i] = Cluster.Token.from(tokens[i]);
            }
        }

        // 3. Find matching cluster.
        var best_idx: ?u16 = null;
        var best_sim: f32 = 0;

        for (0..self.cluster_count) |i| {
            if (self.clusters[i]) |*cluster| {
                if (cluster.token_count == token_count) {
                    const sim = similarity(classified[0..token_count], cluster.tokens[0..cluster.token_count]);
                    if (sim >= self.sim_threshold and sim > best_sim) {
                        best_sim = sim;
                        best_idx = @intCast(i);
                    }
                }
            }
        }

        if (best_idx) |idx| {
            // Merge into existing cluster — generalize tokens.
            var cluster = &(self.clusters[idx].?);
            for (0..cluster.token_count) |i| {
                if (!cluster.tokens[i].is_wildcard and !std.mem.eql(u8, cluster.tokens[i].slice(), classified[i].slice())) {
                    cluster.tokens[i] = Cluster.Token.wildcard();
                }
            }
            // Recompute hash after merge.
            cluster.template_hash = computeTemplateHash(cluster.tokens[0..cluster.token_count]);
            cluster.count += 1;
            return cluster.template_hash;
        }

        // 4. Create new cluster.
        if (self.cluster_count < max_clusters) {
            const hash = computeTemplateHash(classified[0..token_count]);
            var cluster = Cluster{
                .template_hash = hash,
                .tokens = undefined,
                .token_count = token_count,
                .count = 1,
            };
            @memcpy(cluster.tokens[0..token_count], classified[0..token_count]);
            self.clusters[self.cluster_count] = cluster;
            self.cluster_count += 1;
            return hash;
        }

        // At capacity — just hash the classified tokens.
        return computeTemplateHash(classified[0..token_count]);
    }

    /// Check if a token is likely a variable parameter.
    /// Per spec: "Contains digits → likely a parameter (<*>)".
    fn isVariable(token: []const u8) bool {
        if (token.len == 0) return false;

        // Quoted strings.
        if (token.len >= 2 and token[0] == '"' and token[token.len - 1] == '"') return true;

        // Contains any digit → variable (spec rule).
        for (token) |c| {
            if (c >= '0' and c <= '9') return true;
        }

        return false;
    }

    fn similarity(a: []const Cluster.Token, b: []const Cluster.Token) f32 {
        if (a.len != b.len or a.len == 0) return 0;
        var matches: u32 = 0;
        for (a, b) |ta, tb| {
            if (ta.is_wildcard or tb.is_wildcard) {
                matches += 1;
            } else if (std.mem.eql(u8, ta.slice(), tb.slice())) {
                matches += 1;
            }
        }
        return @as(f32, @floatFromInt(matches)) / @as(f32, @floatFromInt(a.len));
    }

    fn computeTemplateHash(tokens: []const Cluster.Token) u64 {
        var hasher = std.hash.Fnv1a_64.init();
        for (tokens) |t| {
            hasher.update(t.slice());
            hasher.update(" ");
        }
        return hasher.final();
    }
};

test "drain same template same hash" {
    var drain = DrainTree.init(4, 0.5);

    const h1 = drain.process("Connection to 10.0.0.1:5432 timed out after 30s");
    const h2 = drain.process("Connection to 10.0.0.2:5432 timed out after 45s");

    try std.testing.expectEqual(h1, h2);
}

test "drain different templates different hash" {
    var drain = DrainTree.init(4, 0.5);

    const h1 = drain.process("Connection to 10.0.0.1 timed out after 30s");
    const h2 = drain.process("User logged in from 10.0.0.1 at 14:00");

    try std.testing.expect(h1 != h2);
}

test "drain counts events per cluster" {
    var drain = DrainTree.init(4, 0.5);

    _ = drain.process("Request completed in 42ms");
    _ = drain.process("Request completed in 55ms");
    _ = drain.process("Request completed in 12ms");

    // First cluster should have count 3.
    try std.testing.expect(drain.clusters[0] != null);
    try std.testing.expectEqual(@as(u32, 3), drain.clusters[0].?.count);
}

test "drain variable detection" {
    var drain = DrainTree.init(4, 0.5);

    // These should produce the same template.
    const h1 = drain.process("Error 500 on server web01");
    const h2 = drain.process("Error 404 on server web02");

    try std.testing.expectEqual(h1, h2);
}

test "drain empty message" {
    var drain = DrainTree.init(4, 0.5);
    const h = drain.process("");
    try std.testing.expectEqual(@as(u64, 0), h);
}

test "drain uuid detection" {
    var drain = DrainTree.init(4, 0.5);

    const h1 = drain.process("Processing request 550e8400-e29b-41d4-a716-446655440000");
    const h2 = drain.process("Processing request a1b2c3d4-e5f6-7890-abcd-ef1234567890");

    try std.testing.expectEqual(h1, h2);
}
