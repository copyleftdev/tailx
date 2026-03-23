const std = @import("std");
const tailx = @import("tailx_lib");
const Pipeline = tailx.pipeline.Pipeline;
const Renderer = tailx.render.Renderer;
const DisplayMode = tailx.render.terminal.DisplayMode;
const ReadBuffer = tailx.ingestion.ReadBuffer;
const Severity = tailx.core.Severity;
const FilterPredicate = tailx.query.FilterPredicate;
const SubstringSearcher = tailx.query.filter.SubstringSearcher;
const IntentParser = tailx.query.IntentParser;
const JsonRenderer = tailx.render.JsonRenderer;

const version = "1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stderr = std.io.getStdErr().writer();
    const stdout_file = std.io.getStdOut();
    const stdout = stdout_file.writer();

    // Parse args.
    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    var files = std.ArrayList([]const u8).init(allocator);
    defer files.deinit();

    var follow = true;
    var from_start = false;
    var no_color = false;
    var severity: Severity = .trace;
    var ring_size: u32 = 65536;
    var mode: DisplayMode = .pattern;
    var json_mode = false;

    // Filter building.
    var filter = FilterPredicate{};
    var has_filter = false;
    var time_filter_ns: ?i128 = null;

    var i: usize = 1;
    while (i < raw_args.len) : (i += 1) {
        const arg = raw_args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(stdout);
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            try stdout.print("tailx v{s}\n", .{version});
            return;
        } else if (std.mem.eql(u8, arg, "--follow") or std.mem.eql(u8, arg, "-f")) {
            follow = true;
        } else if (std.mem.eql(u8, arg, "--no-follow") or std.mem.eql(u8, arg, "-n")) {
            follow = false;
        } else if (std.mem.eql(u8, arg, "--from-start") or std.mem.eql(u8, arg, "-s")) {
            from_start = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            no_color = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            mode = .raw;
        } else if (std.mem.eql(u8, arg, "--trace")) {
            mode = .trace;
        } else if (std.mem.eql(u8, arg, "--incident")) {
            mode = .incident;
        } else if (std.mem.eql(u8, arg, "--severity") or std.mem.eql(u8, arg, "-l")) {
            i += 1;
            if (i >= raw_args.len) {
                try stderr.print("tailx: --severity requires an argument\n", .{});
                std.process.exit(1);
            }
            severity = Severity.parse(raw_args[i]);
        } else if (std.mem.eql(u8, arg, "--grep") or std.mem.eql(u8, arg, "-g")) {
            i += 1;
            if (i >= raw_args.len) {
                try stderr.print("tailx: --grep requires an argument\n", .{});
                std.process.exit(1);
            }
            _ = filter.addClause(.{ .kind = .{ .message_contains = SubstringSearcher.init(raw_args[i]) } });
            has_filter = true;
        } else if (std.mem.eql(u8, arg, "--service")) {
            i += 1;
            if (i >= raw_args.len) {
                try stderr.print("tailx: --service requires an argument\n", .{});
                std.process.exit(1);
            }
            _ = filter.addClause(.{ .kind = .{ .service_eq = FilterPredicate.FixedString.from(raw_args[i]) } });
            has_filter = true;
        } else if (std.mem.eql(u8, arg, "--trace-id")) {
            i += 1;
            if (i >= raw_args.len) {
                try stderr.print("tailx: --trace-id requires an argument\n", .{});
                std.process.exit(1);
            }
            _ = filter.addClause(.{ .kind = .{ .trace_id_eq = FilterPredicate.FixedString.from(raw_args[i]) } });
            has_filter = true;
        } else if (std.mem.eql(u8, arg, "--field")) {
            i += 1;
            if (i >= raw_args.len) {
                try stderr.print("tailx: --field requires key=value\n", .{});
                std.process.exit(1);
            }
            if (std.mem.indexOf(u8, raw_args[i], "=")) |eq_pos| {
                _ = filter.addClause(.{ .kind = .{ .field_eq = .{
                    .key = FilterPredicate.FixedString.from(raw_args[i][0..eq_pos]),
                    .value = FilterPredicate.FixedString.from(raw_args[i][eq_pos + 1 ..]),
                } } });
                has_filter = true;
            } else {
                try stderr.print("tailx: --field must be key=value\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--last")) {
            i += 1;
            if (i >= raw_args.len) {
                try stderr.print("tailx: --last requires a duration (e.g., 5m, 1h, 30s)\n", .{});
                std.process.exit(1);
            }
            const duration_ns = parseDuration(raw_args[i]) catch {
                try stderr.print("tailx: invalid duration '{s}'. Use e.g., 5m, 1h, 30s\n", .{raw_args[i]});
                std.process.exit(1);
            };
            time_filter_ns = std.time.nanoTimestamp() - duration_ns;
        } else if (std.mem.eql(u8, arg, "--ring-size")) {
            i += 1;
            if (i >= raw_args.len) {
                try stderr.print("tailx: --ring-size requires an argument\n", .{});
                std.process.exit(1);
            }
            ring_size = std.fmt.parseInt(u32, raw_args[i], 10) catch {
                try stderr.print("tailx: invalid ring-size\n", .{});
                std.process.exit(1);
            };
        } else if (arg.len > 0 and arg[0] == '-') {
            try stderr.print("tailx: unknown option '{s}'\n", .{arg});
            std.process.exit(1);
        } else {
            // Positional arg: file path or intent query.
            // If the file exists, treat as file path. Otherwise, treat as intent query.
            if (std.fs.cwd().access(arg, .{})) {
                try files.append(arg);
            } else |_| {
                // Not a file — parse as intent query.
                const intent_filter = IntentParser.parse(arg);
                // Merge intent clauses into the main filter.
                for (intent_filter.clauses[0..intent_filter.clause_count]) |clause| {
                    _ = filter.addClause(clause);
                    has_filter = true;
                }
            }
        }
    }

    // Detect mode.
    const is_stdin = files.items.len == 0;
    if (is_stdin and std.posix.isatty(std.io.getStdIn().handle)) {
        try printUsage(stdout);
        return;
    }

    // Initialize pipeline.
    var pipeline = try Pipeline.init(allocator, ring_size);
    defer pipeline.deinit();
    pipeline.fixupPointers();
    pipeline.severity_filter = severity;
    pipeline.time_filter_start_ns = time_filter_ns;

    // Initialize renderers.
    var renderer = Renderer.init(stdout_file.writer());
    renderer.colorize = !no_color and !json_mode and std.posix.isatty(stdout_file.handle);
    renderer.mode = mode;

    var json_renderer = JsonRenderer.init(stdout_file.writer());

    const filter_ptr: ?*const FilterPredicate = if (has_filter) &filter else null;

    if (json_mode) {
        if (is_stdin) {
            try runStdinJson(&pipeline, &json_renderer, filter_ptr);
        } else {
            try runFilesJson(allocator, files.items, follow, from_start, &pipeline, &json_renderer, filter_ptr);
        }
    } else {
        if (is_stdin) {
            try runStdin(&pipeline, &renderer, filter_ptr);
        } else {
            try runFiles(allocator, files.items, follow, from_start, &pipeline, &renderer, filter_ptr);
        }
    }

    // End-of-run output.
    if (pipeline.events_total > 0) {
        var hypotheses: [8]tailx.correlation.Hypothesis = undefined;
        const hyp_count = pipeline.getHypotheses(&hypotheses);

        if (json_mode) {
            // Emit the triage summary — the money shot for AI.
            json_renderer.renderTriageSummary(
                pipeline.stats(),
                pipeline.group_table,
                &pipeline.signal_agg,
                hypotheses[0..hyp_count],
                pipeline.trace_store,
                &pipeline.ring,
            );
        } else if (mode != .raw) {
            const pstats = pipeline.stats();
            renderer.renderActiveAlerts(&pipeline.signal_agg);

            if (mode == .trace) {
                renderer.renderTraces(pipeline.trace_store, &pipeline.ring);
            }

            renderer.renderPatternSummary(pipeline.group_table, pstats);
            renderer.renderHypotheses(hypotheses[0..hyp_count]);
        }

        // Stats to stderr.
        const final_stats = pipeline.stats();
        try stderr.print(
            "tailx: {d} events, {d} groups, {d} templates, {d} drops\n",
            .{ final_stats.events_total, final_stats.active_groups, final_stats.drain_clusters, final_stats.drop_count },
        );
    }
}

