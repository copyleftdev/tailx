const std = @import("std");
const core = @import("../core.zig");

const Event = core.Event;
const Timestamp = core.Timestamp;
const Severity = core.Severity;
const SourceId = core.source.SourceId;

/// How a trace was constructed.
pub const TraceOrigin = enum { explicit, heuristic, mixed };

/// Current state of a trace.
pub const TraceState = enum { active, finalized };

/// Outcome of a trace.
pub const TraceOutcome = enum { success, failure, timeout, unknown };

/// Trace identifier — either extracted from logs or synthetically generated.
pub const TraceId = union(enum) {
    explicit: [36]u8,
    synthetic: u64,

    pub fn fromString(s: []const u8) TraceId {
        var id = TraceId{ .explicit = [_]u8{0} ** 36 };
        const copy_len = @min(s.len, 36);
        @memcpy(id.explicit[0..copy_len], s[0..copy_len]);
        return id;
    }

    /// Write the trace ID into a buffer for display. Returns the valid slice.
    pub fn writeTo(self: *const TraceId, buf: *[36]u8) []const u8 {
        switch (self.*) {
            .explicit => |v| {
                @memcpy(buf, &v);
                var len: usize = 36;
                while (len > 0 and buf[len - 1] == 0) len -= 1;
                return buf[0..len];
            },
            .synthetic => {
                const n = std.fmt.formatIntBuf(buf, @as(u64, switch (self.*) {
                    .synthetic => |sv| sv,
                    else => 0,
                }), 10, .lower, .{});
                return buf[0..n];
            },
        }
    }

    /// Get a displayable slice — CAUTION: only safe while self is alive and pinned.
    pub fn display(self: *const TraceId) []const u8 {
        // For explicit IDs, we need to reach into the union storage.
        // This is safe because self is const and pinned.
        switch (self.*) {
            .explicit => {
                // Use pointer arithmetic to get at the actual stored bytes.
                const ptr: [*]const u8 = @ptrCast(self);
                // Find length (trim trailing zeros).
                var len: usize = 36;
                while (len > 0 and ptr[len - 1] == 0) len -= 1;
                return ptr[0..len];
            },
            .synthetic => return "synthetic",
        }
    }

    pub fn hash(self: TraceId) u64 {
        return switch (self) {
            .explicit => |v| std.hash.Wyhash.hash(0, &v),
            .synthetic => |v| std.hash.Wyhash.hash(0, std.mem.asBytes(&v)),
        };
    }

    pub fn eql(a: TraceId, b: TraceId) bool {
        return switch (a) {
            .explicit => |va| switch (b) {
                .explicit => |vb| std.mem.eql(u8, &va, &vb),
                else => false,
            },
            .synthetic => |va| switch (b) {
                .synthetic => |vb| va == vb,
                else => false,
            },
        };
    }
};

/// Reference to an event in the ring buffer.
pub const EventRef = struct {
    ring_idx: usize,
    timestamp_nanos: i128,
    source: SourceId,
    severity: Severity,
};

/// A reconstructed request flow.
pub const Trace = struct {
    id: TraceId,
    origin: TraceOrigin,
    event_refs: [max_events]EventRef = undefined,
    event_count: u16 = 0,
    state: TraceState = .active,
    start_ns: i128 = 0,
    last_event_ns: i128 = 0,
    outcome: TraceOutcome = .unknown,
    confidence: f32 = 1.0,

    const max_events = 64;

    /// Add an event reference to this trace.
    pub fn addEvent(self: *Trace, ref: EventRef) bool {
        if (self.event_count >= max_events) return false;
        self.event_refs[self.event_count] = ref;
        self.event_count += 1;

        if (self.event_count == 1) {
            self.start_ns = ref.timestamp_nanos;
        }
        self.last_event_ns = @max(self.last_event_ns, ref.timestamp_nanos);

        // Escalate outcome on error/fatal.
        if (ref.severity.numeric() >= Severity.err.numeric()) {
            self.outcome = .failure;
        }
        return true;
    }

    /// Duration from first to last event.
    pub fn durationNs(self: *const Trace) i128 {
        if (self.event_count < 2) return 0;
        return self.last_event_ns - self.start_ns;
    }
};

