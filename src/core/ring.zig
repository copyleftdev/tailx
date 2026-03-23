const std = @import("std");
const Event = @import("event.zig").Event;

pub const EventRing = struct {
    buffer: []Event,
    capacity: usize,
    write_pos: usize,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !EventRing {
        // Round up to power of 2 for fast modular indexing.
        const cap = std.math.ceilPowerOfTwo(usize, capacity) catch capacity;
        const buffer = try allocator.alloc(Event, cap);
        return .{
            .buffer = buffer,
            .capacity = cap,
            .write_pos = 0,
        };
    }

    pub fn deinit(self: *EventRing, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
        self.* = undefined;
    }

    pub fn push(self: *EventRing, event: Event) void {
        self.buffer[self.write_pos & (self.capacity - 1)] = event;
        self.write_pos +%= 1;
    }

    pub fn get(self: *const EventRing, idx: usize) ?Event {
        if (self.write_pos == 0) return null;
        if (idx >= self.write_pos) return null;
        if (self.write_pos - idx > self.capacity) return null; // overwritten
        return self.buffer[idx & (self.capacity - 1)];
    }

    pub fn getPtr(self: *EventRing, idx: usize) ?*Event {
        if (self.write_pos == 0) return null;
        if (idx >= self.write_pos) return null;
        if (self.write_pos - idx > self.capacity) return null;
        return &self.buffer[idx & (self.capacity - 1)];
    }

    /// Number of events currently in the ring (up to capacity).
    pub fn len(self: *const EventRing) usize {
        return @min(self.write_pos, self.capacity);
    }

    /// Oldest valid index.
    pub fn oldest(self: *const EventRing) usize {
        if (self.write_pos <= self.capacity) return 0;
        return self.write_pos - self.capacity;
    }

    /// Most recent index (write_pos - 1), or null if empty.
    pub fn newest(self: *const EventRing) ?usize {
        if (self.write_pos == 0) return null;
        return self.write_pos - 1;
    }

    /// Iterate events from index `start` to `end` (exclusive).
    pub fn iterator(self: *const EventRing, start: usize, end: usize) Iterator {
        return .{
            .ring = self,
            .pos = start,
            .end = end,
        };
    }

    /// Iterate all valid events from oldest to newest.
    pub fn iterAll(self: *const EventRing) Iterator {
        return self.iterator(self.oldest(), self.write_pos);
    }

    pub const Iterator = struct {
        ring: *const EventRing,
        pos: usize,
        end: usize,

        pub fn next(self: *Iterator) ?Event {
            if (self.pos >= self.end) return null;
            const event = self.ring.get(self.pos);
            self.pos += 1;
            return event;
        }
    };
};

test "ring buffer push and get" {
    const Timestamp = @import("timestamp.zig").Timestamp;
    const allocator = std.testing.allocator;

    var ring = try EventRing.init(allocator, 4);
    defer ring.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), ring.capacity);
    try std.testing.expectEqual(@as(usize, 0), ring.len());

    // Push 3 events.
    for (0..3) |i| {
        const raw = "test line";
        ring.push(Event.shell(raw, 0, Timestamp{ .nanos = @intCast(i), .seq = 0 }, 0));
    }
    try std.testing.expectEqual(@as(usize, 3), ring.len());
    try std.testing.expectEqual(@as(i128, 0), ring.get(0).?.timestamp.nanos);
    try std.testing.expectEqual(@as(i128, 2), ring.get(2).?.timestamp.nanos);
}

test "ring buffer wraparound" {
    const Timestamp = @import("timestamp.zig").Timestamp;
    const allocator = std.testing.allocator;

    var ring = try EventRing.init(allocator, 4);
    defer ring.deinit(allocator);

    // Push 6 events into a 4-slot ring → first 2 are overwritten.
    for (0..6) |i| {
        ring.push(Event.shell("line", 0, Timestamp{ .nanos = @intCast(i * 100), .seq = 0 }, 0));
    }

    try std.testing.expectEqual(@as(usize, 4), ring.len());
    try std.testing.expectEqual(@as(?Event, null), ring.get(0)); // overwritten
    try std.testing.expectEqual(@as(?Event, null), ring.get(1)); // overwritten
    try std.testing.expectEqual(@as(i128, 200), ring.get(2).?.timestamp.nanos);
    try std.testing.expectEqual(@as(i128, 500), ring.get(5).?.timestamp.nanos);
    try std.testing.expectEqual(@as(usize, 2), ring.oldest());
    try std.testing.expectEqual(@as(usize, 5), ring.newest().?);
}

test "ring buffer iteration" {
    const Timestamp = @import("timestamp.zig").Timestamp;
    const allocator = std.testing.allocator;

    var ring = try EventRing.init(allocator, 8);
    defer ring.deinit(allocator);

    for (0..5) |i| {
        ring.push(Event.shell("line", 0, Timestamp{ .nanos = @intCast(i), .seq = 0 }, 0));
    }

    var it = ring.iterAll();
    var count: usize = 0;
    while (it.next()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), count);
}