fn runStdinJson(pipeline: *Pipeline, json_renderer: *JsonRenderer, filter_pred: ?*const FilterPredicate) !void {
    const stdin = std.io.getStdIn().reader();
    var buf: [65536]u8 = undefined;

    while (true) {
        const line = stdin.readUntilDelimiterOrEof(&buf, '\n') catch |err| {
            switch (err) {
                error.StreamTooLong => continue,
                else => return err,
            }
        };

        if (line) |raw| {
            const trimmed = if (raw.len > 0 and raw[raw.len - 1] == '\r')
                raw[0 .. raw.len - 1]
            else
                raw;

            if (pipeline.processLine(trimmed, 0)) |event| {
                if (eventPassesFilter(event, pipeline.severity_filter, filter_pred, pipeline.time_filter_start_ns)) {
                    json_renderer.renderEvent(event);
                }
            }
        } else {
            break;
        }
    }
}

fn runFilesJson(
    allocator: std.mem.Allocator,
    file_paths: []const []const u8,
    follow: bool,
    from_start: bool,
    pipeline: *Pipeline,
    json_renderer: *JsonRenderer,
    filter_pred: ?*const FilterPredicate,
) !void {
    // Reuse the same file source setup as runFiles.
    const stderr = std.io.getStdErr().writer();

    var expanded_paths = std.ArrayList([]const u8).init(allocator);
    defer expanded_paths.deinit();
    for (file_paths) |path| {
        if (std.mem.indexOf(u8, path, "*") != null or std.mem.indexOf(u8, path, "?") != null) {
            const dir_end = if (std.mem.lastIndexOf(u8, path, "/")) |pos| pos + 1 else 0;
            const dir_path = if (dir_end > 0) path[0 .. dir_end - 1] else ".";
            const pattern = path[dir_end..];
            var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch continue;
            defer dir.close();
            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (entry.kind != .file) continue;
                if (globMatch(entry.name, pattern)) {
                    const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
                    try expanded_paths.append(full);
                }
            }
        } else {
            try expanded_paths.append(path);
        }
    }

    const FileSourceJson = struct {
        file: std.fs.File,
        source_id: u16,
        buf: *ReadBuffer,
    };

    var sources = std.ArrayList(FileSourceJson).init(allocator);
    defer {
        for (sources.items) |*src| {
            allocator.destroy(src.buf);
            src.file.close();
        }
        sources.deinit();
    }

    for (expanded_paths.items, 0..) |path, idx| {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            try stderr.print("tailx: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
            continue;
        };
        if (!from_start) file.seekFromEnd(0) catch {};
        const buf = try allocator.create(ReadBuffer);
        buf.* = .{};
        try sources.append(.{ .file = file, .source_id = @intCast(idx), .buf = buf });
    }

    if (sources.items.len == 0) {
        try stderr.print("tailx: no files to read\n", .{});
        std.process.exit(1);
    }

    while (true) {
        var any_read = false;
        for (sources.items) |*src| {
            var read_buf: [4096]u8 = undefined;
            const bytes_read = src.file.read(&read_buf) catch 0;
            if (bytes_read > 0) {
                any_read = true;
                _ = src.buf.append(read_buf[0..bytes_read]);
                var lines: [128]ReadBuffer.Line = undefined;
                const line_count = src.buf.drainLines(&lines);
                for (lines[0..line_count]) |line_item| {
                    if (pipeline.processLine(line_item.data, src.source_id)) |event| {
                        if (eventPassesFilter(event, pipeline.severity_filter, filter_pred, pipeline.time_filter_start_ns)) {
                            json_renderer.renderEvent(event);
                        }
                    }
                }
            }
        }
        if (!any_read) {
            if (follow) {
                std.time.sleep(100 * std.time.ns_per_ms);
            } else {
                break;
            }
        }
    }
}

