const std = @import("std");

/// Detects whether a log line is a continuation of the previous event
/// (e.g., stack trace, multi-line JSON, indented output).
pub const MultiLineDetector = struct {
    /// Check if a line is a continuation of the previous event.
    /// Continuation lines should be appended to the previous event
    /// rather than creating a new event.
    pub fn isContinuation(line: []const u8) bool {
        if (line.len == 0) return false;

        // Indented lines (starts with whitespace).
        if (line[0] == ' ' or line[0] == '\t') return true;

        // Java stack trace: "at com.example.Class.method(File.java:42)"
        if (std.mem.startsWith(u8, line, "at ")) return true;

        // Java/Python: "Caused by: ..."
        if (std.mem.startsWith(u8, line, "Caused by:")) return true;
        if (std.mem.startsWith(u8, line, "Caused by ")) return true;

        // Python: "Traceback (most recent call last):"
        if (std.mem.startsWith(u8, line, "Traceback ")) return true;

        // Python: "  File "..." line N"
        if (std.mem.startsWith(u8, line, "File \"")) return true;

        // Java: "... N more"
        if (std.mem.startsWith(u8, line, "... ")) return true;

        // Ruby: "from /path/to/file.rb:N:in `method'"
        if (std.mem.startsWith(u8, line, "from ")) {
            if (std.mem.indexOf(u8, line, ".rb:") != null or
                std.mem.indexOf(u8, line, ".py:") != null)
                return true;
        }

        // Go: "goroutine N [...]:"
        if (std.mem.startsWith(u8, line, "goroutine ")) return true;

        // Continuation marker: line starts with } or ] (closing multiline JSON/XML)
        if (line[0] == '}' or line[0] == ']') return true;

        return false;
    }
};

test "multiline: indented lines are continuations" {
    try std.testing.expect(MultiLineDetector.isContinuation("    at com.example.Main.run(Main.java:42)"));
    try std.testing.expect(MultiLineDetector.isContinuation("\tat java.lang.Thread.run(Thread.java:748)"));
    try std.testing.expect(MultiLineDetector.isContinuation("  File \"/app/main.py\", line 10"));
}

test "multiline: stack trace keywords" {
    try std.testing.expect(MultiLineDetector.isContinuation("at com.example.Service.call(Service.java:100)"));
    try std.testing.expect(MultiLineDetector.isContinuation("Caused by: java.io.IOException: connection refused"));
    try std.testing.expect(MultiLineDetector.isContinuation("Traceback (most recent call last):"));
    try std.testing.expect(MultiLineDetector.isContinuation("... 23 more"));
}

test "multiline: normal lines are not continuations" {
    try std.testing.expect(!MultiLineDetector.isContinuation("2024-03-15 ERROR something broke"));
    try std.testing.expect(!MultiLineDetector.isContinuation("{\"level\":\"error\",\"msg\":\"fail\"}"));
    try std.testing.expect(!MultiLineDetector.isContinuation("INFO startup complete"));
    try std.testing.expect(!MultiLineDetector.isContinuation(""));
}

test "multiline: closing braces" {
    try std.testing.expect(MultiLineDetector.isContinuation("}"));
    try std.testing.expect(MultiLineDetector.isContinuation("]"));
}
