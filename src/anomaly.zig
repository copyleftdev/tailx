// Anomaly Detection — Spec 6

pub const detectors = @import("anomaly/detectors.zig");

pub const RateDetector = detectors.RateDetector;
pub const CusumDetector = detectors.CusumDetector;
pub const DetectorResult = detectors.DetectorResult;
pub const DetectorKind = detectors.DetectorKind;
pub const AnomalyAlert = detectors.AnomalyAlert;
pub const AlertState = detectors.AlertState;
pub const SignalAggregator = detectors.SignalAggregator;

test {
    @import("std").testing.refAllDecls(@This());
}
