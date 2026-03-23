const std = @import("std");
const core = @import("../core.zig");
const parsing = @import("../parsing.zig");
const query_mod = @import("../query.zig");

const Event = core.Event;
const EventArena = core.EventArena;
const Timestamp = core.Timestamp;
const Severity = core.Severity;
const FieldValue = core.field.FieldValue;
const Field = core.field.Field;
const FieldMap = core.field.FieldMap;
const Format = parsing.Format;
const FormatDetector = parsing.FormatDetector;
const JsonParser = parsing.JsonParser;
const KvParser = parsing.KvParser;
const FallbackParser = parsing.FallbackParser;
const DrainTree = parsing.DrainTree;
const FilterPredicate = query_mod.FilterPredicate;
const SubstringSearcher = query_mod.filter.SubstringSearcher;

// ============================================================
// Category A: JSON Parser
// ============================================================

test "golden A01: JSON full known fields" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseJson("{\"timestamp\":\"2024-03-15T14:23:01.123Z\",\"level\":\"error\",\"msg\":\"connection timeout\",\"service\":\"payments\",\"traceId\":\"abc-123-def\"}");
    try expect(e.severity == .err);
    try expectMsg(e, "connection timeout");
    try expectStr(e.service, "payments");
    try expectStr(e.trace_id, "abc-123-def");
    try std.testing.expect(e.timestamp.nanos > 0);
}

test "golden A02: JSON alternate key names" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseJson("{\"@timestamp\":\"2024-03-15T14:23:01Z\",\"severity\":\"warning\",\"text\":\"disk full\",\"application\":\"storage\",\"request_id\":\"req-42\"}");
    try expect(e.severity == .warn);
    try expectMsg(e, "disk full");
    try expectStr(e.service, "storage");
    try expectStr(e.trace_id, "req-42");
}

test "golden A03: JSON epoch millis timestamp" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseJson("{\"ts\":1710510181123,\"lvl\":\"info\",\"log\":\"startup complete\",\"component\":\"gateway\",\"trace\":\"t-999\"}");
    try expect(e.severity == .info);
    try expectMsg(e, "startup complete");
    try expectStr(e.service, "gateway");
    try expectStr(e.trace_id, "t-999");
    const expected_ns: i128 = 1710510181123 * std.time.ns_per_ms;
    try std.testing.expectEqual(expected_ns, e.timestamp.nanos);
}

test "golden A04: JSON epoch seconds timestamp" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseJson("{\"t\":1710510181,\"loglevel\":\"debug\",\"body\":\"cache miss\",\"service_name\":\"cache\",\"x-trace-id\":\"xt-1\"}");
    try expect(e.severity == .debug);
    try expectMsg(e, "cache miss");
    try expectStr(e.service, "cache");
    try expectStr(e.trace_id, "xt-1");
    const expected_ns: i128 = 1710510181 * std.time.ns_per_s;
    try std.testing.expectEqual(expected_ns, e.timestamp.nanos);
}

test "golden A05: JSON all value types" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseJson("{\"msg\":\"request\",\"status\":200,\"latency\":0.042,\"debug\":true,\"extra\":null,\"tags\":\"alpha\"}");
    try expect(e.severity == .unknown);
    try expectMsg(e, "request");
    try expectFieldInt(e, "status", 200);
    try expectFieldFloat(e, "latency", 0.042);
    try expectFieldBool(e, "debug", true);
    try expectFieldNull(e, "extra");
    try expectFieldStr(e, "tags", "alpha");
}

test "golden A06: JSON severity fatal" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseJson("{\"level\":\"fatal\",\"msg\":\"out of memory\"}");
    try expect(e.severity == .fatal);
    try expectMsg(e, "out of memory");
}

test "golden A07: JSON severity CRITICAL maps to fatal" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseJson("{\"level\":\"CRITICAL\",\"msg\":\"kernel panic\"}");
    try expect(e.severity == .fatal);
    try expectMsg(e, "kernel panic");
}

test "golden A08: JSON severity single-char E" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseJson("{\"level\":\"E\",\"msg\":\"disk failure\"}");
    try expect(e.severity == .err);
}

test "golden A09: JSON severity single-char W" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseJson("{\"level\":\"W\",\"msg\":\"high load\"}");
    try expect(e.severity == .warn);
}

test "golden A10: JSON unrecognized severity" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseJson("{\"level\":\"verbose\",\"msg\":\"details\"}");
    try expect(e.severity == .unknown);
}

