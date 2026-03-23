const std = @import("std");
const core = @import("../core.zig");

const Event = core.Event;
const Severity = core.Severity;
const SourceId = core.source.SourceId;

/// Trend direction for a group.
pub const Trend = enum {
    rising,
    stable,
    falling,
    new_group,
    gone,
};

/// Bitfield tracking which sources contribute to a group.
pub const SourceSet = struct {
    bits: [256]u8 = [_]u8{0} ** 256, // 2048 bits = 256 bytes

    pub fn set(self: *SourceSet, id: SourceId) void {
        self.bits[id / 8] |= @as(u8, 1) << @intCast(id % 8);
    }

    pub fn contains(self: *const SourceSet, id: SourceId) bool {
        return (self.bits[id / 8] & (@as(u8, 1) << @intCast(id % 8))) != 0;
    }

    pub fn count(self: *const SourceSet) u16 {
        var total: u16 = 0;
        for (self.bits) |byte| {
            total += @popCount(byte);
        }
        return total;
    }

    pub fn reset(self: *SourceSet) void {
        @memset(&self.bits, 0);
    }
};

/// A group of events sharing the same Drain template.
pub const EventGroup = struct {
    /// Drain template hash — primary key.
    template_hash: u64,

    /// Representative message (first event seen, capped at 255 bytes).
    exemplar: [255]u8 = undefined,
    exemplar_len: u8 = 0,

    /// Service name from first event (capped at 63 bytes).
    service_name: [63]u8 = undefined,
    service_name_len: u8 = 0,

    /// Max severity seen.
    severity: Severity = .unknown,

    /// Sources contributing to this group.
    sources: SourceSet = .{},

    /// Total events in this group.
    count: u64 = 0,

    /// Events in current short window (60s).
    count_short: u32 = 0,

    /// Events in previous short window.
    count_prev_short: u32 = 0,

    /// First seen timestamp.
    first_seen_ns: i128 = 0,

    /// Last seen timestamp.
    last_seen_ns: i128 = 0,

    /// Composite ranking score.
    score: f64 = 0,

    /// Current trend.
    trend: Trend = .new_group,

    /// Active (not merged/evicted).
    active: bool = true,

    /// Set the exemplar from a raw line.
    fn setExemplar(self: *EventGroup, raw: []const u8) void {
        const copy_len: u8 = @intCast(@min(raw.len, 255));
        @memcpy(self.exemplar[0..copy_len], raw[0..copy_len]);
        self.exemplar_len = copy_len;
    }

    pub fn getExemplar(self: *const EventGroup) []const u8 {
        return self.exemplar[0..self.exemplar_len];
    }

    pub fn getService(self: *const EventGroup) ?[]const u8 {
        if (self.service_name_len == 0) return null;
        return self.service_name[0..self.service_name_len];
    }

    fn setService(self: *EventGroup, name: []const u8) void {
        const copy_len: u8 = @intCast(@min(name.len, 63));
        @memcpy(self.service_name[0..copy_len], name[0..copy_len]);
        self.service_name_len = copy_len;
    }
};

