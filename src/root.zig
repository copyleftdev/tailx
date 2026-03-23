//! TailX — Live System Cognition Engine
//!
//! A real-time, multi-source, semantically-aware log stream processor.
//! Reimagines `tail` from "show me lines" to "what's happening, what matters, and why?"

const std = @import("std");

pub const core = @import("core.zig");
pub const stats = @import("stats.zig");
pub const ingestion = @import("ingestion.zig");
pub const parsing = @import("parsing.zig");
pub const pattern = @import("pattern.zig");
pub const anomaly = @import("anomaly.zig");
pub const trace = @import("trace.zig");
pub const correlation = @import("correlation.zig");
pub const query = @import("query.zig");
pub const pipeline = @import("pipeline.zig");
pub const render = @import("render.zig");
pub const testing_mod = @import("testing.zig");

// Re-export core types for convenience.
pub const Timestamp = core.Timestamp;
pub const Severity = core.Severity;
pub const Event = core.Event;
pub const EventRing = core.EventRing;
pub const FieldMap = core.FieldMap;
pub const SourceId = core.SourceId;

// Re-export stats types.
pub const CountMinSketch = stats.CountMinSketch;
pub const EWMA = stats.EWMA;
pub const StreamingStats = stats.StreamingStats;
pub const HyperLogLog = stats.HyperLogLog;
pub const TDigest = stats.TDigest;
pub const TimeWindow = stats.TimeWindow;

// Re-export ingestion types.
pub const ReadBuffer = ingestion.ReadBuffer;
pub const QuickTimestamp = ingestion.QuickTimestamp;
pub const Merger = ingestion.Merger;

// Re-export parsing types.
pub const Format = parsing.Format;
pub const FormatDetector = parsing.FormatDetector;
pub const JsonParser = parsing.JsonParser;
pub const KvParser = parsing.KvParser;
pub const FallbackParser = parsing.FallbackParser;
pub const DrainTree = parsing.DrainTree;

// Re-export pattern types.
pub const EventGroup = pattern.EventGroup;
pub const GroupTable = pattern.GroupTable;
pub const Trend = pattern.Trend;
pub const MinHashSignature = pattern.MinHashSignature;

// Re-export anomaly types.
pub const RateDetector = anomaly.RateDetector;
pub const CusumDetector = anomaly.CusumDetector;
pub const AnomalyAlert = anomaly.AnomalyAlert;
pub const SignalAggregator = anomaly.SignalAggregator;

// Re-export trace types.
pub const Trace = trace.Trace;
pub const TraceId = trace.TraceId;
pub const TraceStore = trace.TraceStore;

// Re-export correlation types.
pub const CorrelationSignal = correlation.CorrelationSignal;
pub const Hypothesis = correlation.Hypothesis;
pub const TemporalProximity = correlation.TemporalProximity;

// Re-export query types.
pub const FilterPredicate = query.FilterPredicate;
pub const SubstringSearcher = query.SubstringSearcher;

test {
    std.testing.refAllDecls(@This());
}