fn eventPassesFilter(event: *const tailx.core.Event, sev_filter: Severity, pred: ?*const FilterPredicate, time_start: ?i128) bool {
    if (event.severity.numeric() < sev_filter.numeric()) return false;
    if (time_start) |ts| {
        if (event.timestamp.nanos < ts) return false;
    }
    if (pred) |f| {
        if (!f.matches(event)) return false;
    }
    return true;
}

fn parseDuration(s: []const u8) !i128 {
    if (s.len < 2) return error.InvalidDuration;
    const unit = s[s.len - 1];
    const num_str = s[0 .. s.len - 1];
    const num = std.fmt.parseInt(i64, num_str, 10) catch return error.InvalidDuration;
    const multiplier: i128 = switch (unit) {
        's' => std.time.ns_per_s,
        'm' => 60 * std.time.ns_per_s,
        'h' => 3600 * std.time.ns_per_s,
        'd' => 86400 * std.time.ns_per_s,
        else => return error.InvalidDuration,
    };
    return @as(i128, num) * multiplier;
}

fn runStdin(pipeline: *Pipeline, renderer: *Renderer, filter_pred: ?*const FilterPredicate) !void {
    const stdin = std.io.getStdIn().reader();
    var buf: [65536]u8 = undefined;

    while (true) {
        const line = stdin.readUntilDelimiterOrEof(&buf, '\n') catch |err| {
            switch (err) {
                error.StreamTooLong => continue,
                else => return err,
            }
        };

        if (line) |raw| {
            const trimmed = if (raw.len > 0 and raw[raw.len - 1] == '\r')
                raw[0 .. raw.len - 1]
            else
                raw;

            if (pipeline.processLine(trimmed, 0)) |event| {
                if (eventPassesFilter(event, pipeline.severity_filter, filter_pred, pipeline.time_filter_start_ns)) {
                    renderer.renderEvent(event, null);
                }
            }

            // Inline summary in follow/pattern mode.
            if (renderer.shouldSummarize()) {
                renderer.renderPatternSummary(pipeline.group_table, pipeline.stats());
                renderer.markSummarized();
            }
        } else {
            break;
        }
    }
}

