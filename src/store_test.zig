//! Stored fields against their values: every document's read back, from
//! blocks of any count, a document longer than a block included; and any
//! bytes, or a damaged store, refused or read without passing its bounds.
const std = @import("std");
const shakedown = @import("shakedown");
const store = @import("segment.zig").store;
const Schema = @import("Schema.zig");

const testing = std.testing;
const gen = shakedown.gen;

const schema = [_]Schema.Field{
    .{ .name = "title", .kind = .text, .stored = true },
    .{ .name = "level", .kind = .keyword },
    .{ .name = "at", .kind = .numeric, .stored = true },
    .{ .name = "tag", .kind = .keyword, .stored = true },
};
const stored_fields = 3;
const max_docs = 300;
const max_block = 1 << 20;

fn bytesOf(s: *shakedown.Source, pool: []const u8) []const u8 {
    const len: usize = switch (gen.intRange(s, u8, 0, 19)) {
        0 => gen.intRange(s, usize, 16 * 1024, pool.len),
        else => gen.intRange(s, usize, 0, 200),
    };
    const start = gen.intRange(s, usize, 0, pool.len - len);
    return pool[start..][0..len];
}

fn againstValues(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var pool: [40 * 1024]u8 = undefined;
    for (&pool, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 7));
    var values: [max_docs][stored_fields]store.Value = undefined;
    const docs = gen.intRange(s, u32, 0, max_docs);
    var w: store.Writer = try .init(gpa);
    defer w.deinit();
    for (values[0..docs]) |*v| {
        v.* = .{ .{ .bytes = bytesOf(s, &pool) }, .{ .numeric = gen.int(s, u64) }, .{ .bytes = bytesOf(s, &pool) } };
        try w.add(v);
    }
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try w.finish(&body);
    const st = try store.Store.parse(body.items, docs, &schema, max_block);
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);
    var out: [stored_fields]store.Value = undefined;
    if (docs == 0) return;
    for (0..docs) |_| {
        const doc = gen.intRange(s, u32, 0, docs - 1);
        try st.read(gpa, doc, &buffer, &out);
        for (values[doc], out) |want, got| switch (want) {
            .bytes => |b| try testing.expectEqualSlices(u8, b, got.bytes),
            .numeric => |n| try testing.expectEqual(n, got.numeric),
        };
    }
}

test "every document's stored values read back, from blocks of any count" {
    try shakedown.check(testing.allocator, {}, againstValues, .{ .seed = 0x73746f72, .cases = 300 });
}

fn readsWithin(st: store.Store, s: *shakedown.Source) !void {
    const gpa = testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);
    var out: [stored_fields]store.Value = undefined;
    if (st.docs == 0) return;
    for (0..4) |_| {
        const read = st.read(gpa, gen.intRange(s, u32, 0, st.docs - 1), &buffer, &out);
        // Refused or not, a read takes no more than a block's bound.
        try testing.expect(buffer.items.len <= max_block);
        read catch |err| switch (err) {
            error.Corrupt => return,
            else => return err,
        };
    }
}

fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var bytes: [256]u8 = undefined;
    const st = store.Store.parse(gen.bytesInto(s, &bytes), gen.intRange(s, u32, 0, 50), &schema, max_block) catch return;
    try readsWithin(st, s);
}

test "fuzz: any bytes are refused as a store, or read within its bounds" {
    try shakedown.check(testing.allocator, {}, anyBytes, .{ .seed = 0x66757a7a, .cases = 3000 });
}

fn damaged(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var pool: [40 * 1024]u8 = undefined;
    for (&pool, 0..) |*b, i| b.* = @truncate(i *% 7);
    const docs = gen.intRange(s, u32, 1, 60);
    var w: store.Writer = try .init(gpa);
    defer w.deinit();
    for (0..docs) |_| try w.add(&.{ .{ .bytes = bytesOf(s, &pool) }, .{ .numeric = gen.int(s, u64) }, .{ .bytes = bytesOf(s, &pool) } });
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try w.finish(&body);
    for (0..gen.intRange(s, usize, 1, 4)) |_| {
        body.items[gen.intRange(s, usize, 0, body.items.len - 1)] = gen.int(s, u8);
    }
    const st = store.Store.parse(body.items, docs, &schema, max_block) catch return;
    try readsWithin(st, s);
}

test "fuzz: a damaged store is refused, or read within its bounds" {
    try shakedown.check(testing.allocator, {}, damaged, .{ .seed = 0x64616d67, .cases = 1000 });
}