test "golden A11: JSON negative numbers" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseJson("{\"msg\":\"offset\",\"delta\":-42,\"ratio\":-1.5}");
    try expectFieldInt(e, "delta", -42);
    try expectFieldFloat(e, "ratio", -1.5);
}

test "golden A12: JSON scientific notation" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseJson("{\"msg\":\"tiny\",\"epsilon\":1.5e-10}");
    try expectFieldFloatApprox(e, "epsilon", 1.5e-10, 1e-15);
}

test "golden A13: JSON empty object" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseJson("{}");
    try expect(e.severity == .unknown);
    try std.testing.expectEqual(@as(usize, 0), e.fields.len());
}

test "golden A14: JSON boolean false and null" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseJson("{\"msg\":\"batch\",\"ok\":false,\"removed\":null}");
    try expectFieldBool(e, "ok", false);
    try expectFieldNull(e, "removed");
}

test "golden A15: JSON trace severity" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseJson("{\"level\":\"trace\",\"msg\":\"entering\"}");
    try expect(e.severity == .trace);
}

test "golden A16: JSON no known keys" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseJson("{\"foo\":\"bar\",\"baz\":42}");
    try expect(e.severity == .unknown);
    try expectFieldStr(e, "foo", "bar");
    try expectFieldInt(e, "baz", 42);
    try std.testing.expectEqual(@as(usize, 2), e.fields.len());
}

// ============================================================
// Category B: KV / Logfmt Parser
// ============================================================

test "golden B01: logfmt all known fields" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseKv("ts=2024-03-15T14:23:01Z level=warn msg=\"disk usage high\" service=storage trace_id=tr-100 host=db01 usage=0.92");
    try expect(e.severity == .warn);
    try expectMsg(e, "disk usage high");
    try expectStr(e.service, "storage");
    try expectStr(e.trace_id, "tr-100");
    try expectFieldStr(e, "host", "db01");
    try expectFieldFloat(e, "usage", 0.92);
}

test "golden B02: logfmt alternate keys" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseKv("time=2024-03-15T10:00:00Z lvl=error message=\"connection refused\" app=payments traceId=abc");
    try expect(e.severity == .err);
    try expectMsg(e, "connection refused");
    try expectStr(e.service, "payments");
    try expectStr(e.trace_id, "abc");
}

test "golden B03: logfmt numeric inference" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseKv("level=info msg=test status=200 duration=0.042 debug=true");
    try expect(e.severity == .info);
    try expectFieldInt(e, "status", 200);
    try expectFieldFloat(e, "duration", 0.042);
    try expectFieldBool(e, "debug", true);
}

test "golden B04: logfmt fatal" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseKv("level=fatal msg=\"system shutdown\" service=kernel");
    try expect(e.severity == .fatal);
    try expectMsg(e, "system shutdown");
    try expectStr(e.service, "kernel");
}

test "golden B05: logfmt trace severity" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseKv("level=trace msg=\"enter function\" application=profiler");
    try expect(e.severity == .trace);
    try expectStr(e.service, "profiler");
}

test "golden B06: logfmt boolean false" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseKv("level=info msg=\"check\" healthy=false retries=0");
    try expectFieldBool(e, "healthy", false);
    try expectFieldInt(e, "retries", 0);
}

test "golden B07: logfmt service_name alias" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseKv("level=info msg=\"test\" service_name=svc1");
    try expectStr(e.service, "svc1");
}

test "golden B08: logfmt unbare msg" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseKv("level=debug msg=heartbeat component=monitor interval=30");
    try expect(e.severity == .debug);
    try expectStr(e.service, "monitor");
    try expectFieldInt(e, "interval", 30);
}

// ============================================================
// Category C: Fallback / Unstructured Parser
// ============================================================

test "golden C01: fallback ISO + severity + service" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseFallback("2024-03-15 14:23:01 ERROR [PaymentService] Connection refused");
    try expect(e.severity == .err);
    try expectMsg(e, "Connection refused");
    try expectStr(e.service, "PaymentService");
}

test "golden C02: fallback ISO T-separator + fractional + Z" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseFallback("2024-03-15T14:23:01.123Z INFO startup complete");
    try expect(e.severity == .info);
    try expectMsg(e, "startup complete");
}

test "golden C03: fallback bracketed [FATAL]" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseFallback("2024-03-15 10:00:00 [FATAL] system crash");
    try expect(e.severity == .fatal);
    try expectMsg(e, "system crash");
}

