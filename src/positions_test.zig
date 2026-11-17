//! One term's positions against a list: read in step with its postings
//! blocks, any document read whole, in part or passed, any block passed;
//! and any bytes, or damaged positions, refused or read within `u32`.
const std = @import("std");
const shakedown = @import("shakedown");
const positions = @import("segment.zig").positions;
const Files = @import("sources_test.zig").Files;
const varint = @import("encoding/varint.zig");

const testing = std.testing;
const gen = shakedown.gen;
const io = testing.io;
const Token = positions.Token;

const max_docs = 400;
const max_tokens = 6000;

const Model = struct {
    offsets: bool,
    docs: [][]const Token,
};

fn model(s: *shakedown.Source, doc_buffer: [][]const Token, token_buffer: []Token) Model {
    const offsets = gen.boolean(s);
    const edges = [_]usize{ 1, 127, 128, 129, 256, 300 };
    const df = if (gen.boolean(s)) edges[gen.intRange(s, usize, 0, edges.len - 1)] else gen.intRange(s, usize, 1, max_docs);
    var used: usize = 0;
    for (doc_buffer[0..df]) |*doc| {
        const room = token_buffer.len - used - (df - 1);
        const want: usize = switch (gen.intRange(s, u8, 0, 9)) {
            0 => gen.intRange(s, usize, 120, 300),
            else => gen.intRange(s, usize, 1, 5),
        };
        const n = @max(1, @min(want, room / df + 1));
        var position: u32 = 0;
        var start: u32 = 0;
        for (token_buffer[used..][0..n]) |*t| {
            // Tokens may share a position, and a start.
            position += switch (gen.intRange(s, u8, 0, 9)) {
                0 => 0,
                1 => gen.intRange(s, u32, 0, 1 << 20),
                else => gen.intRange(s, u32, 1, 9),
            };
            start += gen.intRange(s, u32, 0, 40);
            t.* = .{ .position = position, .start = if (offsets) start else 0, .end = if (offsets) start + gen.intRange(s, u32, 1, 30) else 0 };
        }
        doc.* = token_buffer[used..][0..n];
        used += n;
    }
    return .{ .offsets = offsets, .docs = doc_buffer[0..df] };
}

fn againstList(files: *Files, case: *shakedown.Case) anyerror!void {
    defer files.close();
    const s = case.source;
    const gpa = testing.allocator;
    var doc_buffer: [max_docs][]const Token = undefined;
    var token_buffer: [max_tokens]Token = undefined;
    const m = model(s, &doc_buffer, &token_buffer);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, "head");
    try positions.write(gpa, &bytes, m.docs, m.offsets);
    try bytes.appendSlice(gpa, "tail");
    var r = try positions.Reader.init(try files.source(bytes.items, gen.boolean(s)), io, 4, @intCast(m.docs.len), m.offsets);
    var block: u32 = 0;
    while (block * 128 < m.docs.len) : (block += 1) {
        const docs = m.docs[block * 128 .. @min(block * 128 + 128, m.docs.len)];
        // A block passed whole, as a postings reader passes it.
        if (gen.intRange(s, u8, 0, 3) == 0) continue;
        var tokens: u64 = 0;
        for (docs) |d| tokens += d.len;
        try r.enter(block, tokens);
        for (docs) |d| {
            try r.document(@intCast(d.len));
            switch (gen.intRange(s, u8, 0, 2)) {
                // Passed.
                0 => {},
                // Read in part, then passed by the next `document`.
                1 => for (d[0..gen.intRange(s, usize, 0, d.len)]) |want| {
                    try testing.expectEqual(want, (try r.next()).?);
                },
                // Read whole.
                else => {
                    for (d) |want| try testing.expectEqual(want, (try r.next()).?);
                    try testing.expectEqual(null, try r.next());
                },
            }
        }
        try r.skip();
    }
}

test "a term's positions read back as written, any document read, read in part or passed, any block passed" {
    var files: Files = .init();
    defer files.deinit();
    try shakedown.check(testing.allocator, &files, againstList, .{ .seed = 0x706f7369, .cases = 1500 });
}

test "a whole group passed unread moves past its bytes, its bits byte included" {
    const gpa = testing.allocator;
    // 214 tokens at position 0: a group packed to no bits, one byte, then a
    // short group as varints; a second document after it.
    var first: [214]Token = @splat(.{ .position = 0 });
    const second = [_]Token{ .{ .position = 3 }, .{ .position = 9 } };
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try positions.write(gpa, &bytes, &.{ &first, &second }, false);
    var r = try positions.Reader.init(.{ .memory = bytes.items }, io, 0, 2, false);
    try r.enter(0, first.len + second.len);
    try r.document(first.len);
    try r.document(second.len);
    try testing.expectEqual(Token{ .position = 3 }, (try r.next()).?);
    try testing.expectEqual(Token{ .position = 9 }, (try r.next()).?);
    try testing.expectEqual(null, try r.next());
}

