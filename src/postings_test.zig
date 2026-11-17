//! One term's postings against a list: read back whole, advanced to any
//! targets, each block's impacts its competitive pairs and a bound on every
//! posting of it; and any bytes, or a damaged list, read within the segment.
const std = @import("std");
const shakedown = @import("shakedown");
const postings = @import("segment.zig").postings;
const Files = @import("sources_test.zig").Files;
const varint = @import("encoding/varint.zig");

const testing = std.testing;
const gen = shakedown.gen;
const io = testing.io;
const Posting = postings.Posting;
const Impact = postings.Impact;

const max_docs = 3000;

const Model = struct {
    docs: u32,
    list: []Posting,
    lengths: ?[]u32,
};

fn model(s: *shakedown.Source, list_buffer: []Posting, length_buffer: []u32) Model {
    const docs = gen.intRange(s, u32, 1, max_docs);
    // Around a block's edges as often as anywhere else.
    const edges = [_]u32{ 1, 2, 127, 128, 129, 255, 256, 257, 384 };
    const wanted = if (gen.boolean(s)) edges[gen.intRange(s, usize, 0, edges.len - 1)] else gen.intRange(s, u32, 1, 700);
    const df = @min(wanted, docs);
    // `df` docs of `docs`, rising: each kept with the odds it still needs.
    var n: u32 = 0;
    var doc: u32 = 0;
    while (n < df) : (doc += 1) {
        const left = docs - doc;
        if (left > df - n and gen.intRange(s, u32, 0, left - 1) >= df - n) continue;
        const freq = switch (gen.intRange(s, u8, 0, 9)) {
            0 => gen.int(s, u32) | 1,
            1, 2 => gen.intRange(s, u32, 1, 1000),
            else => gen.intRange(s, u32, 1, 4),
        };
        list_buffer[n] = .{ .doc = doc, .freq = @max(freq, 1) };
        n += 1;
    }
    const keyword = gen.intRange(s, u8, 0, 4) == 0;
    for (length_buffer[0..docs]) |*l| l.* = switch (gen.intRange(s, u8, 0, 9)) {
        0 => gen.int(s, u32),
        else => gen.intRange(s, u32, 1, 40),
    };
    return .{ .docs = docs, .list = list_buffer[0..df], .lengths = if (keyword) null else length_buffer[0..docs] };
}

fn lengthOf(m: Model, doc: u32) u32 {
    return if (m.lengths) |l| l[doc] else 1;
}

fn dominates(a: Impact, b: Impact) bool {
    return a.freq >= b.freq and a.length <= b.length;
}

/// The block's competitive pairs by brute force, frequency rising.
fn competitive(m: Model, block: []const Posting, out: []Impact) []Impact {
    var n: usize = 0;
    for (block, 0..) |p, i| {
        const pair: Impact = .{ .freq = p.freq, .length = lengthOf(m, p.doc) };
        var beaten = false;
        for (block, 0..) |q, j| {
            const other: Impact = .{ .freq = q.freq, .length = lengthOf(m, q.doc) };
            if (i != j and dominates(other, pair) and (other.freq != pair.freq or other.length != pair.length)) beaten = true;
        }
        for (out[0..n]) |seen| if (seen.freq == pair.freq and seen.length == pair.length) {
            beaten = true;
        };
        if (!beaten) {
            out[n] = pair;
            n += 1;
        }
    }
    std.mem.sort(Impact, out[0..n], {}, struct {
        fn less(_: void, a: Impact, b: Impact) bool {
            return a.freq < b.freq;
        }
    }.less);
    return out[0..n];
}

