//! The FST against a sorted map: any set of keys with any values reads
//! back each key's value and no other key, walks every key with a prefix in
//! order, shares the nodes keys have in common, and any bytes are refused or
//! walked within their bounds.
const std = @import("std");
const shakedown = @import("shakedown");
const fst = @import("probe.zig").fst;

const testing = std.testing;
const gen = shakedown.gen;

const max_key = 8;

/// A key over a small alphabet, so keys share prefixes and suffixes.
fn drawKey(s: *shakedown.Source, buffer: *[max_key]u8) []const u8 {
    const len = gen.intRange(s, usize, 0, max_key);
    for (buffer[0..len]) |*c| c.* = "abcz"[gen.intRange(s, usize, 0, 3)];
    return buffer[0..len];
}

const Pair = struct { key: []const u8, value: u64 };

fn lessThan(_: void, a: Pair, b: Pair) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

fn build(gpa: std.mem.Allocator, pairs: []const Pair) ![]u8 {
    var b: fst.Builder = .init(gpa);
    defer b.deinit();
    for (pairs) |p| try b.add(p.key, p.value);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try b.finish(&out);
    return out.toOwnedSlice(gpa);
}

fn againstMap(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var pairs: std.ArrayList(Pair) = .empty;
    const n = gen.intRange(s, usize, 0, 40);
    for (0..n) |_| {
        var buffer: [max_key]u8 = undefined;
        const key = try arena.allocator().dupe(u8, drawKey(s, &buffer));
        // Small values mostly, so outputs are shared and pushed down; huge ones too.
        const value = if (gen.boolean(s)) gen.intRange(s, u64, 0, 9) else gen.int(s, u64);
        try pairs.append(arena.allocator(), .{ .key = key, .value = value });
    }
    std.sort.pdq(Pair, pairs.items, {}, lessThan);
    // Keys once each: the first of equal ones kept.
    var kept: std.ArrayList(Pair) = .empty;
    for (pairs.items) |p| {
        if (kept.items.len != 0 and std.mem.eql(u8, kept.items[kept.items.len - 1].key, p.key)) continue;
        try kept.append(arena.allocator(), p);
    }
    const bytes = try build(gpa, kept.items);
    defer gpa.free(bytes);
    const f = try fst.Fst.parse(bytes);
    try testing.expectEqual(@as(u64, kept.items.len), f.keys);
    for (kept.items) |p| try testing.expectEqual(@as(?u64, p.value), try f.get(p.key));
    // A key not held reads as none.
    for (0..10) |_| {
        var buffer: [max_key]u8 = undefined;
        const key = drawKey(s, &buffer);
        const held = for (kept.items) |p| {
            if (std.mem.eql(u8, p.key, key)) break p.value;
        } else null;
        try testing.expectEqual(held, try f.get(key));
    }
    // Every key with a prefix, in order.
    var prefix_buffer: [max_key]u8 = undefined;
    const drawn = drawKey(s, &prefix_buffer);
    const prefix = drawn[0..@min(drawn.len, gen.intRange(s, usize, 0, 3))];
    var key: [max_key]u8 = undefined;
    var frames: [max_key + 1]fst.Fst.Frame = undefined;
    var walk = try f.walk(prefix, &key, &frames);
    for (kept.items) |p| {
        if (!std.mem.startsWith(u8, p.key, prefix)) continue;
        const entry = (try walk.next()).?;
        try testing.expectEqualStrings(p.key, entry.key);
        try testing.expectEqual(p.value, entry.value);
    }
    try testing.expectEqual(@as(?fst.Fst.Walk.Entry, null), try walk.next());
}

test "any keys with any values read back, and walk in order by prefix" {
    try shakedown.check(testing.allocator, {}, againstMap, .{ .seed = 0x66737431, .cases = 3000 });
}

test "keys sharing a suffix share its nodes" {
    const gpa = testing.allocator;
    var b: fst.Builder = .init(gpa);
    defer b.deinit();
    var key: [7]u8 = "_suffix".*;
    for ("abcdefghijklmnopqrstuvwxyz") |c| {
        key[0] = c;
        try b.add(&key, 0);
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try b.finish(&out);
    // The root, then one chain of "suffix" for all 26: seven nodes after it.
    try testing.expectEqual(@as(u64, 8), b.nodes);
}

test "keys out of order, or twice, are refused" {
    var b: fst.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.add("b", 1);
    try testing.expectError(error.NotRising, b.add("a", 2));
    try testing.expectError(error.NotRising, b.add("b", 2));
    try b.add("ba", 3);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try b.finish(&out);
    const f = try fst.Fst.parse(out.items);
    try testing.expectEqual(@as(?u64, 1), try f.get("b"));
    try testing.expectEqual(@as(?u64, 3), try f.get("ba"));
    try testing.expectEqual(@as(?u64, null), try f.get("a"));
}

test "the empty key and an empty FST" {
    const gpa = testing.allocator;
    const none = try build(gpa, &.{});
    defer gpa.free(none);
    const empty = try fst.Fst.parse(none);
    try testing.expectEqual(@as(?u64, null), try empty.get(""));
    const one = try build(gpa, &.{ .{ .key = "", .value = 7 }, .{ .key = "a", .value = 9 } });
    defer gpa.free(one);
    const f = try fst.Fst.parse(one);
    try testing.expectEqual(@as(?u64, 7), try f.get(""));
    try testing.expectEqual(@as(?u64, 9), try f.get("a"));
}

test "a walk past its key buffer says so" {
    const gpa = testing.allocator;
    const bytes = try build(gpa, &.{.{ .key = "abcd", .value = 1 }});
    defer gpa.free(bytes);
    const f = try fst.Fst.parse(bytes);
    var key: [2]u8 = undefined;
    var frames: [3]fst.Fst.Frame = undefined;
    var walk = try f.walk("", &key, &frames);
    try testing.expectError(error.KeyTooLong, walk.next());
}

/// Any bytes, or a good FST with some bytes changed: refused, or every
/// read and walk ends within its bounds.
fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var buffer: [256]u8 = undefined;
    const bytes = if (gen.boolean(s)) gen.bytesInto(s, &buffer) else good: {
        const file = try build(gpa, &.{ .{ .key = "ab", .value = 3 }, .{ .key = "abc", .value = 1 }, .{ .key = "b", .value = 900 }, .{ .key = "zz", .value = 2 } });
        defer gpa.free(file);
        @memcpy(buffer[0..file.len], file);
        for (0..gen.intRange(s, usize, 1, 3)) |_| buffer[gen.intRange(s, usize, 0, file.len - 1)] = gen.int(s, u8);
        break :good buffer[0..file.len];
    };
    const f = fst.Fst.parse(bytes) catch return;
    for ([_][]const u8{ "", "ab", "abc", "b", "zz", "q" }) |key| _ = f.get(key) catch {};
    var key: [max_key]u8 = undefined;
    var frames: [max_key + 1]fst.Fst.Frame = undefined;
    var walk = f.walk("", &key, &frames) catch return;
    while (walk.next() catch return) |_| {}
}

test "fuzz: any bytes are refused as an FST, or read and walked within their bounds" {
    try shakedown.check(testing.allocator, {}, anyBytes, .{ .seed = 0x66757a7a, .cases = 4000 });
}