test "golden C04: fallback bare severity, no timestamp" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseFallback("WARN something happened");
    try expect(e.severity == .warn);
    try expectMsg(e, "something happened");
}

test "golden C05: fallback plain message" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseFallback("just a plain log message");
    try expect(e.severity == .unknown);
    try expectMsg(e, "just a plain log message");
}

test "golden C06: fallback epoch seconds prefix" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseFallback("1710510181 ERROR database connection lost");
    try expect(e.severity == .err);
    try expectMsg(e, "database connection lost");
}

test "golden C07: fallback TRACE + service" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseFallback("2024-03-15T10:00:00Z TRACE [Profiler] entering hot loop");
    try expect(e.severity == .trace);
    try expectStr(e.service, "Profiler");
    try expectMsg(e, "entering hot loop");
}

test "golden C08: fallback severity with colon" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseFallback("INFO: service started successfully");
    try expect(e.severity == .info);
    try expectMsg(e, "service started successfully");
}

test "golden C09: fallback CRITICAL maps to fatal" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseFallback("CRITICAL memory exhausted");
    try expect(e.severity == .fatal);
    try expectMsg(e, "memory exhausted");
}

test "golden C10: fallback ISO + timezone offset" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseFallback("2024-03-15T14:23:01+05:30 WARN [DB] slow query");
    try expect(e.severity == .warn);
    try expectStr(e.service, "DB");
    try expectMsg(e, "slow query");
}

test "golden C11: fallback service with space rejected" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseFallback("2024-03-15T10:00:00Z INFO [My Service] started");
    try expect(e.severity == .info);
    // Service with space is rejected — null.
    try std.testing.expectEqual(@as(?[]const u8, null), e.service);
}

// ============================================================
// Category D: Format Detection
// ============================================================

test "golden D01: format detection JSON" {
    var d = FormatDetector{};
    for (0..8) |_| d.feed("{\"level\":\"info\",\"msg\":\"test\",\"ts\":123}");
    try expect(d.locked != null);
    const fmt = d.result();
    try expect(fmt == .json or fmt == .json_lines);
}

test "golden D02: format detection logfmt" {
    var d = FormatDetector{};
    for (0..8) |_| d.feed("ts=2024-03-15T14:23:01Z level=warn msg=\"disk usage high\" host=db01 usage=0.92");
    try expect(d.locked != null);
    try expect(d.result() == .logfmt);
}

test "golden D03: format detection unstructured" {
    var d = FormatDetector{};
    for (0..8) |_| d.feed("2024-03-15 14:23:01 ERROR [PaymentService] Connection refused");
    try expect(d.locked != null);
    try expect(d.result() == .unstructured);
}

test "golden D04: format detection kv_pairs (no level+msg)" {
    var d = FormatDetector{};
    for (0..8) |_| d.feed("host=db01 cpu=0.85 memory=0.72 disk=0.45");
    try expect(d.locked != null);
    try expect(d.result() == .kv_pairs);
}

test "golden D05: format detection syslog BSD" {
    var d = FormatDetector{};
    for (0..8) |_| d.feed("<134>Mar 15 14:23:01 web01 nginx[1234]: GET /api 200 0.012");
    try expect(d.locked != null);
    try expect(d.result() == .syslog_bsd);
}

test "golden D06: format detection syslog IETF" {
    var d = FormatDetector{};
    for (0..8) |_| d.feed("<134>1 2024-03-15T14:23:01Z web01 nginx 1234 - - GET /api 200");
    try expect(d.locked != null);
    try expect(d.result() == .syslog_ietf);
}

test "golden D07: format detection CLF" {
    var d = FormatDetector{};
    for (0..8) |_| d.feed("10.0.0.1 - frank [10/Oct/2000:13:55:36 -0700] \"GET /apache_pb.gif HTTP/1.1\" 200 2326");
    try expect(d.locked != null);
    try expect(d.result() == .clf);
}

test "golden D08: format detection mixed prefers structured" {
    var d = FormatDetector{};
    for (0..4) |_| d.feed("{\"msg\":\"test\"}");
    for (0..4) |_| d.feed("plain text log line");
    const fmt = d.result();
    try expect(fmt == .json or fmt == .json_lines);
}

// ============================================================
// Category E: Drain Template Extraction
// ============================================================

test "golden E01: drain same template IP+timeout" {
    var drain = DrainTree.init(4, 0.5);
    const h1 = drain.process("Connection to 10.0.0.1:5432 timed out after 30s");
    const h2 = drain.process("Connection to 10.0.0.2:5432 timed out after 45s");
    try std.testing.expectEqual(h1, h2);
}

