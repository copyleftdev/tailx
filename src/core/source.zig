const std = @import("std");

pub const SourceId = u16;

pub const SourceKind = enum {
    file,
    stdin,
    journald,
    kubernetes,
    socket,
};

pub const SourceMeta = struct {
    id: SourceId,
    kind: SourceKind,
    name: []const u8,
    path: ?[]const u8,
};

pub const SourceRegistry = struct {
    sources: [max_sources]?SourceMeta = [_]?SourceMeta{null} ** max_sources,
    count: u16 = 0,

    pub const max_sources = 4096;

    pub fn register(self: *SourceRegistry, kind: SourceKind, name: []const u8, path: ?[]const u8) !SourceId {
        if (self.count >= max_sources) return error.TooManySources;
        const id = self.count;
        self.sources[id] = .{
            .id = id,
            .kind = kind,
            .name = name,
            .path = path,
        };
        self.count += 1;
        return id;
    }

    pub fn lookup(self: *const SourceRegistry, id: SourceId) ?SourceMeta {
        if (id >= self.count) return null;
        return self.sources[id];
    }

    pub fn nameOf(self: *const SourceRegistry, id: SourceId) []const u8 {
        if (self.lookup(id)) |meta| return meta.name;
        return "<unknown>";
    }
};

test "source registry" {
    var reg = SourceRegistry{};
    const id1 = try reg.register(.file, "app.log", "/var/log/app.log");
    const id2 = try reg.register(.stdin, "stdin", null);

    try std.testing.expectEqual(@as(SourceId, 0), id1);
    try std.testing.expectEqual(@as(SourceId, 1), id2);
    try std.testing.expectEqual(@as(u16, 2), reg.count);

    const meta1 = reg.lookup(id1).?;
    try std.testing.expectEqualStrings("app.log", meta1.name);
    try std.testing.expectEqual(SourceKind.file, meta1.kind);
    try std.testing.expectEqualStrings("/var/log/app.log", meta1.path.?);

    const meta2 = reg.lookup(id2).?;
    try std.testing.expectEqualStrings("stdin", meta2.name);
    try std.testing.expectEqual(@as(?[]const u8, null), meta2.path);

    try std.testing.expectEqual(@as(?SourceMeta, null), reg.lookup(999));
}
