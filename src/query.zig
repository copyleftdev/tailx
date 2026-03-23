// Query & Filter Interface — Spec 8

pub const filter = @import("query/filter.zig");
pub const intent = @import("query/intent.zig");

pub const FilterPredicate = filter.FilterPredicate;
pub const SubstringSearcher = filter.SubstringSearcher;
pub const IntentParser = intent.IntentParser;

test {
    @import("std").testing.refAllDecls(@This());
}