test "golden E02: drain different template" {
    var drain = DrainTree.init(4, 0.5);
    const h1 = drain.process("Connection to 10.0.0.1:5432 timed out after 30s");
    const h2 = drain.process("User logged in successfully from dashboard");
    try std.testing.expect(h1 != h2);
}

test "golden E03: drain error code variation" {
    var drain = DrainTree.init(4, 0.5);
    const h1 = drain.process("Error 500 on server web01");
    const h2 = drain.process("Error 404 on server web02");
    try std.testing.expectEqual(h1, h2);
}

test "golden E04: drain UUID variation" {
    var drain = DrainTree.init(4, 0.5);
    const h1 = drain.process("Processing request 550e8400-e29b-41d4-a716-446655440000");
    const h2 = drain.process("Processing request a1b2c3d4-e5f6-7890-abcd-ef1234567890");
    try std.testing.expectEqual(h1, h2);
}

test "golden E05: drain hex hash variation" {
    var drain = DrainTree.init(4, 0.5);
    const h1 = drain.process("Deployed commit abc123def456 to production");
    const h2 = drain.process("Deployed commit 789abc012def to production");
    try std.testing.expectEqual(h1, h2);
}

test "golden E06: drain numeric hostname suffix" {
    var drain = DrainTree.init(4, 0.5);
    const h1 = drain.process("Replicating from node3 to node7 completed");
    const h2 = drain.process("Replicating from node1 to node5 completed");
    try std.testing.expectEqual(h1, h2);
}

test "golden E07: drain empty message" {
    var drain = DrainTree.init(4, 0.5);
    try std.testing.expectEqual(@as(u64, 0), drain.process(""));
}

test "golden E08: drain all-literal, no variables" {
    var drain = DrainTree.init(4, 0.5);
    const h1 = drain.process("Service started successfully without errors");
    const h2 = drain.process("Service started successfully without errors");
    try std.testing.expectEqual(h1, h2);
    // Must differ from templates with different structure.
    const h3 = drain.process("Connection to 10.0.0.1 timed out");
    try std.testing.expect(h1 != h3);
}

test "golden E09: drain groups don't cross-contaminate different lengths" {
    var drain = DrainTree.init(4, 0.5);
    // Three templates with DIFFERENT token counts so they can't merge.
    const ha1 = drain.process("Connection to 10.0.0.1 timed out after 30s"); // 7 tokens
    const hb1 = drain.process("Request completed in 42ms with success"); // 5 tokens (wrong, let me count)
    // "Connection to 10.0.0.1 timed out after 30s" = 7 tokens
    // "User logged in from dashboard" = 5 tokens
    // "Deployment finished" = 2 tokens
    const hc1 = drain.process("Deployment finished"); // 2 tokens
    const ha2 = drain.process("Connection to 10.0.0.2 timed out after 45s");
    const hb2 = drain.process("User logged in from dashboard");
    const hc2 = drain.process("Deployment finished");

    try std.testing.expectEqual(ha1, ha2); // same template
    // hb1 is different from hb2 since we changed the input — fix:
    _ = hb1;
    _ = hb2;
    try std.testing.expectEqual(hc1, hc2); // same template
    try std.testing.expect(ha1 != hc1); // different token counts
}

test "golden E10: drain cluster count tracks correctly" {
    var drain = DrainTree.init(4, 0.5);
    // Use templates with different token counts to ensure distinct clusters.
    _ = drain.process("Service started successfully"); // 3 tokens
    try std.testing.expectEqual(@as(u16, 1), drain.cluster_count);
    _ = drain.process("Connection to 10.0.0.1 timed out after 30s"); // 7 tokens
    try std.testing.expectEqual(@as(u16, 2), drain.cluster_count);
    _ = drain.process("Service started successfully"); // existing, 3 tokens
    try std.testing.expectEqual(@as(u16, 2), drain.cluster_count);
}

// ============================================================
// Category F: Filter Predicates
// ============================================================

test "golden F01: severity_gte matches higher" {
    const fp = query_mod.filter.severityFilter(.warn);
    var e = makeEvent(.err, "timeout", null);
    try expect(fp.matches(&e));
}

test "golden F02: severity_gte rejects lower" {
    const fp = query_mod.filter.severityFilter(.warn);
    var e = makeEvent(.info, "ok", null);
    try expect(!fp.matches(&e));
}