/// Central registry of all active groups.
pub const GroupTable = struct {
    groups: [max_groups]?EventGroup = [_]?EventGroup{null} ** max_groups,
    group_count: u32 = 0,

    /// Open-addressing hash index: template_hash → group index.
    index: [index_size]IndexEntry = [_]IndexEntry{.{}} ** index_size,

    pub const max_groups = 8192;
    const index_size = 16384; // 2x for low collision rate

    const IndexEntry = struct {
        template_hash: u64 = 0,
        group_idx: u32 = 0,
        occupied: bool = false,
    };

    /// Classify an event into a group. Creates a new group if needed.
    pub fn classify(self: *GroupTable, event: *const Event) ?*EventGroup {
        if (event.template_hash == 0) return null;

        // Lookup existing group.
        if (self.findGroup(event.template_hash)) |group| {
            self.updateGroup(group, event);
            return group;
        }

        // Create new group.
        var slot_idx: u32 = 0;
        if (self.group_count >= max_groups) {
            // Evict lowest-score group.
            slot_idx = self.evict();
        } else {
            // Find first empty slot.
            slot_idx = self.findEmptySlot() orelse return null;
        }

        var group = EventGroup{
            .template_hash = event.template_hash,
        };
        group.setExemplar(event.message);
        if (event.service) |svc| group.setService(svc);
        group.first_seen_ns = event.timestamp.nanos;
        self.groups[slot_idx] = group;
        if (!self.groups[slot_idx].?.active) return null; // shouldn't happen
        self.group_count += 1;

        // Add to index.
        self.indexInsert(event.template_hash, slot_idx);

        const g = &(self.groups[slot_idx].?);
        self.updateGroup(g, event);
        return g;
    }

    /// Update group state with a new event.
    fn updateGroup(self: *GroupTable, group: *EventGroup, event: *const Event) void {
        _ = self;
        group.count += 1;
        group.count_short += 1;
        group.last_seen_ns = event.timestamp.nanos;

        // Escalate severity (use numeric ordering, not enum value).
        if (event.severity.numeric() > group.severity.numeric()) {
            group.severity = event.severity;
        }

        // Track source.
        group.sources.set(event.source);

        // Recompute score.
        group.score = computeScore(group, event.timestamp.nanos);
        group.trend = computeTrend(group);
    }

    /// Window rotation: shift counts, recompute trends.
    pub fn windowRotate(self: *GroupTable, now_ns: i128) void {
        for (&self.groups) |*slot| {
            if (slot.*) |*group| {
                if (!group.active) continue;
                group.count_prev_short = group.count_short;
                group.count_short = 0;
                group.trend = computeTrend(group);
                group.score = computeScore(group, now_ns);
            }
        }
    }

    /// Get the top N groups by score (sorted descending).
    /// Writes into the provided buffer and returns the count.
    pub fn topGroups(self: *const GroupTable, out: []TopGroupEntry) u32 {
        var count: u32 = 0;

        // Collect all active groups.
        for (self.groups, 0..) |slot, i| {
            if (slot) |group| {
                if (!group.active) continue;
                if (count < out.len) {
                    out[count] = .{
                        .index = @intCast(i),
                        .score = group.score,
                        .template_hash = group.template_hash,
                    };
                    count += 1;
                } else {
                    // Replace the lowest-score entry if this one is higher.
                    var min_idx: u32 = 0;
                    for (out[0..count], 0..) |e, j| {
                        if (e.score < out[min_idx].score) min_idx = @intCast(j);
                    }
                    if (group.score > out[min_idx].score) {
                        out[min_idx] = .{
                            .index = @intCast(i),
                            .score = group.score,
                            .template_hash = group.template_hash,
                        };
                    }
                }
            }
        }

        // Sort by score descending.
        if (count > 1) {
            std.mem.sort(TopGroupEntry, out[0..count], {}, struct {
                fn cmp(_: void, a: TopGroupEntry, b: TopGroupEntry) bool {
                    return a.score > b.score;
                }
            }.cmp);
        }

        return count;
    }

    pub const TopGroupEntry = struct {
        index: u32,
        score: f64,
        template_hash: u64,
    };

    // --- Internal ---

    fn findGroup(self: *GroupTable, template_hash: u64) ?*EventGroup {
        const start = @as(u32, @intCast(template_hash % index_size));
        var probe = start;
        for (0..index_size) |_| {
            const entry = &self.index[probe];
            if (!entry.occupied) return null;
            if (entry.template_hash == template_hash) {
                if (self.groups[entry.group_idx]) |*g| {
                    if (g.active) return g;
                }
            }
            probe = (probe + 1) % index_size;
        }
        return null;
    }

    fn findEmptySlot(self: *const GroupTable) ?u32 {
        for (self.groups, 0..) |slot, i| {
            if (slot == null) return @intCast(i);
        }
        return null;
    }

    fn evict(self: *GroupTable) u32 {
        var min_score: f64 = std.math.floatMax(f64);
        var min_idx: u32 = 0;
        for (self.groups, 0..) |slot, i| {
            if (slot) |group| {
                if (group.active and group.score < min_score) {
                    min_score = group.score;
                    min_idx = @intCast(i);
                }
            }
        }
        // Remove from index.
        if (self.groups[min_idx]) |group| {
            self.indexRemove(group.template_hash);
        }
        self.groups[min_idx] = null;
        self.group_count -= 1;
        return min_idx;
    }

    fn indexInsert(self: *GroupTable, template_hash: u64, group_idx: u32) void {
        const start = @as(u32, @intCast(template_hash % index_size));
        var probe = start;
        for (0..index_size) |_| {
            if (!self.index[probe].occupied) {
                self.index[probe] = .{
                    .template_hash = template_hash,
                    .group_idx = group_idx,
                    .occupied = true,
                };
                return;
            }
            probe = (probe + 1) % index_size;
        }
    }

    fn indexRemove(self: *GroupTable, template_hash: u64) void {
        const start = @as(u32, @intCast(template_hash % index_size));
        var probe = start;
        for (0..index_size) |_| {
            if (!self.index[probe].occupied) return;
            if (self.index[probe].template_hash == template_hash) {
                self.index[probe] = .{};
                return;
            }
            probe = (probe + 1) % index_size;
        }
    }
};

