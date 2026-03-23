// Pattern Detection & Grouping — Spec 4

pub const group = @import("pattern/group.zig");
pub const minhash = @import("pattern/minhash.zig");

pub const EventGroup = group.EventGroup;
pub const GroupTable = group.GroupTable;
pub const Trend = group.Trend;
pub const SourceSet = group.SourceSet;
pub const MinHashSignature = minhash.MinHashSignature;

test {
    @import("std").testing.refAllDecls(@This());
}
