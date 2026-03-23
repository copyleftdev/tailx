const std = @import("std");

pub const EventArena = struct {
    arena: std.heap.ArenaAllocator,
    generation: u32,
    created_ns: i128,

    pub fn init(backing: std.mem.Allocator, generation: u32, now_ns: i128) EventArena {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .generation = generation,
            .created_ns = now_ns,
        };
    }

    pub fn deinit(self: *EventArena) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *EventArena) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Duplicate a string into this arena.
    pub fn dupeString(self: *EventArena, s: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, s);
    }

    /// Allocate a slice of type T.
    pub fn alloc(self: *EventArena, comptime T: type, n: usize) ![]T {
        return self.arena.allocator().alloc(T, n);
    }
};

pub const ArenaPool = struct {
    arenas: [max_generations]?EventArena = [_]?EventArena{null} ** max_generations,
    current_gen: u32 = 0,
    window_duration_ns: i128,
    backing: std.mem.Allocator,

    pub const max_generations = 16;

    pub fn init(backing: std.mem.Allocator, window_duration_ns: i128) ArenaPool {
        var pool = ArenaPool{
            .window_duration_ns = window_duration_ns,
            .backing = backing,
        };
        pool.arenas[0] = EventArena.init(backing, 0, 0);
        return pool;
    }

    pub fn deinit(self: *ArenaPool) void {
        for (&self.arenas) |*slot| {
            if (slot.*) |*arena| {
                arena.deinit();
                slot.* = null;
            }
        }
    }

    pub fn current(self: *ArenaPool) *EventArena {
        return &(self.arenas[self.current_gen % max_generations].?);
    }

    /// Rotate to a new generation if the current arena has exceeded its window.
    pub fn maybeRotate(self: *ArenaPool, now_ns: i128) bool {
        const cur = self.current();
        if (now_ns - cur.created_ns >= self.window_duration_ns) {
            self.current_gen += 1;
            const slot = self.current_gen % max_generations;

            // Free the old arena in this slot if it exists.
            if (self.arenas[slot]) |*old| {
                old.deinit();
            }

            self.arenas[slot] = EventArena.init(self.backing, self.current_gen, now_ns);
            return true;
        }
        return false;
    }

    /// Free arenas older than the given generation.
    pub fn gc(self: *ArenaPool, oldest_gen_in_use: u32) void {
        for (&self.arenas) |*slot| {
            if (slot.*) |*arena| {
                if (arena.generation < oldest_gen_in_use) {
                    arena.deinit();
                    slot.* = null;
                }
            }
        }
    }
};

test "event arena dupe string" {
    var arena = EventArena.init(std.testing.allocator, 0, 0);
    defer arena.deinit();

    const original = "hello world";
    const duped = try arena.dupeString(original);
    try std.testing.expectEqualStrings(original, duped);
    // Verify it's a different pointer (independent copy).
    try std.testing.expect(duped.ptr != original.ptr);
}

test "arena pool rotation" {
    var pool = ArenaPool.init(std.testing.allocator, 1000); // 1000ns window
    defer pool.deinit();

    try std.testing.expectEqual(@as(u32, 0), pool.current().generation);

    // Not enough time passed — no rotation.
    try std.testing.expect(!pool.maybeRotate(500));
    try std.testing.expectEqual(@as(u32, 0), pool.current().generation);

    // Enough time passed — rotate.
    try std.testing.expect(pool.maybeRotate(1500));
    try std.testing.expectEqual(@as(u32, 1), pool.current().generation);
}