fn againstList(files: *Files, case: *shakedown.Case) anyerror!void {
    defer files.close();
    const s = case.source;
    const gpa = testing.allocator;
    var list_buffer: [700]Posting = undefined;
    var length_buffer: [max_docs]u32 = undefined;
    const m = model(s, &list_buffer, &length_buffer);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    // Something before, so the reader starts at an address, and after.
    try bytes.appendSlice(gpa, "head");
    try postings.write(gpa, &bytes, m.list, m.lengths);
    try bytes.appendSlice(gpa, "tail");
    const source = try files.source(bytes.items, gen.boolean(s));

    // Read whole, with each block's impacts.
    var r = try postings.Reader.init(source, io, 4, m.docs);
    try testing.expectEqual(@as(u32, @intCast(m.list.len)), r.docFreq());
    var block_start: usize = 0;
    for (m.list, 0..) |want, i| {
        const got = (try r.next()) orelse return error.TestExpectedEqual;
        try testing.expectEqual(want, got);
        if (i % 128 == 0) block_start = i;
        const block = m.list[block_start..@min(block_start + 128, m.list.len)];
        try testing.expectEqual(block[block.len - 1].doc, r.blockLast());
        const impacts = r.impacts();
        try testing.expect(impacts.len >= 1 and impacts.len <= postings.max_impacts);
        // Every posting of the block is bounded by an impact.
        const pair: Impact = .{ .freq = got.freq, .length = lengthOf(m, got.doc) };
        for (impacts) |imp| {
            if (dominates(imp, pair)) break;
        } else return error.TestUnexpectedResult;
        // The impacts are the competitive pairs, or past eight the one loose pair.
        if (i == block_start) {
            var expected_buffer: [128]Impact = undefined;
            const expected = competitive(m, block, &expected_buffer);
            if (expected.len <= postings.max_impacts) {
                try testing.expectEqualSlices(Impact, expected, impacts);
            } else {
                var top: Impact = .{ .freq = 0, .length = std.math.maxInt(u32) };
                for (expected) |e| top = .{ .freq = @max(top.freq, e.freq), .length = @min(top.length, e.length) };
                try testing.expectEqualSlices(Impact, &.{top}, impacts);
            }
        }
    }
    try testing.expectEqual(null, try r.next());
    try testing.expectEqual(null, try r.next());

    // Advanced to rising targets, with a next between some: always the first
    // posting at or past the target from where the reader stands.
    var a = try postings.Reader.init(source, io, 4, m.docs);
    var at: usize = 0;
    var target: u32 = 0;
    while (true) {
        target += gen.intRange(s, u32, 0, 300);
        if (gen.intRange(s, u8, 0, 3) == 0) {
            const got = try a.next();
            if (at == m.list.len) {
                try testing.expectEqual(null, got);
                break;
            }
            try testing.expectEqual(m.list[at], got.?);
            at += 1;
            target = @max(target, m.list[at - 1].doc);
            continue;
        }
        while (at < m.list.len and m.list[at].doc < target) at += 1;
        const got = try a.advance(target);
        if (at == m.list.len) {
            try testing.expectEqual(null, got);
            break;
        }
        try testing.expectEqual(m.list[at], got.?);
        at += 1;
    }
}

test "a term's postings read back as written, advance to any target, and each block's impacts are its competitive pairs" {
    var files: Files = .init();
    defer files.deinit();
    try shakedown.check(testing.allocator, &files, againstList, .{ .seed = 0x706f7374, .cases = 1500 });
}

fn impactsOf(list: []const Posting, lengths: []const u32, docs: u32, out: *[postings.max_impacts]Impact) ![]const Impact {
    const gpa = testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try postings.write(gpa, &bytes, list, lengths);
    var r = try postings.Reader.init(.{ .memory = bytes.items }, io, 0, docs);
    _ = try r.next();
    const kept = r.impacts();
    @memcpy(out[0..kept.len], kept);
    return out[0..kept.len];
}

test "the pair of the highest frequency is kept whatever its length, the longest there is included" {
    const max = std.math.maxInt(u32);
    var out: [postings.max_impacts]Impact = undefined;
    try testing.expectEqualSlices(Impact, &.{ .{ .freq = 1, .length = 3 }, .{ .freq = 5, .length = max } }, try impactsOf(&.{ .{ .doc = 0, .freq = 5 }, .{ .doc = 1, .freq = 1 } }, &.{ max, 3 }, 2, &out));
}

test "past eight competitive pairs a block keeps one: its highest frequency and shortest length" {
    var list: [9]Posting = undefined;
    var lengths: [9]u32 = undefined;
    for (&list, &lengths, 0..) |*p, *l, i| {
        p.* = .{ .doc = @intCast(i), .freq = @intCast(i + 1) };
        l.* = @intCast(i + 1);
    }
    var out: [postings.max_impacts]Impact = undefined;
    try testing.expectEqualSlices(Impact, &.{.{ .freq = 9, .length = 1 }}, try impactsOf(&list, &lengths, 9, &out));
    // Eight are kept as they are.
    try testing.expectEqual(@as(usize, 8), (try impactsOf(list[0..8], lengths[0..8], 8, &out)).len);
}

