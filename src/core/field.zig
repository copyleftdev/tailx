const std = @import("std");

pub const FieldValue = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
    null_val: void,

    pub fn asFloat(self: FieldValue) ?f64 {
        return switch (self) {
            .float => |v| v,
            .int => |v| @as(f64, @floatFromInt(v)),
            else => null,
        };
    }

    pub fn asString(self: FieldValue) ?[]const u8 {
        return switch (self) {
            .string => |v| v,
            else => null,
        };
    }
};

pub const Field = struct {
    key: []const u8,
    value: FieldValue,
};

pub const FieldMap = struct {
    fields: []const Field,

    pub const empty = FieldMap{ .fields = &.{} };

    /// Linear scan — fine for typical field counts (<50).
    pub fn get(self: FieldMap, key: []const u8) ?FieldValue {
        for (self.fields) |f| {
            if (std.mem.eql(u8, f.key, key)) return f.value;
        }
        return null;
    }

    pub fn getString(self: FieldMap, key: []const u8) ?[]const u8 {
        const val = self.get(key) orelse return null;
        return val.asString();
    }

    pub fn getFloat(self: FieldMap, key: []const u8) ?f64 {
        const val = self.get(key) orelse return null;
        return val.asFloat();
    }

    pub fn len(self: FieldMap) usize {
        return self.fields.len;
    }
};

test "field map get" {
    const fields = [_]Field{
        .{ .key = "status", .value = .{ .int = 200 } },
        .{ .key = "path", .value = .{ .string = "/api" } },
        .{ .key = "latency", .value = .{ .float = 0.123 } },
        .{ .key = "debug", .value = .{ .boolean = true } },
    };
    const map = FieldMap{ .fields = &fields };

    try std.testing.expectEqual(@as(i64, 200), map.get("status").?.int);
    try std.testing.expectEqualStrings("/api", map.getString("path").?);
    try std.testing.expectEqual(@as(f64, 0.123), map.getFloat("latency").?);
    try std.testing.expect(map.get("debug").?.boolean);
    try std.testing.expectEqual(@as(?FieldValue, null), map.get("nonexistent"));
}

test "field value asFloat" {
    const int_val = FieldValue{ .int = 42 };
    try std.testing.expectEqual(@as(f64, 42.0), int_val.asFloat().?);

    const float_val = FieldValue{ .float = 3.14 };
    try std.testing.expectEqual(@as(f64, 3.14), float_val.asFloat().?);

    const str_val = FieldValue{ .string = "hello" };
    try std.testing.expectEqual(@as(?f64, null), str_val.asFloat());
}
