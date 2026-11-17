//! A numeric column against its values: each read back in any order, each
//! block's bounds its least and greatest, blocks of a narrow span packed and
//! of a wide one raw; and any bytes, or a damaged column, refused or read
//! within each block's bounds.
const std = @import("std");
const shakedown = @import("shakedown");
const columns = @import("segment.zig").columns;

const testing = std.testing;
const gen = shakedown.gen;

const max_docs = 700;

fn valuesOf(s: *shakedown.Source, out: []u64) []u64 {
    const edges = [_]u32{ 0, 1, 127, 128, 129, 256, 300 };
    const docs = if (gen.boolean(s)) edges[gen.intRange(s, usize, 0, edges.len - 1)] else gen.intRange(s, u32, 0, max_docs);
    const base = gen.int(s, u64);
    for (out[0..docs]) |*v| v.* = switch (gen.intRange(s, u8, 0, 9)) {
        // Somewhere else entirely: a block with one is raw.
        0 => gen.int(s, u64),
        1 => base,
        else => base +| gen.intRange(s, u64, 0, 1000),
    };
    return out[0..docs];
}

fn againstValues(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var buffer: [max_docs]u64 = undefined;
    const values = valuesOf(s, &buffer);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try columns.write(gpa, &bytes, values);
    const column = try columns.Column.parse(bytes.items, @intCast(values.len));
    try testing.expectEqual(@as(u32, @intCast((values.len + 127) / 128)), column.blocks());
    for (0..column.blocks()) |b| {
        const block = values[b * 128 .. @min(b * 128 + 128, values.len)];
        try testing.expectEqual(columns.Bounds{ .min = std.mem.min(u64, block), .max = std.mem.max(u64, block) }, column.bounds(@intCast(b)));
    }
    var cursor: columns.Cursor = .init(column);
    if (values.len == 0) return;
    for (0..2 * values.len) |_| {
        const doc = gen.intRange(s, u32, 0, @intCast(values.len - 1));
        try testing.expectEqual(values[doc], try cursor.get(doc));
    }
}

test "a column reads back as its values, each block bounded by its least and greatest" {
    try shakedown.check(testing.allocator, {}, againstValues, .{ .seed = 0x636f6c73, .cases = 1500 });
}

fn readsWithin(column: columns.Column) !void {
    var cursor: columns.Cursor = .init(column);
    for (0..column.docs) |d| {
        const doc: u32 = @intCast(d);
        const v = cursor.get(doc) catch return;
        const b = column.bounds(doc / 128);
        try testing.expect(v >= b.min and v <= b.max);
    }
}

fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var buffer: [512]u8 = undefined;
    const column = columns.Column.parse(gen.bytesInto(s, &buffer), gen.intRange(s, u32, 0, 400)) catch return;
    try readsWithin(column);
}

test "fuzz: any bytes are refused as a column, or read within each block's bounds" {
    try shakedown.check(testing.allocator, {}, anyBytes, .{ .seed = 0x66757a7a, .cases = 3000 });
}

fn damaged(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var buffer: [max_docs]u64 = undefined;
    const values = valuesOf(s, &buffer);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try columns.write(gpa, &bytes, values);
    if (bytes.items.len == 0) return;
    for (0..gen.intRange(s, usize, 1, 4)) |_| {
        bytes.items[gen.intRange(s, usize, 0, bytes.items.len - 1)] = gen.int(s, u8);
    }
    const column = columns.Column.parse(bytes.items, @intCast(values.len)) catch return;
    try readsWithin(column);
}

test "fuzz: a damaged column is refused, or read within each block's bounds" {
    try shakedown.check(testing.allocator, {}, damaged, .{ .seed = 0x64616d67, .cases = 2000 });
}
