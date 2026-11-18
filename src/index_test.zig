//! The index of a document type, as a program uses it: documents added and
//! committed, a snapshot searched by a query parsed or built, hits sorted
//! and paged, totals counted to a threshold, stored fields read back typed,
//! a hit of another snapshot refused, an index that will not open saying
//! why and where, and an aegis instant as a numeric field.
const std = @import("std");
const aegis = @import("aegis");
const probe = @import("probe.zig");

const testing = std.testing;
const io = testing.io;

const Entry = struct {
    seq: aegis.id.Id(Entry, u64),
    at: i64,
    level: []const u8,
    message: []const u8,
    note: []const u8 = "",

    pub const probe = .{
        .id = .seq,
        .fields = .{
            .at = .{ .numeric = .{ .stored = true } },
            .level = .{ .keyword = .{ .stored = true } },
            .message = .{ .text = .{ .positions = true, .analysis = .words_and_identifiers, .stored = true } },
        },
    };
};

const Index = probe.Index(Entry);

fn entry(seq: u64, at: i64, level: []const u8, message: []const u8) Entry {
    return .{ .seq = .fromRaw(seq), .at = at, .level = level, .message = message };
}

const entries = [_]Entry{
    entry(1, -20, "INFO", "segment merge started"),
    entry(2, -10, "ERR", "segment merge failed in parseSpan"),
    entry(3, 0, "ERR", "merge of the segment failed"),
    entry(4, 10, "WARN", "parse span slow"),
    entry(5, 20, "ERR", "disk full"),
};

fn committed(w: *Index.Writer) !u64 {
    var result = try w.commit(io);
    var generation: u64 = undefined;
    result.take(&generation);
    return generation;
}

fn filled(dir: std.Io.Dir) !*Index.Writer {
    const w = try Index.openWriter(testing.allocator, io, dir, .{ .durability = .none });
    errdefer w.deinit(io);
    for (entries) |e| try w.add(io, e);
    _ = try committed(w);
    return w;
}

fn parsed(text: []const u8) !Index.Query {
    return Index.Query.parse(testing.allocator, .init(text), .{});
}

fn seqs(hits: []const Index.Hit, out: []u64) []u64 {
    for (hits, out[0..hits.len]) |h, *o| o.* = h.id.raw();
    return out[0..hits.len];
}

test "a program adds, commits, searches and reads back its documents typed" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const w = try filled(tmp.dir);
    defer w.deinit(io);
    const r = try Index.openReader(testing.allocator, io, tmp.dir, .{});
    defer r.deinit();
    var q = try parsed("level:ERR \"segment failed\"~3");
    defer q.deinit();
    var hits = try r.search(io, &q, .{});
    defer hits.deinit();
    var buffer: [8]u64 = undefined;
    // Exact in 3, one position longer in 2.
    try testing.expectEqualSlices(u64, &.{ 3, 2 }, seqs(hits.hits, &buffer));
    try testing.expectEqual(probe.Total{ .value = 2, .relation = .exact }, hits.total);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s: Index.Stored = try r.stored(io, hits.hits[0], arena.allocator());
    try testing.expectEqualStrings("ERR", s.level);
    try testing.expectEqualStrings("merge of the segment failed", s.message);
    try testing.expectEqual(@as(i64, 0), s.at);
    // Only the stored fields: `seq` and `note` are not among them.
    try testing.expect(!@hasField(Index.Stored, "note") and !@hasField(Index.Stored, "seq"));
}

test "a query built in code finds what its text finds" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const w = try filled(tmp.dir);
    defer w.deinit(io);
    const r = try w.reader();
    defer r.deinit();
    var b: Index.Query.Builder = .init(testing.allocator);
    defer b.deinit();
    const clause = try b.@"and"(&.{
        try b.term(.message, "parseSpan"),
        try b.not(try b.term(.level, "WARN")),
        b.range(.at, -15, null),
    });
    var built = try b.build(clause);
    defer built.deinit();
    var text = try parsed("message:parseSpan -level:WARN at:[-15 TO *]");
    defer text.deinit();
    try testing.expectEqual(@as(u64, 1), try r.count(io, &built));
    try testing.expectEqual(try r.count(io, &text), try r.count(io, &built));
}

test "hits sort by a numeric field and page by cursor, the pages the whole list" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const w = try filled(tmp.dir);
    defer w.deinit(io);
    const r = try w.reader();
    defer r.deinit();
    var q = try parsed("*");
    defer q.deinit();
    const sort: Index.Sort = .{ .field = .{ .by = .at, .order = .descending } };
    var whole = try r.search(io, &q, .{ .top = .literal(10), .sort = sort });
    defer whole.deinit();
    var buffer: [8]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{ 5, 4, 3, 2, 1 }, seqs(whole.hits, &buffer));
    var paged: std.ArrayList(u64) = .empty;
    defer paged.deinit(testing.allocator);
    var after: ?Index.Cursor = null;
    while (true) {
        var page = try r.search(io, &q, .{ .top = .literal(2), .sort = sort, .after = after });
        defer page.deinit();
        for (page.hits) |h| try paged.append(testing.allocator, h.id.raw());
        after = page.next orelse break;
    }
    try testing.expectEqualSlices(u64, &.{ 5, 4, 3, 2, 1 }, paged.items);
    // By score, the pages are the best hits in order too.
    var words = try parsed("segment OR merge OR failed");
    defer words.deinit();
    var best = try r.search(io, &words, .{ .top = .literal(10) });
    defer best.deinit();
    paged.clearRetainingCapacity();
    after = null;
    while (true) {
        var page = try r.search(io, &words, .{ .top = .literal(1), .after = after });
        defer page.deinit();
        for (page.hits) |h| try paged.append(testing.allocator, h.id.raw());
        after = page.next orelse break;
    }
    try testing.expectEqualSlices(u64, seqs(best.hits, &buffer), paged.items);
}

