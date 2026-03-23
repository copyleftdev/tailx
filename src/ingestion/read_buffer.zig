const std = @import("std");

/// Per-source read buffer with in-place line splitting.
/// 64 KiB buffer. Yields complete lines terminated by \n.
/// Handles \r\n, partial lines across reads, and long-line truncation.
pub const ReadBuffer = struct {
    buf: [buffer_size]u8 = undefined,
    len: usize = 0,
    scan_pos: usize = 0,

    pub const buffer_size = 65536; // 64 KiB

    pub const Line = struct {
        data: []const u8,
    };

    /// Append bytes from a read() call into the buffer.
    /// Returns the number of bytes actually appended (may be less if buffer is near full).
    pub fn append(self: *ReadBuffer, bytes: []const u8) usize {
        const available = buffer_size - self.len;
        const to_copy = @min(bytes.len, available);
        @memcpy(self.buf[self.len..][0..to_copy], bytes[0..to_copy]);
        self.len += to_copy;
        return to_copy;
    }

    /// Yield complete lines (\n-terminated) from the buffer.
    /// Incomplete trailing data is retained for the next read.
    /// Returns lines via the provided output slice.
    /// If the buffer is full with no newline, yields the entire buffer as a
    /// truncated line to prevent stalling.
    pub fn drainLines(self: *ReadBuffer, out: []Line) usize {
        var count: usize = 0;
        var line_start: usize = 0;

        var pos = self.scan_pos;
        while (pos < self.len and count < out.len) {
            if (self.buf[pos] == '\n') {
                var end = pos;
                // Trim \r for \r\n line endings.
                if (end > line_start and self.buf[end - 1] == '\r') {
                    end -= 1;
                }
                out[count] = .{ .data = self.buf[line_start..end] };
                count += 1;
                line_start = pos + 1;
            }
            pos += 1;
        }

        // Handle full buffer with no newline → truncated line.
        if (count == 0 and self.len == buffer_size and line_start == 0) {
            out[0] = .{ .data = self.buf[0..self.len] };
            count = 1;
            line_start = self.len;
        }

        // Compact: move unprocessed bytes to the front.
        if (line_start > 0) {
            const remaining = self.len - line_start;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[line_start..self.len]);
            }
            self.len = remaining;
            self.scan_pos = 0;
        } else {
            self.scan_pos = pos;
        }

        return count;
    }

    /// Reset the buffer, discarding all data.
    pub fn reset(self: *ReadBuffer) void {
        self.len = 0;
        self.scan_pos = 0;
    }
};

test "read buffer basic line splitting" {
    var rb = ReadBuffer{};
    var lines: [16]ReadBuffer.Line = undefined;

    _ = rb.append("hello\nworld\n");
    const count = rb.drainLines(&lines);

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("hello", lines[0].data);
    try std.testing.expectEqualStrings("world", lines[1].data);
    try std.testing.expectEqual(@as(usize, 0), rb.len);
}

test "read buffer partial line retained" {
    var rb = ReadBuffer{};
    var lines: [16]ReadBuffer.Line = undefined;

    // First read: partial line, no newline.
    _ = rb.append("partial");
    var count = rb.drainLines(&lines);
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expectEqual(@as(usize, 7), rb.len);

    // Second read: completes the line.
    _ = rb.append(" line\n");
    count = rb.drainLines(&lines);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("partial line", lines[0].data);
}

test "read buffer carriage return handling" {
    var rb = ReadBuffer{};
    var lines: [16]ReadBuffer.Line = undefined;

    _ = rb.append("windows\r\nline\r\n");
    const count = rb.drainLines(&lines);

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("windows", lines[0].data);
    try std.testing.expectEqualStrings("line", lines[1].data);
}

test "read buffer long line truncation" {
    var rb = ReadBuffer{};
    var lines: [4]ReadBuffer.Line = undefined;

    // Fill the entire 64 KiB buffer with no newline.
    var big_buf: [ReadBuffer.buffer_size]u8 = undefined;
    @memset(&big_buf, 'A');
    _ = rb.append(&big_buf);

    try std.testing.expectEqual(ReadBuffer.buffer_size, rb.len);

    // Should yield the full buffer as a truncated line.
    const count = rb.drainLines(&lines);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(ReadBuffer.buffer_size, lines[0].data.len);
    // Buffer should be empty after truncation.
    try std.testing.expectEqual(@as(usize, 0), rb.len);
}

test "read buffer multiple reads compose" {
    var rb = ReadBuffer{};
    var lines: [16]ReadBuffer.Line = undefined;

    _ = rb.append("line1\nli");
    var count = rb.drainLines(&lines);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("line1", lines[0].data);

    // "li" should be retained.
    _ = rb.append("ne2\nline3\n");
    count = rb.drainLines(&lines);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("line2", lines[0].data);
    try std.testing.expectEqualStrings("line3", lines[1].data);
}

test "read buffer empty input" {
    var rb = ReadBuffer{};
    var lines: [16]ReadBuffer.Line = undefined;

    _ = rb.append("");
    const count = rb.drainLines(&lines);
    try std.testing.expectEqual(@as(usize, 0), count);
}
