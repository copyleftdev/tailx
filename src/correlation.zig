// Correlation Engine — Spec 7

pub const engine = @import("correlation/engine.zig");

pub const CorrelationSignal = engine.CorrelationSignal;
pub const Hypothesis = engine.Hypothesis;
pub const TemporalProximity = engine.TemporalProximity;
pub const SignalKind = engine.SignalKind;

test {
    @import("std").testing.refAllDecls(@This());
}
