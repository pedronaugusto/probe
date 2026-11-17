//! The merge against the segment writer: segments merged, their deleted
//! documents dropped, are byte for byte the segment built from their live
//! documents in order, since one writer writes both. A source whose
//! postings or stored blocks have any one bit changed refuses the merge,
//! naming the segment and the section. The policy keeps every merge within
//! its cap and the index within its tier and deletes budget.
const std = @import("std");
const shakedown = @import("shakedown");
const merge = @import("merge.zig");
const Opened = @import("Opened.zig");
const Schema = @import("Schema.zig");
const bitmap = @import("encoding.zig").bitmap;
const segment = @import("segment.zig");

const testing = std.testing;
const gen = shakedown.gen;
const io = testing.io;
const files = segment.files;
const write = segment.write;

const schema = [_]Schema.Field{
    .{ .name = "body", .kind = .text, .positions = true, .offsets = true },
    .{ .name = "title", .kind = .text },
    .{ .name = "tag", .kind = .keyword, .stored = true },
    .{ .name = "n", .kind = .numeric, .stored = true },
    .{ .name = "when", .kind = .numeric },
};

const words = [_][]const u8{ "alpha", "beta", "gamma", "parseSpan", "x", "HTTPServer", "delta", "e2e" };
const max_block = 16 * 1024 * 1024 + segment.store.block_bytes;

/// A document's text, its values pointing into it.
const Doc = struct {
    id: u64,
    body: [400]u8 = undefined,
    body_len: usize = 0,
    title: []const u8,
    tag: [1]u8,
    n: u64,
    when: u64,

    fn values(d: *const Doc) [schema.len]write.Value {
        return .{ .{ .text = d.body[0..d.body_len] }, .{ .text = d.title }, .{ .keyword = &d.tag }, .{ .numeric = d.n }, .{ .numeric = d.when } };
    }
};

fn docOf(s: *shakedown.Source) Doc {
    var d: Doc = .{ .id = gen.intRange(s, u64, 0, 30), .title = words[gen.intRange(s, usize, 0, words.len - 1)], .tag = .{"abcd"[gen.intRange(s, usize, 0, 3)]}, .n = gen.int(s, u64), .when = gen.intRange(s, u64, 0, 1000) };
    // Long enough at times that a term passes a postings block and a
    // stored block closes.
    for (0..gen.intRange(s, usize, 0, 40)) |_| {
        const w = words[gen.intRange(s, usize, 0, words.len - 1)];
        if (d.body_len + w.len + 1 > d.body.len) break;
        @memcpy(d.body[d.body_len..][0..w.len], w);
        d.body[d.body_len + w.len] = ' ';
        d.body_len += w.len + 1;
    }
    return d;
}

/// The file of a segment of `docs`.
fn build(gpa: std.mem.Allocator, docs: []const Doc, number: u64) !std.ArrayList(u8) {
    var b: write.Builder = try .init(gpa, &schema, 255);
    defer b.deinit();
    for (docs) |*d| {
        const values = d.values();
        _ = try b.add(.{ .id = d.id, .values = &values });
    }
    return b.finish(number);
}

/// A source of the merge: in memory, or opened from its file.
const Held = union(enum) {
    memory: segment.read.Segment,
    disk: Opened,

    fn open(tmp: std.Io.Dir, file: []const u8, number: u64, docs: u32, disk: bool) !Held {
        const gpa = testing.allocator;
        if (disk) {
            var name_buffer: [files.max_name_bytes]u8 = undefined;
            try tmp.writeFile(io, .{ .sub_path = files.name(&name_buffer, number, .segment, 0), .data = file });
            return .{ .disk = try Opened.open(gpa, io, tmp, &schema, .{ .number = number, .docs = docs }, max_block) };
        }
        const e: files.Expected = .{ .kind = .segment, .segment = number };
        return .{ .memory = try segment.read.Segment.parse(gpa, io, segment.read.inMemory(try e.checkSegment(.init(file))), &schema, max_block) };
    }

    fn input(h: *const Held, number: u64, deleted: ?*const bitmap.Bitmap) merge.Input {
        return switch (h.*) {
            .memory => |*m| .{ .number = number, .segment = m, .deleted = deleted, .table = null },
            .disk => |*o| .{ .number = number, .segment = &o.segment, .deleted = deleted, .table = o.table },
        };
    }

    fn deinit(h: *Held) void {
        switch (h.*) {
            .memory => |*m| m.deinit(testing.allocator),
            .disk => |*o| o.deinit(testing.allocator, io),
        }
    }
};

const max_sources = 4;