/// Compute group ranking score.
pub fn computeScore(group: *const EventGroup, now_ns: i128) f64 {
    // Recency: exponential decay, halflife 30s.
    const age_s = @as(f64, @floatFromInt(@max(@as(i128, 0), now_ns - group.last_seen_ns))) / 1e9;
    const recency = @exp(-age_s / 30.0);

    // Frequency: log-scaled count in short window.
    const freq = @log2(@as(f64, @floatFromInt(group.count_short + 1)));

    // Severity weight.
    const sev_weight: f64 = switch (group.severity) {
        .trace => 0.1,
        .debug => 0.2,
        .info => 0.5,
        .warn => 2.0,
        .err => 5.0,
        .fatal => 10.0,
        .unknown => 0.3,
    };

    // Trend multiplier.
    const trend_mult: f64 = switch (group.trend) {
        .rising => 2.0,
        .new_group => 1.5,
        .stable => 1.0,
        .falling => 0.7,
        .gone => 0.1,
    };

    // Source spread.
    const spread = @log2(@as(f64, @floatFromInt(group.sources.count() + 1)));

    return recency * freq * sev_weight * trend_mult * spread;
}

/// Compute trend from window counts.
pub fn computeTrend(group: *const EventGroup) Trend {
    if (group.count_prev_short == 0 and group.count_short == 0) return .gone;
    if (group.count_prev_short == 0) return .new_group;
    const ratio = @as(f64, @floatFromInt(group.count_short)) /
        @as(f64, @floatFromInt(group.count_prev_short));
    if (ratio > 1.5) return .rising;
    if (ratio < 0.67) return .falling;
    return .stable;
}

test "source set basic operations" {
    var ss = SourceSet{};
    try std.testing.expectEqual(@as(u16, 0), ss.count());

    ss.set(0);
    ss.set(5);
    ss.set(100);

    try std.testing.expect(ss.contains(0));
    try std.testing.expect(ss.contains(5));
    try std.testing.expect(ss.contains(100));
    try std.testing.expect(!ss.contains(1));
    try std.testing.expectEqual(@as(u16, 3), ss.count());
}

