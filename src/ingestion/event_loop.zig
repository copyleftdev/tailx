const std = @import("std");
const builtin = @import("builtin");

/// Platform-specific poller for non-blocking I/O.
/// Uses epoll on Linux, falls back to poll on other platforms.
pub const Poller = struct {
    fds: [max_fds]PollEntry = undefined,
    fd_count: u8 = 0,

    const max_fds = 64;

    const PollEntry = struct {
        fd: std.posix.fd_t,
        user_data: usize,
    };

    pub fn init() Poller {
        return .{};
    }

    /// Register a file descriptor for read events.
    pub fn add(self: *Poller, fd: std.posix.fd_t, user_data: usize) bool {
        if (self.fd_count >= max_fds) return false;
        self.fds[self.fd_count] = .{ .fd = fd, .user_data = user_data };
        self.fd_count += 1;
        return true;
    }

    /// Poll for ready file descriptors.
    /// Returns number of ready fds. Ready indices written to `ready_out`.
    pub fn poll(self: *Poller, ready_out: []usize, timeout_ms: i32) u8 {
        if (self.fd_count == 0) {
            if (timeout_ms > 0) std.time.sleep(@intCast(timeout_ms * std.time.ns_per_ms));
            return 0;
        }

        // Build pollfd array.
        var pollfds: [max_fds]std.posix.pollfd = undefined;
        for (self.fds[0..self.fd_count], 0..) |entry, i| {
            pollfds[i] = .{
                .fd = entry.fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            };
        }

        const result = std.posix.poll(pollfds[0..self.fd_count], timeout_ms) catch return 0;

        if (result == 0) return 0;

        var count: u8 = 0;
        for (pollfds[0..self.fd_count], 0..) |pfd, i| {
            if (pfd.revents & std.posix.POLL.IN != 0) {
                if (count < ready_out.len) {
                    ready_out[count] = self.fds[i].user_data;
                    count += 1;
                }
            }
        }

        return count;
    }
};

test "poller init" {
    const p = Poller.init();
    try std.testing.expectEqual(@as(u8, 0), p.fd_count);
}