/// Reads every block and document of `r` as `freqs` say, giving up at the
/// first refusal: what is read is within `u32` and rises.
fn readsWithin(r: *positions.Reader, freqs: []const u32) !void {
    var block: u32 = 0;
    while (block * 128 < freqs.len) : (block += 1) {
        const docs = freqs[block * 128 .. @min(block * 128 + 128, freqs.len)];
        var tokens: u64 = 0;
        for (docs) |f| tokens += f;
        r.enter(block, tokens) catch return;
        for (docs) |f| {
            r.document(f) catch return;
            var last: u32 = 0;
            while (r.next() catch return) |t| {
                try testing.expect(t.position >= last);
                if (r.offsets) try testing.expect(t.end > t.start);
                last = t.position;
            }
        }
    }
}

fn anyBytes(files: *Files, case: *shakedown.Case) anyerror!void {
    defer files.close();
    const s = case.source;
    var buffer: [512]u8 = undefined;
    const bytes = gen.bytesInto(s, &buffer);
    var freqs: [300]u32 = undefined;
    const df = gen.intRange(s, usize, 1, freqs.len);
    for (freqs[0..df]) |*f| f.* = gen.intRange(s, u32, 1, 300);
    var r = positions.Reader.init(try files.source(bytes, gen.boolean(s)), io, gen.intRange(s, u64, 0, bytes.len), @intCast(df), gen.boolean(s)) catch return;
    try readsWithin(&r, freqs[0..df]);
}

test "fuzz: any bytes are refused as positions, or read rising" {
    var files: Files = .init();
    defer files.deinit();
    try shakedown.check(testing.allocator, &files, anyBytes, .{ .seed = 0x66757a7a, .cases = 3000 });
}

fn damaged(files: *Files, case: *shakedown.Case) anyerror!void {
    defer files.close();
    const s = case.source;
    const gpa = testing.allocator;
    var doc_buffer: [max_docs][]const Token = undefined;
    var token_buffer: [max_tokens]Token = undefined;
    const m = model(s, &doc_buffer, &token_buffer);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try positions.write(gpa, &bytes, m.docs, m.offsets);
    for (0..gen.intRange(s, usize, 1, 4)) |_| {
        bytes.items[gen.intRange(s, usize, 0, bytes.items.len - 1)] = gen.int(s, u8);
    }
    if (gen.boolean(s)) bytes.shrinkRetainingCapacity(gen.intRange(s, usize, 0, bytes.items.len));
    var freqs: [max_docs]u32 = undefined;
    for (m.docs, freqs[0..m.docs.len]) |d, *f| f.* = @intCast(d.len);
    var r = positions.Reader.init(try files.source(bytes.items, gen.boolean(s)), io, 0, @intCast(m.docs.len), m.offsets) catch return;
    try readsWithin(&r, freqs[0..m.docs.len]);
}

test "fuzz: damaged positions are refused, or read rising" {
    var files: Files = .init();
    defer files.deinit();
    try shakedown.check(testing.allocator, &files, damaged, .{ .seed = 0x64616d67, .cases = 2000 });
}

test "chunk lengths that end before their length says are refused" {
    const gpa = testing.allocator;
    var tokens: [300][1]Token = undefined;
    var docs: [300][]const Token = undefined;
    for (&tokens, &docs, 0..) |*t, *d, i| {
        t.* = .{.{ .position = @intCast(i % 7) }};
        d.* = t;
    }
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try positions.write(gpa, &bytes, &docs, false);
    // The same positions with a byte after the lengths, their length one more.
    var at: usize = 0;
    const length_bytes = try varint.read(bytes.items, &at);
    var padded: std.ArrayList(u8) = .empty;
    defer padded.deinit(gpa);
    try varint.append(gpa, &padded, length_bytes + 1);
    try padded.appendSlice(gpa, bytes.items[at..][0..@intCast(length_bytes)]);
    try padded.append(gpa, 0);
    try padded.appendSlice(gpa, bytes.items[at + @as(usize, @intCast(length_bytes)) ..]);
    inline for (.{ bytes.items, padded.items }, .{ false, true }) |body, refused| {
        var r = try positions.Reader.init(.{ .memory = body }, io, 0, docs.len, false);
        const read: anyerror!void = blk: {
            var block: u32 = 0;
            while (block * 128 < docs.len) : (block += 1) {
                const n = @min(128, docs.len - block * 128);
                r.enter(block, n) catch |err| break :blk err;
                for (0..n) |_| r.document(1) catch |err| break :blk err;
                r.skip() catch |err| break :blk err;
            }
        };
        if (refused) try testing.expectError(error.Corrupt, read) else try read;
    }
}