fn runFiles(
    allocator: std.mem.Allocator,
    file_paths: []const []const u8,
    follow: bool,
    from_start: bool,
    pipeline: *Pipeline,
    renderer: *Renderer,
    filter_pred: ?*const FilterPredicate,
) !void {
    const stderr = std.io.getStdErr().writer();

    const FileSource = struct {
        file: std.fs.File,
        path: []const u8,
        source_id: u16,
        buf: *ReadBuffer,
        last_size: u64,
        inode: u64,

        /// Check for truncation (copytruncate) and rotation (create).
        fn checkRotation(self: *@This()) void {
            // 1. Check current fd size for truncation.
            const fd_stat = self.file.stat() catch return;
            if (fd_stat.size < self.last_size) {
                // Copytruncate: same inode, size shrunk → seek to 0.
                self.file.seekTo(0) catch {};
                self.buf.reset();
            }
            self.last_size = fd_stat.size;

            // 2. Check if path now points to a different inode (create rotation).
            const path_stat = std.fs.cwd().statFile(self.path) catch return;
            if (path_stat.inode != self.inode) {
                // Path now has a new file. Reopen.
                const new_file = std.fs.cwd().openFile(self.path, .{}) catch return;
                self.file.close();
                self.file = new_file;
                self.inode = path_stat.inode;
                self.last_size = 0;
                self.buf.reset();
            }
        }
    };

    var sources = std.ArrayList(FileSource).init(allocator);
    defer {
        for (sources.items) |*src| {
            allocator.destroy(src.buf);
            src.file.close();
        }
        sources.deinit();
    }

    // Expand globs and collect all file paths.
    var expanded_paths = std.ArrayList([]const u8).init(allocator);
    defer expanded_paths.deinit();

    for (file_paths) |path| {
        if (std.mem.indexOf(u8, path, "*") != null or std.mem.indexOf(u8, path, "?") != null) {
            // Glob expansion: split into directory + pattern.
            const dir_end = if (std.mem.lastIndexOf(u8, path, "/")) |pos| pos + 1 else 0;
            const dir_path = if (dir_end > 0) path[0 .. dir_end - 1] else ".";
            const pattern = path[dir_end..];

            var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
                try stderr.print("tailx: cannot open directory for glob '{s}'\n", .{path});
                continue;
            };
            defer dir.close();

            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (entry.kind != .file) continue;
                if (globMatch(entry.name, pattern)) {
                    // Build full path.
                    const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
                    try expanded_paths.append(full);
                }
            }
        } else {
            try expanded_paths.append(path);
        }
    }

    for (expanded_paths.items, 0..) |path, idx| {
        const source_id: u16 = @intCast(idx);
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            try stderr.print("tailx: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
            continue;
        };

        if (!from_start) {
            file.seekFromEnd(0) catch {};
        }

        const buf = try allocator.create(ReadBuffer);
        buf.* = .{};

        const fstat = file.stat() catch null;
        const initial_size: u64 = if (fstat) |s| s.size else 0;
        const initial_inode: u64 = if (fstat) |s| s.inode else 0;
        try sources.append(.{
            .file = file,
            .path = path,
            .source_id = source_id,
            .buf = buf,
            .last_size = initial_size,
            .inode = initial_inode,
        });
    }

    if (sources.items.len == 0) {
        try stderr.print("tailx: no files to read\n", .{});
        std.process.exit(1);
    }

    const show_source = sources.items.len > 1;

    while (true) {
        var any_read = false;
        for (sources.items) |*src| {
            var read_buf: [4096]u8 = undefined;
            const bytes_read = src.file.read(&read_buf) catch 0;

            if (bytes_read > 0) {
                any_read = true;
                _ = src.buf.append(read_buf[0..bytes_read]);

                var lines: [128]ReadBuffer.Line = undefined;
                const line_count = src.buf.drainLines(&lines);

                for (lines[0..line_count]) |line_item| {
                    if (pipeline.processLine(line_item.data, src.source_id)) |event| {
                        if (eventPassesFilter(event, pipeline.severity_filter, filter_pred, pipeline.time_filter_start_ns)) {
                            const name: ?[]const u8 = if (show_source) src.path else null;
                            renderer.renderEvent(event, name);
                        }
                    }
                }
            }
        }

        // Inline summary in follow/pattern mode.
        if (renderer.shouldSummarize()) {
            renderer.renderPatternSummary(pipeline.group_table, pipeline.stats());
            renderer.markSummarized();
        }

        if (!any_read) {
            if (follow) {
                // Use poll to wait for data instead of blind sleep.
                var pollfds: [64]std.posix.pollfd = undefined;
                const poll_count = @min(sources.items.len, 64);
                for (sources.items[0..poll_count], 0..) |src, pi| {
                    pollfds[pi] = .{
                        .fd = src.file.handle,
                        .events = std.posix.POLL.IN,
                        .revents = 0,
                    };
                }
                _ = std.posix.poll(pollfds[0..poll_count], 100) catch {
                    std.time.sleep(100 * std.time.ns_per_ms);
                };
                // Check for file truncation periodically.
                for (sources.items) |*src| {
                    src.checkRotation();
                }
            } else {
                break;
            }
        }
    }
}