fn asBuilt(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var all: [max_sources * 70]Doc = undefined;
    var live: std.ArrayList(Doc) = .empty;
    defer live.deinit(gpa);
    var held: [max_sources]Held = undefined;
    var deleted: [max_sources]?bitmap.Bitmap = @splat(null);
    var inputs: [max_sources]merge.Input = undefined;
    const sources = gen.intRange(s, usize, 1, max_sources);
    // A source held in memory borrows its file's bytes.
    var built: [max_sources]std.ArrayList(u8) = undefined;
    var opened: usize = 0;
    defer for (held[0..opened], deleted[0..opened], built[0..opened]) |*h, *d, *f| {
        h.deinit();
        if (d.*) |*b| b.deinit(gpa);
        f.deinit(gpa);
    };
    var used: usize = 0;
    for (0..sources) |i| {
        const docs = all[used..][0..gen.intRange(s, usize, 1, 70)];
        used += docs.len;
        for (docs) |*d| d.* = docOf(s);
        built[i] = try build(gpa, docs, i);
        held[i] = Held.open(tmp.dir, built[i].items, i, @intCast(docs.len), gen.boolean(s)) catch |err| {
            built[i].deinit(gpa);
            return err;
        };
        opened += 1;
        if (gen.boolean(s)) deleted[i] = try .init(gpa, @intCast(docs.len));
        for (docs, 0..) |d, doc| {
            if (deleted[i]) |*b| if (gen.intRange(s, u8, 0, 3) == 0) {
                b.add(@intCast(doc));
                continue;
            };
            try live.append(gpa, d);
        }
        inputs[i] = held[i].input(i, if (deleted[i]) |*b| b else null);
    }
    var want = try build(gpa, live.items, 99);
    defer want.deinit(gpa);
    var got: std.Io.Writer.Allocating = .init(gpa);
    defer got.deinit();
    const docs = try merge.merge(gpa, io, &schema, 255, inputs[0..sources], &got.writer, 99, null);
    try testing.expectEqual(live.items.len, docs);
    try testing.expectEqualSlices(u8, want.items, got.written());
}

test "segments merged are the segment built from their live documents, byte for byte" {
    try shakedown.check(testing.allocator, {}, asBuilt, .{ .seed = 0x6d657267, .cases = 120 });
}

