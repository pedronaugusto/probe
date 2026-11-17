//! The writer against a model of the documents it holds: any run of adds,
//! deletes, updates, refreshes, commits and reopens leaves the segments
//! holding exactly the model's live documents, a reopen exactly the last
//! commit's, and the directory no manifest past the retention nor a file
//! none of the kept manifests names. A second writer is refused while the
//! first holds the lock.
const std = @import("std");
const shakedown = @import("shakedown");
const Writer = @import("Writer.zig");
const Manifest = @import("Manifest.zig");
const Schema = @import("Schema.zig");
const segment = @import("segment.zig");

const testing = std.testing;
const gen = shakedown.gen;
const io = testing.io;

const schema = [_]Schema.Field{
    .{ .name = "body", .kind = .text, .positions = true },
    .{ .name = "serial", .kind = .keyword, .stored = true },
};

const words = [_][]const u8{ "alpha", "beta", "gamma delta", "parseSpan", "x" };

/// A document of the model: its id and the serial that tells it apart.
const Doc = struct { id: u64, serial: u32 };

fn lessThan(_: void, a: Doc, b: Doc) bool {
    return a.id < b.id or (a.id == b.id and a.serial < b.serial);
}

/// What the writer's segments hold, deleted documents left out, sorted.
fn held(w: *Writer, out: *std.ArrayList(Doc)) !void {
    const gpa = testing.allocator;
    out.clearRetainingCapacity();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);
    for (w.live.items) |*l| {
        const seg = switch (l.held) {
            .opened => |*o| &o.segment,
            .fresh => |*f| &f.segment,
        };
        for (0..l.docs) |d| {
            const doc: u32 = @intCast(d);
            if (l.deleted) |deleted| if (deleted.has(doc)) continue;
            var values: [1]segment.store.Value = undefined;
            try seg.storedOf(io, gpa, doc, &buffer, &values);
            try out.append(gpa, .{ .id = seg.idOf(doc), .serial = try std.fmt.parseInt(u32, values[0].bytes, 10) });
        }
    }
    std.mem.sort(Doc, out.items, {}, lessThan);
}

fn expectHolds(w: *Writer, model: []const Doc) !void {
    const gpa = testing.allocator;
    var want: std.ArrayList(Doc) = .empty;
    defer want.deinit(gpa);
    try want.appendSlice(gpa, model);
    std.mem.sort(Doc, want.items, {}, lessThan);
    var got: std.ArrayList(Doc) = .empty;
    defer got.deinit(gpa);
    try held(w, &got);
    try testing.expectEqualSlices(Doc, want.items, got.items);
}

/// The directory holds at most `keep` manifests, and no segment file that
/// none of them names.
fn expectPruned(dir: std.Io.Dir, keep: u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var generations: std.ArrayList(u64) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (Manifest.generationOf(entry.name)) |g| try generations.append(a, g);
    }
    try testing.expect(generations.items.len <= keep);
    var numbers: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var deletions: std.AutoHashMapUnmanaged([2]u64, void) = .empty;
    for (generations.items) |g| {
        var name_buffer: [Manifest.name_bytes]u8 = undefined;
        const bytes = try dir.readFileAlloc(io, Manifest.name(&name_buffer, g), a, .unlimited);
        const m = try Manifest.parse(a, .init(bytes), .{ .generation = g, .fields = &schema, .term_bytes = 255 });
        for (m.segments) |s| {
            try numbers.put(a, s.number, {});
            if (s.deletions) |d| try deletions.put(a, .{ s.number, d.generation }, {});
        }
    }
    it = dir.iterate();
    while (try it.next(io)) |entry| {
        const n = segment.files.parseName(entry.name) orelse continue;
        try testing.expect(numbers.contains(n.segment));
        if (n.kind == .deletions) try testing.expect(deletions.contains(.{ n.segment, n.generation }));
    }
}

const Op = enum { add, delete, update, refresh, commit, reopen };

fn againstModel(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const keep = gen.intRange(s, u8, 1, 3);
    const options: Writer.Options = .{ .keep_commits = keep, .buffer_bytes = gen.intRange(s, usize, 20, 400) };
    var w: Writer = try .open(gpa, io, tmp.dir, &schema, options);
    defer w.deinit(io);
    // The live documents now, and as of the last commit.
    var current: std.ArrayList(Doc) = .empty;
    defer current.deinit(gpa);
    var committed: std.ArrayList(Doc) = .empty;
    defer committed.deinit(gpa);
    var serial: u32 = 0;
    for (0..gen.intRange(s, usize, 1, 60)) |_| {
        const id = gen.intRange(s, u64, 0, 9);
        switch (gen.enumValue(s, Op)) {
            .add, .update => |op| {
                if (op == .update) try deleteFrom(&current, id);
                var serial_text: [10]u8 = undefined;
                const values = [_]segment.write.Value{
                    .{ .text = words[gen.intRange(s, usize, 0, words.len - 1)] },
                    .{ .keyword = try std.mem.print(&serial_text, "{d}", .{serial}) },
                };
                const doc: segment.write.Document = .{ .id = id, .values = &values };
                if (op == .update) try w.update(io, doc) else try w.add(io, doc);
                try current.append(gpa, .{ .id = id, .serial = serial });
                serial += 1;
            },
            .delete => {
                try w.delete(id);
                try deleteFrom(&current, id);
            },
            .refresh => {
                try w.refresh(io);
                try expectHolds(&w, current.items);
            },
            .commit => {
                _ = try w.commit(io);
                committed.clearRetainingCapacity();
                try committed.appendSlice(gpa, current.items);
                try expectHolds(&w, current.items);
                try expectPruned(tmp.dir, keep);
            },
            .reopen => {
                w.deinit(io);
                w = try .open(gpa, io, tmp.dir, &schema, options);
                current.clearRetainingCapacity();
                try current.appendSlice(gpa, committed.items);
                try expectHolds(&w, committed.items);
            },
        }
    }
}

fn deleteFrom(docs: *std.ArrayList(Doc), id: u64) !void {
    var kept: usize = 0;
    for (docs.items) |d| {
        if (d.id == id) continue;
        docs.items[kept] = d;
        kept += 1;
    }
    docs.shrinkRetainingCapacity(kept);
}

test "a writer's segments hold its model's documents through adds, deletes, updates, refreshes, commits and reopens" {
    try shakedown.check(testing.allocator, {}, againstModel, .{ .seed = 0x77726974, .cases = 150 });
}

test "a second writer of a directory is refused while the first holds its lock" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = try .open(testing.allocator, io, tmp.dir, &schema, .{});
    try testing.expectError(error.Locked, Writer.open(testing.allocator, io, tmp.dir, &schema, .{}));
    w.deinit(io);
    var again: Writer = try .open(testing.allocator, io, tmp.dir, &schema, .{});
    again.deinit(io);
}

test "an index opened with another schema is refused" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = try .open(testing.allocator, io, tmp.dir, &schema, .{});
    _ = try w.commit(io);
    w.deinit(io);
    var mismatch: Manifest.Mismatch = .{};
    try testing.expectError(error.SchemaMismatch, Writer.open(testing.allocator, io, tmp.dir, schema[0..1], .{ .mismatch = &mismatch }));
    // The first field that differs: one the index recorded and was not asked for.
    const f = mismatch.what.field;
    try testing.expectEqual(@as(usize, 1), f.place);
    try testing.expectEqualStrings("serial", f.recorded.?.name);
    try testing.expectEqual(null, f.asked);
}
