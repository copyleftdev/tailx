// Stream processing primitives — Spec 3: Statistical Data Structures

pub const count_min_sketch = @import("stats/count_min_sketch.zig");
pub const ewma = @import("stats/ewma.zig");
pub const streaming_stats = @import("stats/streaming_stats.zig");
pub const hyper_log_log = @import("stats/hyper_log_log.zig");
pub const t_digest = @import("stats/t_digest.zig");
pub const time_window = @import("stats/time_window.zig");

pub const CountMinSketch = count_min_sketch.CountMinSketch;
pub const EWMA = ewma.EWMA;
pub const StreamingStats = streaming_stats.StreamingStats;
pub const HyperLogLog = hyper_log_log.HyperLogLog;
pub const TDigest = t_digest.TDigest;
pub const TimeWindow = time_window.TimeWindow;
pub const Bucket = time_window.Bucket;

test {
    @import("std").testing.refAllDecls(@This());
}
