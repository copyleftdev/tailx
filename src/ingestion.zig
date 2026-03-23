// Ingestion Layer — Spec 1: Source Drivers, Line Splitting, Merge & Sequencing

pub const read_buffer = @import("ingestion/read_buffer.zig");
pub const quick_timestamp = @import("ingestion/quick_timestamp.zig");
pub const merger = @import("ingestion/merger.zig");
pub const event_loop = @import("ingestion/event_loop.zig");

pub const ReadBuffer = read_buffer.ReadBuffer;
pub const QuickTimestamp = quick_timestamp.QuickTimestamp;
pub const Merger = merger.Merger;
pub const Poller = event_loop.Poller;

test {
    @import("std").testing.refAllDecls(@This());
}