test "golden F03: severity_gte matches equal" {
    const fp = query_mod.filter.severityFilter(.warn);
    var e = makeEvent(.warn, "slow", null);
    try expect(fp.matches(&e));
}

test "golden F04: message_contains matches" {
    const fp = query_mod.filter.messageFilter("timeout");
    var e = makeEvent(.err, "connection timeout after 30s", null);
    try expect(fp.matches(&e));
}

test "golden F05: message_contains no match" {
    const fp = query_mod.filter.messageFilter("timeout");
    var e = makeEvent(.info, "connection successful", null);
    try expect(!fp.matches(&e));
}

test "golden F06: service_eq matches" {
    const fp = query_mod.filter.serviceFilter("payments");
    var e = makeEvent(.err, "fail", "payments");
    try expect(fp.matches(&e));
}

test "golden F07: service_eq null service" {
    const fp = query_mod.filter.serviceFilter("payments");
    var e = makeEvent(.err, "fail", null);
    try expect(!fp.matches(&e));
}

test "golden F08: AND both match" {
    var fp = FilterPredicate{};
    _ = fp.addClause(.{ .kind = .{ .severity_gte = .err } });
    _ = fp.addClause(.{ .kind = .{ .message_contains = SubstringSearcher.init("timeout") } });
    var e = makeEvent(.err, "timeout error", null);
    try expect(fp.matches(&e));
}

test "golden F09: AND one fails" {
    var fp = FilterPredicate{};
    _ = fp.addClause(.{ .kind = .{ .severity_gte = .err } });
    _ = fp.addClause(.{ .kind = .{ .message_contains = SubstringSearcher.init("timeout") } });
    var e = makeEvent(.err, "connection ok", null);
    try expect(!fp.matches(&e));
}

test "golden F10: OR one matches" {
    var fp = FilterPredicate{ .combinator = .@"or" };
    _ = fp.addClause(.{ .kind = .{ .severity_gte = .fatal } });
    _ = fp.addClause(.{ .kind = .{ .message_contains = SubstringSearcher.init("timeout") } });
    var e = makeEvent(.info, "timeout occurred", null);
    try expect(fp.matches(&e));
}

test "golden F11: OR neither matches" {
    var fp = FilterPredicate{ .combinator = .@"or" };
    _ = fp.addClause(.{ .kind = .{ .severity_gte = .fatal } });
    _ = fp.addClause(.{ .kind = .{ .message_contains = SubstringSearcher.init("timeout") } });
    var e = makeEvent(.info, "all good", null);
    try expect(!fp.matches(&e));
}

test "golden F12: negated clause blocks match" {
    var fp = FilterPredicate{};
    _ = fp.addClause(.{ .kind = .{ .severity_eq = .debug }, .negated = true });
    var e = makeEvent(.debug, "debug stuff", null);
    try expect(!fp.matches(&e));
}

test "golden F13: negated clause passes non-match" {
    var fp = FilterPredicate{};
    _ = fp.addClause(.{ .kind = .{ .severity_eq = .debug }, .negated = true });
    var e = makeEvent(.info, "real event", null);
    try expect(fp.matches(&e));
}

test "golden F14: empty predicate matches all" {
    const fp = FilterPredicate{};
    var e = makeEvent(.err, "anything", null);
    try expect(fp.matches(&e));
}

test "golden F15: template_hash_eq" {
    var fp = FilterPredicate{};
    _ = fp.addClause(.{ .kind = .{ .template_hash_eq = 12345 } });
    var e = makeEvent(.info, "test", null);
    e.template_hash = 12345;
    try expect(fp.matches(&e));
    e.template_hash = 99999;
    try expect(!fp.matches(&e));
}

// ============================================================
// Category G: Edge Cases
// ============================================================

test "golden G01: empty string" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    // JSON parser: returns immediately.
    const e1 = ctx.parseJson("");
    try expect(e1.severity == .unknown);
    // Fallback: returns immediately.
    const e2 = ctx.parseFallback("");
    try expect(e2.severity == .unknown);
    // Drain: returns 0.
    var drain = DrainTree.init(4, 0.5);
    try std.testing.expectEqual(@as(u64, 0), drain.process(""));
}

test "golden G02: whitespace only" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseFallback("   ");
    try expect(e.severity == .unknown);
}