fn flipped(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var docs: [60]Doc = undefined;
    const counts = [2]usize{ gen.intRange(s, usize, 1, 30), gen.intRange(s, usize, 1, 30) };
    var held: [2]Held = undefined;
    var opened: usize = 0;
    defer for (held[0..opened]) |*h| h.deinit();
    var inputs: [2]merge.Input = undefined;
    // One source, segment 7 or 8, has one bit changed in its postings or
    // its store: sections read as they are asked for, so it opens.
    const damaged = gen.intRange(s, usize, 0, 1);
    const section = gen.enumValue(s, enum { postings, store });
    var start: usize = 0;
    for (counts, 0..) |n, i| {
        const these = docs[start..][0..n];
        start += n;
        for (these) |*d| d.* = docOf(s);
        var file = try build(gpa, these, 7 + i);
        defer file.deinit(gpa);
        if (i == damaged) {
            const e: files.Expected = .{ .kind = .segment, .segment = 7 + i };
            const sections = try e.checkSegment(.init(file.items));
            const bytes = sections[
                @backingInt(@as(files.Section, switch (section) {
                    .postings => .postings,
                    .store => .store,
                }))
            ];
            const at = @intFromPtr(bytes.ptr) - @intFromPtr(file.items.ptr) + gen.intRange(s, usize, 0, bytes.len - 1);
            file.items[at] ^= @as(u8, 1) << gen.intRange(s, u3, 0, 7);
        }
        held[i] = Held.open(tmp.dir, file.items, 7 + i, @intCast(n), true) catch |err| {
            // A stored block's table is read whole when the store opens.
            try testing.expectEqual(error.Corrupt, err);
            try testing.expect(section == .store);
            return;
        };
        opened += 1;
        inputs[i] = held[i].input(7 + i, null);
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var diagnostic: merge.Diagnostic = .{};
    try testing.expectError(error.Corrupt, merge.merge(gpa, io, &schema, 255, &inputs, &out.writer, 9, &diagnostic));
    try testing.expectEqual(@as(u64, 7 + damaged), diagnostic.segment);
    try testing.expectEqual(@as(files.Section, switch (section) {
        .postings => .postings,
        .store => .store,
    }), diagnostic.section);
}

test "a source with one bit of its postings or stored blocks changed refuses the merge, named" {
    try shakedown.check(testing.allocator, {}, flipped, .{ .seed = 0x666c6970, .cases = 400 });
}

const Size = merge.Policy.Size;

/// The segments `merged` takes the place of, as one segment of their live
/// documents and bytes.
fn applied(sizes: *std.ArrayList(Size), merged: []const usize) Size {
    var into: Size = .{ .bytes = 0, .docs = 0, .deleted = 0 };
    var i = merged.len;
    while (i > 0) {
        i -= 1;
        const s = sizes.orderedRemove(merged[i]);
        into.bytes += merge.Policy.liveBytes(s);
        into.docs += s.docs - s.deleted;
    }
    return into;
}

fn policyHolds(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    const p: merge.Policy = .{
        .max_merged_bytes = gen.intRange(s, u64, 2_000, 200_000),
        .segments_per_tier = gen.intRange(s, u8, 2, 12),
        .max_merge_at_once = gen.intRange(s, u8, 2, 12),
        .floor_bytes = gen.intRange(s, u64, 1, 2_000),
        .deletes_pct_allowed = gen.intRange(s, u8, 5, 50),
    };
    var sizes: std.ArrayList(Size) = .empty;
    defer sizes.deinit(gpa);
    var out: std.ArrayList(usize) = .empty;
    defer out.deinit(gpa);
    for (0..gen.intRange(s, usize, 1, 300)) |_| {
        if (sizes.items.len == 0 or gen.intRange(s, u8, 0, 2) != 0) {
            // A flush: a segment of new documents.
            const docs = gen.intRange(s, u32, 1, 40);
            try sizes.append(gpa, .{ .bytes = @as(u64, docs) * gen.intRange(s, u64, 20, 200), .docs = docs, .deleted = 0 });
        } else {
            // Deletes in one segment; one with none live leaves the index.
            const at = gen.intRange(s, usize, 0, sizes.items.len - 1);
            const seg = &sizes.items[at];
            seg.deleted += gen.intRange(s, u32, 1, seg.docs - seg.deleted);
            if (seg.deleted == seg.docs) _ = sizes.orderedRemove(at);
        }
        // Merges until none is due.
        var merges: usize = 0;
        while (true) : (merges += 1) {
            try testing.expect(merges < 10_000);
            try out.resize(gpa, sizes.items.len);
            const chosen = p.choose(sizes.items, out.items);
            if (chosen.len == 0) break;
            var live: u64 = 0;
            for (chosen) |c| live += merge.Policy.liveBytes(sizes.items[c]);
            if (chosen.len > 1) {
                // No merge of several passes the cap.
                try testing.expect(live <= p.max_merged_bytes);
                try testing.expect(chosen.len <= @min(p.max_merge_at_once, p.segments_per_tier));
            } else {
                // A segment written again alone reclaims its deletes.
                try testing.expect(sizes.items[chosen[0]].deleted > 0);
            }
            try sizes.append(gpa, applied(&sizes, chosen));
        }
        // At rest the index is within its budget: the segments the tiers
        // allow, and the deletes allowed, of those not left alone.
        const b = p.budget(sizes.items);
        var counted: u64 = 0;
        var deleted: u64 = 0;
        for (sizes.items) |seg| {
            const alone = merge.Policy.liveBytes(seg) > p.max_merged_bytes / 2 and @as(u64, seg.deleted) * 100 <= @as(u64, seg.docs) * p.deletes_pct_allowed;
            if (alone) continue;
            counted += 1;
            deleted += seg.deleted;
        }
        try testing.expect(counted <= b.segments);
        try testing.expect(deleted <= b.deleted);
    }
}

test "the policy: no merge past the cap, and at rest the segments within the tier budget and their deletes within the allowance" {
    try shakedown.check(testing.allocator, {}, policyHolds, .{ .seed = 0x74696572, .cases = 300 });
}

test "the policy merges the lowest scored run, skipping a segment too large to join it" {
    const p: merge.Policy = .{ .max_merged_bytes = 1000, .segments_per_tier = 2, .max_merge_at_once = 2, .floor_bytes = 10, .deletes_pct_allowed = 20 };
    var out: [8]usize = undefined;
    // Five of one size: more than the tiers allow; the two equal merge.
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, p.choose(&.{
        .{ .bytes = 100, .docs = 10, .deleted = 0 },
        .{ .bytes = 100, .docs = 10, .deleted = 0 },
        .{ .bytes = 100, .docs = 10, .deleted = 0 },
        .{ .bytes = 100, .docs = 10, .deleted = 0 },
        .{ .bytes = 100, .docs = 10, .deleted = 0 },
    }, &out));
    // A segment past half the cap with few deletes is left alone; one with
    // deletes past the allowance joins what fits under the cap, or with
    // nothing that fits is written again alone.
    try testing.expectEqualSlices(usize, &.{}, p.choose(&.{ .{ .bytes = 900, .docs = 100, .deleted = 10 }, .{ .bytes = 50, .docs = 10, .deleted = 0 } }, &out));
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, p.choose(&.{ .{ .bytes = 900, .docs = 100, .deleted = 30 }, .{ .bytes = 50, .docs = 10, .deleted = 0 } }, &out));
    try testing.expectEqualSlices(usize, &.{0}, p.choose(&.{ .{ .bytes = 1000, .docs = 100, .deleted = 45 }, .{ .bytes = 900, .docs = 100, .deleted = 0 } }, &out));
    // Within the budget, nothing is due.
    try testing.expectEqualSlices(usize, &.{}, p.choose(&.{ .{ .bytes = 100, .docs = 10, .deleted = 0 }, .{ .bytes = 20, .docs = 2, .deleted = 0 } }, &out));
}
