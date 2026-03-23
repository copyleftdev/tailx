const std = @import("std");
const core = @import("../core.zig");

const FieldMap = core.field.FieldMap;
const FieldValue = core.field.FieldValue;

/// Inferred field type.
pub const FieldType = enum {
    string,
    int,
    float,
    boolean,
    mixed,
};

/// A field discovered during schema inference.
pub const SchemaField = struct {
    key: [64]u8 = undefined,
    key_len: u8 = 0,
    predominant_type: FieldType = .string,
    occurrences: u32 = 0,
    type_counts: [4]u32 = [_]u32{0} ** 4, // string, int, float, bool

    pub fn getKey(self: *const SchemaField) []const u8 {
        return self.key[0..self.key_len];
    }

    pub fn frequency(self: *const SchemaField, total: u32) f32 {
        if (total == 0) return 0;
        return @as(f32, @floatFromInt(self.occurrences)) / @as(f32, @floatFromInt(total));
    }
};

/// Infers schema from the first N events of a source.
/// Tracks field names, types, and frequencies.
pub const SchemaInferer = struct {
    fields: [max_fields]SchemaField = [_]SchemaField{.{}} ** max_fields,
    field_count: u16 = 0,
    total_events: u32 = 0,
    locked: bool = false,

    const max_fields = 128;
    const sample_target = 64;

    /// Feed an event's fields into the inferer.
    pub fn feed(self: *SchemaInferer, field_map: FieldMap) void {
        if (self.locked) return;

        self.total_events += 1;

        for (field_map.fields) |field| {
            const slot = self.getOrCreate(field.key) orelse continue;
            slot.occurrences += 1;

            switch (field.value) {
                .string => slot.type_counts[0] += 1,
                .int => slot.type_counts[1] += 1,
                .float => slot.type_counts[2] += 1,
                .boolean => slot.type_counts[3] += 1,
                .null_val => {},
            }

            // Update predominant type.
            var max_count: u32 = 0;
            var max_idx: u8 = 0;
            for (slot.type_counts, 0..) |count, i| {
                if (count > max_count) {
                    max_count = count;
                    max_idx = @intCast(i);
                }
            }
            slot.predominant_type = switch (max_idx) {
                0 => .string,
                1 => .int,
                2 => .float,
                3 => .boolean,
                else => .mixed,
            };
        }

        if (self.total_events >= sample_target) {
            self.locked = true;
        }
    }

    /// Get stable fields (appear in >80% of events).
    pub fn stableFieldCount(self: *const SchemaInferer) u16 {
        var count: u16 = 0;
        for (self.fields[0..self.field_count]) |field| {
            if (field.frequency(self.total_events) > 0.8) count += 1;
        }
        return count;
    }

    /// Check if a field name is numeric (int or float).
    pub fn isNumeric(self: *const SchemaInferer, key: []const u8) bool {
        for (self.fields[0..self.field_count]) |field| {
            if (std.mem.eql(u8, field.getKey(), key)) {
                return field.predominant_type == .int or field.predominant_type == .float;
            }
        }
        return false;
    }

    fn getOrCreate(self: *SchemaInferer, key: []const u8) ?*SchemaField {
        // Lookup existing.
        for (self.fields[0..self.field_count]) |*field| {
            if (std.mem.eql(u8, field.getKey(), key)) return field;
        }

        // Create new.
        if (self.field_count >= max_fields) return null;
        const copy_len: u8 = @intCast(@min(key.len, 64));
        var field = &self.fields[self.field_count];
        @memcpy(field.key[0..copy_len], key[0..copy_len]);
        field.key_len = copy_len;
        self.field_count += 1;
        return field;
    }
};

test "schema inferer basic" {
    const Field = core.field.Field;

    var inferer = SchemaInferer{};

    // Feed 10 events with consistent fields.
    for (0..10) |_| {
        const fields = [_]Field{
            .{ .key = "status", .value = .{ .int = 200 } },
            .{ .key = "latency", .value = .{ .float = 0.042 } },
            .{ .key = "path", .value = .{ .string = "/api" } },
        };
        inferer.feed(FieldMap{ .fields = &fields });
    }

    try std.testing.expectEqual(@as(u16, 3), inferer.field_count);
    try std.testing.expectEqual(@as(u32, 10), inferer.total_events);
    try std.testing.expect(inferer.isNumeric("status"));
    try std.testing.expect(inferer.isNumeric("latency"));
    try std.testing.expect(!inferer.isNumeric("path"));
}

test "schema inferer locks after sample target" {
    var inferer = SchemaInferer{};
    const Field = core.field.Field;

    for (0..64) |_| {
        const fields = [_]Field{
            .{ .key = "x", .value = .{ .int = 1 } },
        };
        inferer.feed(FieldMap{ .fields = &fields });
    }

    try std.testing.expect(inferer.locked);

    // Further feeds should be ignored.
    const fields2 = [_]Field{
        .{ .key = "new_field", .value = .{ .string = "test" } },
    };
    inferer.feed(FieldMap{ .fields = &fields2 });
    try std.testing.expectEqual(@as(u16, 1), inferer.field_count); // still 1, not 2
}

test "schema inferer stable fields" {
    var inferer = SchemaInferer{};
    const Field = core.field.Field;

    for (0..10) |i| {
        if (i < 9) {
            // "status" appears 9/10 times (90%)
            const fields = [_]Field{
                .{ .key = "status", .value = .{ .int = 200 } },
                .{ .key = "rare", .value = .{ .string = "x" } },
            };
            inferer.feed(FieldMap{ .fields = &fields });
        } else {
            // Last event only has "rare"
            const fields = [_]Field{
                .{ .key = "rare", .value = .{ .string = "x" } },
            };
            inferer.feed(FieldMap{ .fields = &fields });
        }
    }

    // "status" appears 9/10 = 90%, "rare" appears 10/10 = 100%. Both > 80%.
    try std.testing.expectEqual(@as(u16, 2), inferer.stableFieldCount());
}