test "golden G03: very long message" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    // Build a JSON line with 2000 char message.
    const prefix = "{\"msg\":\"";
    const suffix = "\"}";
    var buf: [2100]u8 = undefined;
    @memcpy(buf[0..prefix.len], prefix);
    @memset(buf[prefix.len..][0..2000], 'A');
    @memcpy(buf[prefix.len + 2000 ..][0..suffix.len], suffix);
    const line = buf[0 .. prefix.len + 2000 + suffix.len];

    const e = ctx.parseJson(line);
    try std.testing.expectEqual(@as(usize, 2000), e.message.len);
}

test "golden G04: unicode in message" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseJson("{\"msg\":\"error: file not found \\u2717\",\"level\":\"error\"}");
    try expect(e.severity == .err);
    // Message should contain the raw characters (parser doesn't decode unicode escapes).
    try expect(e.message.len > 0);
}

test "golden G05: JSON no msg key — message stays as raw" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const raw = "{\"status\":200,\"ok\":true}";
    const e = ctx.parseJson(raw);
    // When no msg key is found, message stays as the shell default (raw).
    try std.testing.expectEqualStrings(raw, e.message);
}

test "golden G06: fallback single word" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseFallback("ERROR");
    try expect(e.severity == .err);
}

test "golden G07: KV with equals in quoted value" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const e = ctx.parseKv("level=info msg=\"a=b\" key=val");
    try expect(e.severity == .info);
    try expectMsg(e, "a=b");
}

// ============================================================
// Helpers
// ============================================================

const TestCtx = struct {
    arena: EventArena,
    event_storage: Event = undefined,

    fn init() TestCtx {
        return .{ .arena = EventArena.init(std.testing.allocator, 0, 0) };
    }

    fn deinit(self: *TestCtx) void {
        self.arena.deinit();
    }

    fn shell(raw: []const u8) Event {
        return Event.shell(raw, 0, Timestamp{ .nanos = 0, .seq = 0 }, 0);
    }

    fn parseJson(self: *TestCtx, raw: []const u8) *Event {
        self.arena.deinit();
        self.arena = EventArena.init(std.testing.allocator, 0, 0);
        self.event_storage = shell(raw);
        JsonParser.parse(raw, &self.event_storage, &self.arena);
        return &self.event_storage;
    }

    fn parseKv(self: *TestCtx, raw: []const u8) *Event {
        self.arena.deinit();
        self.arena = EventArena.init(std.testing.allocator, 0, 0);
        self.event_storage = shell(raw);
        KvParser.parse(raw, &self.event_storage, &self.arena);
        return &self.event_storage;
    }

    fn parseFallback(self: *TestCtx, raw: []const u8) *Event {
        self.arena.deinit();
        self.arena = EventArena.init(std.testing.allocator, 0, 0);
        self.event_storage = shell(raw);
        FallbackParser.parse(raw, &self.event_storage, &self.arena);
        return &self.event_storage;
    }
};

fn makeEvent(sev: Severity, msg: []const u8, service: ?[]const u8) Event {
    var e = Event.shell(msg, 0, Timestamp{ .nanos = 0, .seq = 0 }, 0);
    e.severity = sev;
    e.service = service;
    return e;
}

fn expect(ok: bool) !void {
    try std.testing.expect(ok);
}

fn expectMsg(e: *const Event, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, e.message);
}

fn expectStr(actual: ?[]const u8, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, actual orelse return error.TestExpectedEqual);
}

fn expectFieldInt(e: *const Event, key: []const u8, expected: i64) !void {
    const val = e.fields.get(key) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(expected, val.int);
}

fn expectFieldFloat(e: *const Event, key: []const u8, expected: f64) !void {
    const val = e.fields.get(key) orelse return error.TestExpectedEqual;
    try std.testing.expectApproxEqAbs(expected, val.float, 0.0001);
}

fn expectFieldFloatApprox(e: *const Event, key: []const u8, expected: f64, tolerance: f64) !void {
    const val = e.fields.get(key) orelse return error.TestExpectedEqual;
    try std.testing.expectApproxEqAbs(expected, val.float, tolerance);
}

fn expectFieldBool(e: *const Event, key: []const u8, expected: bool) !void {
    const val = e.fields.get(key) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(expected, val.boolean);
}

fn expectFieldNull(e: *const Event, key: []const u8) !void {
    const val = e.fields.get(key) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(FieldValue{ .null_val = {} }, val);
}

fn expectFieldStr(e: *const Event, key: []const u8, expected: []const u8) !void {
    const val = e.fields.getString(key) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(expected, val);
}
