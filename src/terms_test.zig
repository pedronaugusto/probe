//! A segment's term dictionary against a model: each field's terms looked
//! up to the addresses written, absent terms and fields absent; and any
//! bytes, or a damaged dictionary, refused or read within its table.
const std = @import("std");
const shakedown = @import("shakedown");
const terms = @import("segment.zig").terms;

const testing = std.testing;
const gen = shakedown.gen;

const places = 8;
const max_terms = 40;

const Model = struct {
    /// Per place, its terms rising, or none when the field is absent.
    present: [places]bool,
    words: [places][max_terms][]const u8,
    counts: [places]usize,
    text: [places * max_terms * 6]u8,
};

fn termOf(s: *shakedown.Source, out: []u8) []u8 {
    const len = gen.intRange(s, usize, 0, 5);
    for (out[0..len]) |*b| b.* = "abc\x00\xff"[gen.intRange(s, usize, 0, 4)];
    return out[0..len];
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn build(s: *shakedown.Source, m: *Model) void {
    var used: usize = 0;
    for (0..places) |p| {
        m.present[p] = gen.boolean(s);
        m.counts[p] = 0;
        if (!m.present[p]) continue;
        var raw: [max_terms][]const u8 = undefined;
        const n = gen.intRange(s, usize, 0, max_terms);
        for (raw[0..n]) |*t| {
            const term = termOf(s, m.text[used..][0..5]);
            used += term.len;
            t.* = term;
        }
        std.mem.sort([]const u8, raw[0..n], {}, lessThan);
        // Distinct, rising.
        for (raw[0..n]) |t| {
            if (m.counts[p] > 0 and std.mem.eql(u8, m.words[p][m.counts[p] - 1], t)) continue;
            m.words[p][m.counts[p]] = t;
            m.counts[p] += 1;
        }
    }
}

fn addressOf(place: usize, ordinal: usize) terms.Address {
    return .{ .postings = place * 1000 + ordinal, .positions = if (place % 2 == 0) terms.no_positions else ordinal * 7 };
}

fn write(gpa: std.mem.Allocator, m: *const Model, out: *std.ArrayList(u8)) !void {
    var fields: u32 = 0;
    for (m.present) |p| fields += @intFromBool(p);
    try terms.begin(gpa, out, fields);
    for (0..places) |p| {
        if (!m.present[p]) continue;
        var w: terms.FieldWriter = .init(gpa);
        defer w.deinit();
        for (m.words[p][0..m.counts[p]], 0..) |t, i| try w.add(t, addressOf(p, i));
        try w.finish(@intCast(p), out);
    }
}

fn againstModel(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var m: Model = undefined;
    build(s, &m);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try write(gpa, &m, &bytes);
    const d = try terms.Dictionary.parse(bytes.items, places);
    var probe_buffer: [5]u8 = undefined;
    for (0..places) |p| {
        const field = try d.field(@intCast(p)) orelse {
            try testing.expect(!m.present[p]);
            continue;
        };
        try testing.expect(m.present[p]);
        try testing.expectEqual(@as(u64, m.counts[p]), field.terms);
        for (m.words[p][0..m.counts[p]], 0..) |t, i| {
            try testing.expectEqual(addressOf(p, i), (try field.lookup(t)).?);
        }
        // A term the field does not hold.
        const other = termOf(s, &probe_buffer);
        const held = for (m.words[p][0..m.counts[p]]) |t| {
            if (std.mem.eql(u8, t, other)) break true;
        } else false;
        if (!held) try testing.expectEqual(null, try field.lookup(other));
    }
}

test "each field's terms look up to the addresses written, and nothing else does" {
    try shakedown.check(testing.allocator, {}, againstModel, .{ .seed = 0x7465726d, .cases = 1500 });
}

fn readsWithin(d: terms.Dictionary, s: *shakedown.Source) !void {
    var buffer: [5]u8 = undefined;
    for (0..places) |p| {
        const field = (d.field(@intCast(p)) catch return) orelse continue;
        _ = field.lookup(termOf(s, &buffer)) catch return;
    }
}

fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var buffer: [256]u8 = undefined;
    const d = terms.Dictionary.parse(gen.bytesInto(s, &buffer), places) catch return;
    try readsWithin(d, s);
}

test "fuzz: any bytes are refused as a dictionary, or looked up within it" {
    try shakedown.check(testing.allocator, {}, anyBytes, .{ .seed = 0x66757a7a, .cases = 3000 });
}

fn damaged(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var m: Model = undefined;
    build(s, &m);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try write(gpa, &m, &bytes);
    for (0..gen.intRange(s, usize, 1, 4)) |_| {
        bytes.items[gen.intRange(s, usize, 0, bytes.items.len - 1)] = gen.int(s, u8);
    }
    const d = terms.Dictionary.parse(bytes.items, places) catch return;
    // Every term written, so a damaged node or table on its path is met.
    for (0..places) |p| {
        const field = (d.field(@intCast(p)) catch return) orelse continue;
        for (m.words[p][0..m.counts[p]]) |t| _ = field.lookup(t) catch continue;
    }
    try readsWithin(d, s);
}

test "fuzz: a damaged dictionary is refused, or looked up within it" {
    try shakedown.check(testing.allocator, {}, damaged, .{ .seed = 0x64616d67, .cases = 2000 });
}
