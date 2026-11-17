//! Stored fields against their values: every document's read back, from
//! blocks of any count, a document longer than a block included; and any
//! bytes, or a damaged store, refused or read without passing its bounds.
const std = @import("std");
const shakedown = @import("shakedown");
const store = @import("segment.zig").store;
const Files = @import("sources_test.zig").Files;
const varint = @import("encoding/varint.zig");
const warp = @import("warp");
const Schema = @import("Schema.zig");

const testing = std.testing;
const gen = shakedown.gen;
const io = testing.io;

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

fn againstValues(files: *Files, case: *shakedown.Case) anyerror!void {
    defer files.close();
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
    var st = try store.Store.parse(gpa, io, try files.source(body.items, gen.boolean(s)), docs, &schema, max_block);
    defer st.deinit(gpa);
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);
    var out: [stored_fields]store.Value = undefined;
    if (docs == 0) return;
    for (0..docs) |_| {
        const doc = gen.intRange(s, u32, 0, docs - 1);
        try st.read(io, gpa, doc, &buffer, &out);
        for (values[doc], out) |want, got| switch (want) {
            .bytes => |b| try testing.expectEqualSlices(u8, b, got.bytes),
            .numeric => |n| try testing.expectEqual(n, got.numeric),
        };
    }
}

test "every document's stored values read back, from blocks of any count" {
    var files: Files = .init();
    defer files.deinit();
    try shakedown.check(testing.allocator, &files, againstValues, .{ .seed = 0x73746f72, .cases = 300 });
}

fn readsWithin(st: store.Store, s: *shakedown.Source) !void {
    const gpa = testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);
    var out: [stored_fields]store.Value = undefined;
    if (st.docs == 0) return;
    for (0..4) |_| {
        const read = st.read(io, gpa, gen.intRange(s, u32, 0, st.docs - 1), &buffer, &out);
        // Refused or not, a read takes no more than a block's bound.
        try testing.expect(buffer.items.len <= max_block);
        read catch |err| switch (err) {
            error.Corrupt => return,
            else => return err,
        };
    }
}

fn anyBytes(files: *Files, case: *shakedown.Case) anyerror!void {
    defer files.close();
    const s = case.source;
    var bytes: [256]u8 = undefined;
    const source = try files.source(gen.bytesInto(s, &bytes), gen.boolean(s));
    var st = store.Store.parse(testing.allocator, io, source, gen.intRange(s, u32, 0, 50), &schema, max_block) catch return;
    defer st.deinit(testing.allocator);
    try readsWithin(st, s);
}

test "fuzz: any bytes are refused as a store, or read within its bounds" {
    var files: Files = .init();
    defer files.deinit();
    try shakedown.check(testing.allocator, &files, anyBytes, .{ .seed = 0x66757a7a, .cases = 3000 });
}

fn damaged(files: *Files, case: *shakedown.Case) anyerror!void {
    defer files.close();
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
    // The table's check made whole again, mostly, so the checks behind it
    // are what is tested.
    if (gen.intRange(s, u8, 0, 3) != 0) fixCheck(body.items);
    var st = store.Store.parse(gpa, io, try files.source(body.items, gen.boolean(s)), docs, &schema, max_block) catch return;
    defer st.deinit(gpa);
    try readsWithin(st, s);
}

/// Rewrites the CRC-32C of the block count and table `body` begins with,
/// where they fit.
fn fixCheck(body: []u8) void {
    var at: usize = 0;
    const blocks = varint.read(body, &at) catch return;
    if (blocks > (body.len - at) / 20) return;
    const end = at + @as(usize, @intCast(blocks)) * 20;
    if (end + 4 > body.len) return;
    std.mem.writeInt(u32, body[end..][0..4], warp.crc32c(0, body[0..end]), .little);
}

test "fuzz: a damaged store is refused, or read within its bounds" {
    var files: Files = .init();
    defer files.deinit();
    try shakedown.check(testing.allocator, &files, damaged, .{ .seed = 0x64616d67, .cases = 1000 });
}

test "a block refused leaves the buffer within the bound" {
    const gpa = testing.allocator;
    var w: store.Writer = try .init(gpa);
    defer w.deinit();
    var text: [3000]u8 = undefined;
    for (&text, 0..) |*b, i| b.* = @truncate(i *% 13);
    try w.add(&.{ .{ .bytes = &text }, .{ .numeric = 1 }, .{ .bytes = "x" } });
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try w.finish(&body);
    // One block: the bound is its decoded length exactly; its compressed
    // bytes, after the varint and the table's one entry, are spoiled.
    const raw = std.mem.readInt(u32, body.items[1 + 4 ..][0..4], .little);
    @memset(body.items[1 + 20 + 4 ..], 0xff);
    var st = try store.Store.parse(gpa, io, .{ .memory = body.items }, 1, &schema, raw);
    defer st.deinit(gpa);
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);
    var out: [stored_fields]store.Value = undefined;
    try testing.expectError(error.Corrupt, st.read(io, gpa, 0, &buffer, &out));
    try testing.expect(buffer.items.len <= raw);
}

fn tableFlip(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var pool: [40 * 1024]u8 = undefined;
    for (&pool, 0..) |*b, i| b.* = @truncate(i *% 31);
    const docs = gen.intRange(s, u32, 1, 60);
    var w: store.Writer = try .init(gpa);
    defer w.deinit();
    for (0..docs) |_| try w.add(&.{ .{ .bytes = bytesOf(s, &pool) }, .{ .numeric = gen.int(s, u64) }, .{ .bytes = bytesOf(s, &pool) } });
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try w.finish(&body);
    var at: usize = 0;
    const blocks: usize = @intCast(try varint.read(body.items, &at));
    // Any one bit of the block count, the table or its check.
    const flip = gen.intRange(s, usize, 0, at + blocks * 20 + 4 - 1);
    body.items[flip] ^= @as(u8, 1) << gen.intRange(s, u3, 0, 7);
    try testing.expectError(error.Corrupt, store.Store.parse(gpa, io, .{ .memory = body.items }, docs, &schema, max_block));
}

test "a store whose table has any one bit changed is refused when parsed" {
    try shakedown.check(testing.allocator, {}, tableFlip, .{ .seed = 0x7461626c, .cases = 1000 });
}
