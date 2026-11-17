//! The README's usage, run with the tests.
const std = @import("std");
const probe = @import("probe");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(io, "probe-usage");
    // A directory left behind is named, not fatal: the example has run.
    defer cwd.deleteTree(io, "probe-usage") catch |err| std.log.warn("probe-usage left behind: {t}", .{err});
    const dir = try cwd.createDirPathOpen(io, "probe-usage", .{ .open_options = .{ .iterate = true } });
    defer dir.close(io);
    // --- README:usage ---
    const Entry = struct {
        seq: u64,
        level: []const u8,
        message: []const u8,
        pub const probe = .{
            .id = .seq,
            .fields = .{
                .level = .{ .keyword = .{ .stored = true } },
                .message = .{ .text = .{ .positions = true, .analysis = .words_and_identifiers } },
            },
        };
    };
    const Index = probe.Index(Entry);

    const w = try Index.openWriter(gpa, io, dir, .{});
    defer w.deinit(io);
    try w.add(io, .{ .seq = 1, .level = "ERR", .message = "segment merge failed in parseSpan" });
    try w.add(io, .{ .seq = 2, .level = "INFO", .message = "segment merged" });
    var done = try w.commit(io);
    var generation: u64 = undefined;
    done.take(&generation);

    const r = try Index.openReader(gpa, io, dir, .{});
    defer r.deinit();
    // An identifier's parts find it, as a phrase of words does.
    var q = try Index.Query.parse(gpa, .init("level:ERR \"parse span\""), .{});
    defer q.deinit();
    var hits = try r.search(io, &q, .{});
    defer hits.deinit();
    std.debug.assert(hits.hits.len == 1);
    std.debug.assert(hits.hits[0].id.raw() == 1);
    // The stored fields come back typed.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const stored = try r.stored(io, hits.hits[0], arena.allocator());
    std.debug.assert(std.mem.eql(u8, stored.level, "ERR"));
    // --- README:usage ---
}