test "a total is exact up to the threshold and at least it past" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const w = try Index.openWriter(testing.allocator, io, tmp.dir, .{ .durability = .none });
    defer w.deinit(io);
    for (0..300) |i| try w.add(io, entry(i + 1, @intCast(i), "INFO", if (i % 50 == 0) "rare common" else "common"));
    try w.refresh(io);
    const r = try w.reader();
    defer r.deinit();
    // A disjunction runs WAND: its total is counted by matching.
    var q = try parsed("rare OR common");
    defer q.deinit();
    var capped = try r.search(io, &q, .{ .top = .literal(3), .count_up_to = 100 });
    defer capped.deinit();
    try testing.expectEqual(probe.Total{ .value = 100, .relation = .at_least }, capped.total);
    var exact = try r.search(io, &q, .{ .top = .literal(3), .count_up_to = std.math.maxInt(u64) });
    defer exact.deinit();
    try testing.expectEqual(probe.Total{ .value = 300, .relation = .exact }, exact.total);
    try testing.expectEqual(@as(u64, 300), try r.count(io, &q));
}

test "a hit is read only by the snapshot it came from" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const w = try filled(tmp.dir);
    defer w.deinit(io);
    const old = try Index.openReader(testing.allocator, io, tmp.dir, .{});
    defer old.deinit();
    var q = try parsed("disk");
    defer q.deinit();
    var hits = try old.search(io, &q, .{});
    defer hits.deinit();
    try w.add(io, entry(6, 30, "INFO", "disk ok"));
    _ = try committed(w);
    const new = try old.reopen(io);
    defer new.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.StaleHit, new.stored(io, hits.hits[0], arena.allocator()));
    try testing.expectError(error.StaleHit, new.search(io, &q, .{ .after = hits.next orelse Index.Cursor{ .segment = hits.hits[0].segment, .last = .{ .segment = 0, .doc = 0, .score = 0 } } }));
    _ = try old.stored(io, hits.hits[0], arena.allocator());
}

const Other = struct {
    seq: u64,
    level: []const u8,
    pub const probe = .{ .id = .seq, .fields = .{ .level = .{ .keyword = .{} } } };
};

test "an index that does not open says why, and on which file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        const w = try filled(tmp.dir);
        defer w.deinit(io);
        try testing.expectError(error.Locked, Index.openWriter(testing.allocator, io, tmp.dir, .{}));
    }
    var d: probe.OpenDiagnostic = .{};
    try testing.expectError(error.SchemaMismatch, probe.Index(Other).openReader(testing.allocator, io, tmp.dir, .{ .diagnostic = &d }));
    try testing.expectEqualStrings("at", d.mismatch.what.field.recorded.?.name);
    // A segment file cut short: refused, and named.
    var it = tmp.dir.iterate();
    const name = while (try it.next(io)) |e| {
        if (std.mem.endsWith(u8, e.name, ".seg")) break try testing.allocator.dupe(u8, e.name);
    } else return error.NoSegment;
    defer testing.allocator.free(name);
    const file = try tmp.dir.openFile(io, name, .{ .mode = .read_write });
    try file.setLength(io, 40);
    file.close(io);
    d = .{};
    try testing.expectError(error.Corrupt, Index.openReader(testing.allocator, io, tmp.dir, .{ .diagnostic = &d }));
    try testing.expectEqualStrings(name, d.file().?);
}

test "a document whose text passes the limit is refused before it is analyzed" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const w = try Index.openWriter(testing.allocator, io, tmp.dir, .{ .durability = .none, .limits = .{ .document_bytes = 8 } });
    defer w.deinit(io);
    try testing.expectError(error.FieldTooLong, w.add(io, entry(1, 0, "ERR", "too long a message")));
    try w.add(io, entry(2, 0, "ERR", "short"));
}

const Event = struct {
    seq: u64,
    at: aegis.units.Instant(.real, .millisecond, i64),
    what: []const u8,
    pub const probe = .{ .id = .seq, .fields = .{ .at = .{ .numeric = .{ .stored = true } }, .what = .{ .text = .{} } } };
};

test "an aegis instant is a numeric field: ranged in its own type, sorted by, read back typed" {
    const Events = probe.Index(Event);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const w = try Events.openWriter(testing.allocator, io, tmp.dir, .{ .durability = .none });
    defer w.deinit(io);
    for ([_]i64{ 1500, -2000, 0, -1 }, 1..) |ms, seq| try w.add(io, .{ .seq = seq, .at = .fromRaw(ms), .what = "tick" });
    var result = try w.commit(io);
    var generation: u64 = undefined;
    result.take(&generation);
    const r = try w.reader();
    defer r.deinit();
    var b: Events.Query.Builder = .init(testing.allocator);
    defer b.deinit();
    // From a millisecond before the epoch on: the signed order holds.
    var q = try b.build(b.range(.at, .fromRaw(-1), null));
    defer q.deinit();
    var hits = try r.search(io, &q, .{ .sort = .{ .field = .{ .by = .at, .order = .ascending } } });
    defer hits.deinit();
    var buffer: [4]u64 = undefined;
    for (hits.hits, buffer[0..hits.hits.len]) |h, *o| o.* = h.id.raw();
    try testing.expectEqualSlices(u64, &.{ 4, 3, 1 }, buffer[0..hits.hits.len]);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const stored = try r.stored(io, hits.hits[0], arena.allocator());
    try testing.expectEqual(@as(i64, -1), stored.at.raw());
}
