// Parsing & Schema Inference — Spec 2

pub const format_detector = @import("parsing/format_detector.zig");
pub const json_parser = @import("parsing/json_parser.zig");
pub const kv_parser = @import("parsing/kv_parser.zig");
pub const fallback_parser = @import("parsing/fallback_parser.zig");
pub const syslog_parser = @import("parsing/syslog_parser.zig");
pub const multiline = @import("parsing/multiline.zig");
pub const schema = @import("parsing/schema.zig");
pub const drain = @import("parsing/drain.zig");

pub const Format = format_detector.Format;
pub const FormatDetector = format_detector.FormatDetector;
pub const JsonParser = json_parser.JsonParser;
pub const KvParser = kv_parser.KvParser;
pub const FallbackParser = fallback_parser.FallbackParser;
pub const SyslogBsdParser = syslog_parser.SyslogBsdParser;
pub const MultiLineDetector = multiline.MultiLineDetector;
pub const SchemaInferer = schema.SchemaInferer;
pub const DrainTree = drain.DrainTree;

test {
    @import("std").testing.refAllDecls(@This());
}