test "group table basic grouping" {
    const Timestamp = core.Timestamp;
    var table = GroupTable{};

    // Create 100 events with the same template_hash.
    for (0..100) |i| {
        var event = Event.shell("test line", 0, Timestamp{ .nanos = @intCast(i * 1000), .seq = @intCast(i) }, 0);
        event.template_hash = 12345;
        _ = table.classify(&event);
    }

    try std.testing.expectEqual(@as(u32, 1), table.group_count);
    const group = table.findGroup(12345).?;
    try std.testing.expectEqual(@as(u64, 100), group.count);
}

test "group table multi-template" {
    const Timestamp = core.Timestamp;
    var table = GroupTable{};

    // 3 distinct templates, 50 events each.
    for (0..3) |t| {
        for (0..50) |i| {
            var event = Event.shell("line", 0, Timestamp{ .nanos = @intCast(i * 1000), .seq = @intCast(t * 50 + i) }, 0);
            event.template_hash = @as(u64, @intCast(t + 1)) * 1000;
            _ = table.classify(&event);
        }
    }

    try std.testing.expectEqual(@as(u32, 3), table.group_count);
}

test "group table trend detection" {
    try std.testing.expectEqual(Trend.gone, computeTrend(&EventGroup{ .template_hash = 1, .count_short = 0, .count_prev_short = 0 }));
    try std.testing.expectEqual(Trend.new_group, computeTrend(&EventGroup{ .template_hash = 1, .count_short = 10, .count_prev_short = 0 }));
    try std.testing.expectEqual(Trend.rising, computeTrend(&EventGroup{ .template_hash = 1, .count_short = 30, .count_prev_short = 10 }));
    try std.testing.expectEqual(Trend.falling, computeTrend(&EventGroup{ .template_hash = 1, .count_short = 10, .count_prev_short = 30 }));
    try std.testing.expectEqual(Trend.stable, computeTrend(&EventGroup{ .template_hash = 1, .count_short = 20, .count_prev_short = 22 }));
}

test "group table scoring favors error over info" {
    var error_group = EventGroup{ .template_hash = 1, .severity = .err, .count_short = 10, .count_prev_short = 5, .last_seen_ns = 1000, .trend = .rising };
    error_group.sources.set(0);
    var info_group = EventGroup{ .template_hash = 2, .severity = .info, .count_short = 10, .count_prev_short = 15, .last_seen_ns = 1000, .trend = .falling };
    info_group.sources.set(0);

    const error_score = computeScore(&error_group, 1000);
    const info_score = computeScore(&info_group, 1000);
    try std.testing.expect(error_score > info_score);
}

test "group table window rotation" {
    const Timestamp = core.Timestamp;
    var table = GroupTable{};

    // Add events.
    for (0..10) |i| {
        var event = Event.shell("test", 0, Timestamp{ .nanos = @intCast(i * 1000), .seq = @intCast(i) }, 0);
        event.template_hash = 999;
        _ = table.classify(&event);
    }

    const group = table.findGroup(999).?;
    try std.testing.expectEqual(@as(u32, 10), group.count_short);

    // Rotate window.
    table.windowRotate(100_000);

    try std.testing.expectEqual(@as(u32, 0), group.count_short);
    try std.testing.expectEqual(@as(u32, 10), group.count_prev_short);
}

test "group table top groups" {
    const Timestamp = core.Timestamp;
    var table = GroupTable{};

    // Create groups with different severities.
    var e1 = Event.shell("error line", 0, Timestamp{ .nanos = 1000, .seq = 0 }, 0);
    e1.template_hash = 100;
    e1.severity = .err;
    _ = table.classify(&e1);

    var e2 = Event.shell("info line", 0, Timestamp{ .nanos = 1000, .seq = 1 }, 0);
    e2.template_hash = 200;
    e2.severity = .info;
    _ = table.classify(&e2);

    var top: [10]GroupTable.TopGroupEntry = undefined;
    const count = table.topGroups(&top);
    try std.testing.expectEqual(@as(u32, 2), count);
    // Error group should rank first.
    const first = table.groups[top[0].index].?;
    try std.testing.expectEqual(Severity.err, first.severity);
}
