//! What a project that depends on probe writes. Built by
//! `zig build check-consumer` with only probe's own dependencies to fetch,
//! so probe's build.zig must work without any of its CI dependencies.
const std = @import("std");
const probe = @import("probe");

const Entry = struct {
    seq: u64,
    level: []const u8,
    message: []const u8,
    pub const probe = .{
        .id = .seq,
        .fields = .{
            .level = .{ .keyword = .{ .stored = true } },
            .message = .{ .text = .{ .positions = true } },
        },
    };
};

const Index = probe.Index(Entry);

/// Indexes one entry and finds it again.
fn roundTrip(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    const w = try Index.openWriter(gpa, io, dir, .{});
    defer w.deinit(io);
    try w.add(io, .{ .seq = 1, .level = "ERR", .message = "disk full" });
    var done = try w.commit(io);
    var generation: u64 = undefined;
    done.take(&generation);
    const r = try w.reader();
    defer r.deinit();
    var q = try Index.Query.parse(gpa, .init("level:ERR disk"), .{});
    defer q.deinit();
    var hits = try r.search(io, &q, .{});
    defer hits.deinit();
}

pub fn main() void {
    _ = &roundTrip;
}