fn printUsage(writer: anytype) !void {
    try writer.print(
        \\tailx v{s} — live system cognition engine
        \\
        \\Usage:
        \\  tailx <file>...                  Tail one or more files
        \\  cat log | tailx                  Read from stdin (pipe)
        \\
        \\Modes:
        \\      --raw                        Classic tail (line by line only)
        \\      --trace                      Trace view (group by trace ID)
        \\      --incident                   Only anomalies + top groups
        \\      --json                       JSONL output (for AI/tooling)
        \\      (default)                    Pattern mode (lines + summary)
        \\
        \\Filters:
        \\  -l, --severity <level>           Minimum severity to display
        \\  -g, --grep <string>              Filter by message substring
        \\      --service <name>             Filter by service name
        \\      --trace-id <id>              Filter by trace ID
        \\      --field <key=value>          Filter by field value
        \\      --last <duration>            Only events from last N (5m, 1h, 30s)
        \\
        \\Options:
        \\  -f, --follow                     Follow files (default)
        \\  -n, --no-follow                  Read to EOF and stop
        \\  -s, --from-start                 Start from beginning of file
        \\      --no-color                   Disable color output
        \\      --ring-size <n>              Event ring capacity (default: 65536)
        \\  -h, --help                       Show this help
        \\  -V, --version                    Show version
        \\
        \\Severity levels:
        \\  trace, debug, info, warn, error, fatal
        \\
        \\Examples:
        \\  tailx app.log                    Tail with pattern grouping
        \\  tailx -s -n /var/log/syslog      Read full file, show summary
        \\  tailx --severity error app.log   Only errors and above
        \\  tailx --grep timeout app.log     Only lines containing "timeout"
        \\  tailx --service payments app.log Only from payments service
        \\  tailx --incident app.log db.log  Anomaly-only view
        \\  dmesg | tailx --severity warn    Kernel warnings and above
        \\
    , .{version});
}

/// Simple glob pattern matching (* and ?).
fn globMatch(name: []const u8, pattern: []const u8) bool {
    var ni: usize = 0;
    var pi: usize = 0;
    var star_pi: ?usize = null;
    var star_ni: usize = 0;

    while (ni < name.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == name[ni])) {
            ni += 1;
            pi += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ni = ni;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ni += 1;
            ni = star_ni;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

test {
    std.testing.refAllDecls(@This());
}