/// Every posting read from `r` lies in the segment and rises.
fn readsWithin(r: *postings.Reader, docs: u32) !void {
    var last: ?u32 = null;
    var n: u32 = 0;
    while (r.next() catch return) |p| {
        try testing.expect(p.doc < docs and p.freq >= 1);
        if (last) |l| try testing.expect(p.doc > l);
        last = p.doc;
        n += 1;
        try testing.expect(n <= r.docFreq());
    }
}

fn anyBytes(files: *Files, case: *shakedown.Case) anyerror!void {
    defer files.close();
    const s = case.source;
    var buffer: [512]u8 = undefined;
    const bytes = gen.bytesInto(s, &buffer);
    const docs = gen.intRange(s, u32, 1, 5000);
    const source = try files.source(bytes, gen.boolean(s));
    const address = gen.intRange(s, u64, 0, bytes.len);
    var r = postings.Reader.init(source, io, address, docs) catch return;
    try readsWithin(&r, docs);
    var a = postings.Reader.init(source, io, address, docs) catch return;
    _ = a.advance(gen.intRange(s, u32, 0, docs)) catch return;
}

test "fuzz: any bytes are refused as postings, or read within the segment, rising" {
    var files: Files = .init();
    defer files.deinit();
    try shakedown.check(testing.allocator, &files, anyBytes, .{ .seed = 0x66757a7a, .cases = 3000 });
}

fn damaged(files: *Files, case: *shakedown.Case) anyerror!void {
    defer files.close();
    const s = case.source;
    const gpa = testing.allocator;
    var list_buffer: [700]Posting = undefined;
    var length_buffer: [max_docs]u32 = undefined;
    const m = model(s, &list_buffer, &length_buffer);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try postings.write(gpa, &bytes, m.list, m.lengths);
    for (0..gen.intRange(s, usize, 1, 4)) |_| {
        const at = gen.intRange(s, usize, 0, bytes.items.len - 1);
        bytes.items[at] = gen.int(s, u8);
    }
    if (gen.boolean(s)) bytes.shrinkRetainingCapacity(gen.intRange(s, usize, 0, bytes.items.len));
    var r = postings.Reader.init(try files.source(bytes.items, gen.boolean(s)), io, 0, m.docs) catch return;
    try readsWithin(&r, m.docs);
}

test "fuzz: damaged postings are refused, or read within the segment, rising" {
    var files: Files = .init();
    defer files.deinit();
    try shakedown.check(testing.allocator, &files, damaged, .{ .seed = 0x64616d67, .cases = 2000 });
}

test "skip entries that end before their length says are refused" {
    const gpa = testing.allocator;
    var list: [300]Posting = undefined;
    for (&list, 0..) |*p, i| p.* = .{ .doc = @intCast(i * 2), .freq = 1 };
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try postings.write(gpa, &bytes, &list, null);
    var r = try postings.Reader.init(.{ .memory = bytes.items }, io, 0, 600);
    while (try r.next()) |_| {}
    // The same postings with a byte after the entries, their length one more.
    var at: usize = 0;
    _ = try varint.read(bytes.items, &at);
    const len_at = at;
    const skip_bytes = try varint.read(bytes.items, &at);
    var padded: std.ArrayList(u8) = .empty;
    defer padded.deinit(gpa);
    try padded.appendSlice(gpa, bytes.items[0..len_at]);
    try varint.append(gpa, &padded, skip_bytes + 1);
    try padded.appendSlice(gpa, bytes.items[at..][0..@intCast(skip_bytes)]);
    try padded.append(gpa, 0);
    try padded.appendSlice(gpa, bytes.items[at + @as(usize, @intCast(skip_bytes)) ..]);
    var p = try postings.Reader.init(.{ .memory = padded.items }, io, 0, 600);
    const read: anyerror!void = while (p.next()) |posting| {
        if (posting == null) break;
    } else |err| err;
    try testing.expectError(error.Corrupt, read);
}
