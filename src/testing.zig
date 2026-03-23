// Golden test dataset — deterministic, full-spectrum assertions.

pub const golden = @import("testing/golden.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
