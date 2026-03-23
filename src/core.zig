// Core types for TailX — Spec 0: Event Model & Core Types

pub const timestamp = @import("core/timestamp.zig");
pub const severity = @import("core/severity.zig");
pub const field = @import("core/field.zig");
pub const event = @import("core/event.zig");
pub const source = @import("core/source.zig");
pub const ring = @import("core/ring.zig");
pub const arena = @import("core/arena.zig");

pub const Timestamp = timestamp.Timestamp;
pub const Severity = severity.Severity;
pub const FieldValue = field.FieldValue;
pub const Field = field.Field;
pub const FieldMap = field.FieldMap;
pub const Event = event.Event;
pub const SourceId = source.SourceId;
pub const SourceKind = source.SourceKind;
pub const SourceMeta = source.SourceMeta;
pub const SourceRegistry = source.SourceRegistry;
pub const EventRing = ring.EventRing;
pub const EventArena = arena.EventArena;
pub const ArenaPool = arena.ArenaPool;

test {
    @import("std").testing.refAllDecls(@This());
}
