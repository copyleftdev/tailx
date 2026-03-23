const std = @import("std");
const core = @import("../core.zig");

const Event = core.Event;
const EventRing = core.EventRing;
const ArenaPool = core.ArenaPool;
const Timestamp = core.Timestamp;
const SourceId = core.source.SourceId;

/// Merges raw lines into Event shells in the EventRing.
/// Assigns monotonic sequence numbers and arena-duplicates raw data.
pub const Merger = struct {
    seq_counter: u64,
    ring: *EventRing,
    arena_pool: *ArenaPool,
    drop_count: u64,

    pub fn init(ring: *EventRing, arena_pool: *ArenaPool) Merger {
        return .{
            .seq_counter = 0,
            .ring = ring,
            .arena_pool = arena_pool,
            .drop_count = 0,
        };
    }

    /// Ingest a raw line into the ring as an Event shell.
    /// On arena OOM, the event is dropped and drop_count incremented.
    pub fn ingest(
        self: *Merger,
        raw: []const u8,
        timestamp_nanos: i128,
        source_id: SourceId,
    ) void {
        const arena = self.arena_pool.current();
        const owned_raw = arena.dupeString(raw) catch {
            self.drop_count += 1;
            return;
        };

        const event = Event.shell(
            owned_raw,
            source_id,
            Timestamp{ .nanos = timestamp_nanos, .seq = self.seq_counter },
            arena.generation,
        );

        self.ring.push(event);
        self.seq_counter +%= 1;
    }
};

test "merger ingest creates event shells" {
    const allocator = std.testing.allocator;

    var ring = try EventRing.init(allocator, 16);
    defer ring.deinit(allocator);

    var pool = ArenaPool.init(allocator, 60 * std.time.ns_per_s);
    defer pool.deinit();

    var merger = Merger.init(&ring, &pool);

    merger.ingest("2024-03-15 ERROR something broke", 1710510181_000_000_000, 0);
    merger.ingest("2024-03-15 INFO all good", 1710510182_000_000_000, 1);

    try std.testing.expectEqual(@as(usize, 2), ring.len());
    try std.testing.expectEqual(@as(u64, 2), merger.seq_counter);

    const e0 = ring.get(0).?;
    try std.testing.expectEqualStrings("2024-03-15 ERROR something broke", e0.raw);
    try std.testing.expectEqual(@as(SourceId, 0), e0.source);
    try std.testing.expectEqual(@as(u64, 0), e0.timestamp.seq);
    try std.testing.expectEqual(core.Severity.unknown, e0.severity);

    const e1 = ring.get(1).?;
    try std.testing.expectEqualStrings("2024-03-15 INFO all good", e1.raw);
    try std.testing.expectEqual(@as(SourceId, 1), e1.source);
    try std.testing.expectEqual(@as(u64, 1), e1.timestamp.seq);
}

test "merger sequence wraps correctly" {
    const allocator = std.testing.allocator;

    var ring = try EventRing.init(allocator, 4);
    defer ring.deinit(allocator);

    var pool = ArenaPool.init(allocator, 60 * std.time.ns_per_s);
    defer pool.deinit();

    var merger = Merger.init(&ring, &pool);

    // Push enough events to wrap the ring.
    for (0..6) |i| {
        merger.ingest("line", @intCast(i * 1000), 0);
    }

    try std.testing.expectEqual(@as(u64, 6), merger.seq_counter);
    try std.testing.expectEqual(@as(usize, 4), ring.len());

    // Oldest should be index 2 (first two overwritten).
    const oldest = ring.get(ring.oldest()).?;
    try std.testing.expectEqual(@as(u64, 2), oldest.timestamp.seq);
}

test "merger drop count on arena failure" {
    const allocator = std.testing.allocator;

    var ring = try EventRing.init(allocator, 4);
    defer ring.deinit(allocator);

    var pool = ArenaPool.init(allocator, 60 * std.time.ns_per_s);
    defer pool.deinit();

    var merger = Merger.init(&ring, &pool);

    // Normal ingest should work.
    merger.ingest("test", 0, 0);
    try std.testing.expectEqual(@as(u64, 0), merger.drop_count);
    try std.testing.expectEqual(@as(usize, 1), ring.len());
}