/// Store of active and finalized traces.
pub const TraceStore = struct {
    active: [max_active]?Trace = [_]?Trace{null} ** max_active,
    active_count: u32 = 0,

    finalized: [max_finalized]?Trace = [_]?Trace{null} ** max_finalized,
    finalized_head: u32 = 0,
    finalized_count: u32 = 0,

    expiry_ns: i128,
    next_synthetic: u64 = 1,

    /// Max active traces. Sized for stack allocation.
    /// Production use should heap-allocate for larger sizes.
    const max_active = 256;
    const max_finalized = 512;

    pub fn init(expiry_ns: i128) TraceStore {
        return .{ .expiry_ns = expiry_ns };
    }

    /// Get or create a trace for the given ID.
    pub fn getOrCreate(self: *TraceStore, id: TraceId) ?*Trace {
        // Lookup existing.
        for (&self.active) |*slot| {
            if (slot.*) |*trace| {
                if (trace.state == .active and TraceId.eql(trace.id, id)) {
                    return trace;
                }
            }
        }

        // Create new.
        for (&self.active) |*slot| {
            if (slot.* == null) {
                slot.* = Trace{ .id = id, .origin = .explicit };
                self.active_count += 1;
                return &(slot.*.?);
            }
        }

        return null; // full
    }

    /// Assign an event with an explicit trace ID.
    pub fn assignExplicit(self: *TraceStore, event: *const Event, ring_idx: usize) void {
        const trace_id_str = event.trace_id orelse return;
        const id = TraceId.fromString(trace_id_str);
        const trace = self.getOrCreate(id) orelse return;

        const ref = EventRef{
            .ring_idx = ring_idx,
            .timestamp_nanos = event.timestamp.nanos,
            .source = event.source,
            .severity = event.severity,
        };

        _ = trace.addEvent(ref);
    }

    /// Generate a new synthetic trace ID.
    pub fn nextSyntheticId(self: *TraceStore) TraceId {
        const id = TraceId{ .synthetic = self.next_synthetic };
        self.next_synthetic += 1;
        return id;
    }

    /// Sweep expired active traces into finalized.
    pub fn expireSweep(self: *TraceStore, now_ns: i128) u32 {
        var expired: u32 = 0;
        for (&self.active) |*slot| {
            if (slot.*) |*trace| {
                if (trace.state == .active and
                    now_ns - trace.last_event_ns > self.expiry_ns)
                {
                    trace.state = .finalized;
                    self.finalize(trace.*);
                    slot.* = null;
                    self.active_count -= 1;
                    expired += 1;
                }
            }
        }
        return expired;
    }

    fn finalize(self: *TraceStore, trace: Trace) void {
        self.finalized[self.finalized_head % max_finalized] = trace;
        self.finalized_head += 1;
        if (self.finalized_count < max_finalized) {
            self.finalized_count += 1;
        }
    }

    /// Count of active traces.
    pub fn activeTraceCount(self: *const TraceStore) u32 {
        return self.active_count;
    }

    /// Count of finalized traces.
    pub fn finalizedTraceCount(self: *const TraceStore) u32 {
        return self.finalized_count;
    }
};

test "trace add events and duration" {
    var trace = Trace{ .id = TraceId{ .synthetic = 1 }, .origin = .explicit };

    try std.testing.expect(trace.addEvent(.{
        .ring_idx = 0,
        .timestamp_nanos = 1000,
        .source = 0,
        .severity = .info,
    }));
    try std.testing.expect(trace.addEvent(.{
        .ring_idx = 1,
        .timestamp_nanos = 5000,
        .source = 0,
        .severity = .info,
    }));

    try std.testing.expectEqual(@as(u16, 2), trace.event_count);
    try std.testing.expectEqual(@as(i128, 4000), trace.durationNs());
    try std.testing.expectEqual(TraceOutcome.unknown, trace.outcome);
}

test "trace outcome escalation" {
    var trace = Trace{ .id = TraceId{ .synthetic = 1 }, .origin = .explicit };

    _ = trace.addEvent(.{ .ring_idx = 0, .timestamp_nanos = 1000, .source = 0, .severity = .info });
    try std.testing.expectEqual(TraceOutcome.unknown, trace.outcome);

    _ = trace.addEvent(.{ .ring_idx = 1, .timestamp_nanos = 2000, .source = 0, .severity = .err });
    try std.testing.expectEqual(TraceOutcome.failure, trace.outcome);
}

test "trace store explicit assignment" {
    var store = TraceStore.init(60 * std.time.ns_per_s);

    var event = core.Event.shell("test line", 0, Timestamp{ .nanos = 1000, .seq = 0 }, 0);
    event.trace_id = "abc123";
    store.assignExplicit(&event, 0);

    try std.testing.expectEqual(@as(u32, 1), store.activeTraceCount());

    // Same trace ID → same trace.
    event.timestamp = Timestamp{ .nanos = 2000, .seq = 1 };
    store.assignExplicit(&event, 1);
    try std.testing.expectEqual(@as(u32, 1), store.activeTraceCount());
}

test "trace store expiry sweep" {
    const ns = std.time.ns_per_s;
    var store = TraceStore.init(10 * ns); // 10s expiry

    var event = core.Event.shell("test", 0, Timestamp{ .nanos = 1 * ns, .seq = 0 }, 0);
    event.trace_id = "trace1";
    store.assignExplicit(&event, 0);
    try std.testing.expectEqual(@as(u32, 1), store.activeTraceCount());

    // Sweep at 5s — not expired yet.
    _ = store.expireSweep(5 * ns);
    try std.testing.expectEqual(@as(u32, 1), store.activeTraceCount());

    // Sweep at 12s — expired.
    const expired = store.expireSweep(12 * ns);
    try std.testing.expectEqual(@as(u32, 1), expired);
    try std.testing.expectEqual(@as(u32, 0), store.activeTraceCount());
    try std.testing.expectEqual(@as(u32, 1), store.finalizedTraceCount());
}

test "trace id equality" {
    const a = TraceId.fromString("abc123");
    const b = TraceId.fromString("abc123");
    const c = TraceId.fromString("xyz789");

    try std.testing.expect(TraceId.eql(a, b));
    try std.testing.expect(!TraceId.eql(a, c));
}
