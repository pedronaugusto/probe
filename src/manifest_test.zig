//! The manifest against its rules: any manifest that keeps them reads back
//! as written, each rule broken is refused with its error, names and
//! generations map one to one, and any bytes are refused or read as a
//! manifest that keeps every rule.
const std = @import("std");
const shakedown = @import("shakedown");
const Manifest = @import("Manifest.zig");

const testing = std.testing;
const gen = shakedown.gen;

const schema = [_]Manifest.Field{
    .{ .name = "message", .kind = .text, .positions = true, .offsets = true, .analysis = .words_and_identifiers },
    .{ .name = "level", .kind = .keyword, .stored = true },
    .{ .name = "at", .kind = .numeric, .stored = true },
};

fn expectedOf(m: Manifest) Manifest.Expected {
    return .{ .generation = m.generation, .fields = m.fields, .term_bytes = m.term_bytes };
}

/// A manifest that keeps every rule, its segments in `buffer`.
fn manifestOf(s: *shakedown.Source, buffer: []Manifest.Segment) Manifest {
    const generation = if (gen.boolean(s)) gen.int(s, u64) else gen.intRange(s, u64, 0, 9);
    const count = gen.intRange(s, usize, 0, buffer.len);
    var number: u64 = gen.intRange(s, u64, 0, 3);
    for (buffer[0..count]) |*segment| {
        const docs = if (gen.boolean(s)) gen.int(s, u32) else gen.intRange(s, u32, 1, 5);
        segment.* = .{ .number = number, .docs = @max(docs, 1) };
        if (segment.docs > 1 and gen.boolean(s)) segment.deletions = .{
            .generation = gen.intRange(s, u64, 0, generation),
            .count = gen.intRange(s, u32, 1, segment.docs - 1),
        };
        number += gen.intRange(s, u64, 1, 1000);
    }
    return .{
        .generation = generation,
        .next_segment = number + gen.intRange(s, u64, 0, 3),
        .term_bytes = gen.intRange(s, u16, 1, 255),
        .fields = schema[0..gen.intRange(s, usize, 0, schema.len)],
        .segments = buffer[0..count],
    };
}

fn written(gpa: std.mem.Allocator, m: Manifest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try m.write(&out.writer);
    return out.toOwnedSlice();
}

fn expectSame(want: Manifest, got: Manifest) !void {
    try testing.expectEqual(want.format, got.format);
    try testing.expectEqual(want.generation, got.generation);
    try testing.expectEqual(want.next_segment, got.next_segment);
    try testing.expectEqual(want.term_bytes, got.term_bytes);
    try testing.expectEqual(want.fields.len, got.fields.len);
    for (want.fields, got.fields) |w, g| {
        try testing.expectEqualStrings(w.name, g.name);
        try testing.expectEqual(Manifest.Field{ .name = "", .kind = w.kind, .positions = w.positions, .offsets = w.offsets, .analysis = w.analysis, .stored = w.stored }, Manifest.Field{ .name = "", .kind = g.kind, .positions = g.positions, .offsets = g.offsets, .analysis = g.analysis, .stored = g.stored });
    }
    try testing.expectEqualSlices(Manifest.Segment, want.segments, got.segments);
}

fn roundTrip(_: void, case: *shakedown.Case) anyerror!void {
    var segments: [12]Manifest.Segment = undefined;
    const m = manifestOf(case.source, &segments);
    const bytes = try written(testing.allocator, m);
    defer testing.allocator.free(bytes);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try expectSame(m, try Manifest.parse(arena.allocator(), .init(bytes), expectedOf(m)));
}

test "a manifest that keeps every rule reads back as written" {
    try shakedown.check(testing.allocator, {}, roundTrip, .{ .seed = 0x6d616e69, .cases = 500 });
}

const Broken = enum { generation, term_bytes, fields, field, format, newer, order, number, empty, none_deleted, all_deleted, later_deletions };

fn breaks(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var segments: [12]Manifest.Segment = undefined;
    var m = manifestOf(s, &segments);
    var mismatch: Manifest.Mismatch = .{};
    var expected = expectedOf(m);
    expected.mismatch = &mismatch;
    var other_fields: [schema.len]Manifest.Field = undefined;
    const broken = gen.enumValue(s, Broken);
    const want: Manifest.ParseError = switch (broken) {
        .generation => blk: {
            m.generation +%= gen.intRange(s, u64, 1, 5);
            break :blk error.Corrupt;
        },
        .term_bytes => blk: {
            m.term_bytes = if (m.term_bytes == 255) 1 else m.term_bytes + 1;
            break :blk error.SchemaMismatch;
        },
        .fields => blk: {
            // Any other count of the same fields.
            const other = (m.fields.len + gen.intRange(s, usize, 1, schema.len)) % (schema.len + 1);
            m.fields = schema[0..other];
            break :blk error.SchemaMismatch;
        },
        .field => blk: {
            if (m.fields.len == 0) return;
            @memcpy(other_fields[0..m.fields.len], m.fields);
            const f = &other_fields[gen.intRange(s, usize, 0, m.fields.len - 1)];
            switch (gen.intRange(s, u8, 0, 4)) {
                0 => f.name = "renamed",
                1 => f.kind = if (f.kind == .text) .keyword else .text,
                2 => f.stored = !f.stored,
                3 => f.positions = !f.positions,
                else => f.analysis = if (f.analysis == .words) .words_and_identifiers else .words,
            }
            m.fields = other_fields[0..m.fields.len];
            break :blk error.SchemaMismatch;
        },
        .format => blk: {
            m.format = 0;
            break :blk error.Corrupt;
        },
        .newer => blk: {
            m.format = gen.intRange(s, u16, Manifest.current_format + 1, std.math.maxInt(u16));
            break :blk error.VersionTooNew;
        },
        .order => blk: {
            if (m.segments.len < 2) return;
            const i = gen.intRange(s, usize, 1, m.segments.len - 1);
            segments[i].number = segments[i - 1].number - gen.intRange(s, u64, 0, @min(segments[i - 1].number, 3));
            break :blk error.Corrupt;
        },
        .number => blk: {
            if (m.segments.len == 0) return;
            m.next_segment = segments[m.segments.len - 1].number - gen.intRange(s, u64, 0, @min(segments[m.segments.len - 1].number, 2));
            break :blk error.Corrupt;
        },
        .empty => blk: {
            if (m.segments.len == 0) return;
            const i = gen.intRange(s, usize, 0, m.segments.len - 1);
            segments[i] = .{ .number = segments[i].number, .docs = 0 };
            break :blk error.Corrupt;
        },
        .none_deleted, .all_deleted, .later_deletions => blk: {
            if (m.segments.len == 0) return;
            const segment = &segments[gen.intRange(s, usize, 0, m.segments.len - 1)];
            segment.deletions = switch (broken) {
                .none_deleted => .{ .generation = 0, .count = 0 },
                .all_deleted => .{ .generation = 0, .count = segment.docs + gen.intRange(s, u32, 0, @min(std.math.maxInt(u32) - segment.docs, 2)) },
                else => .{ .generation = m.generation +| 1, .count = 1 },
            };
            if (broken == .later_deletions and (m.generation == std.math.maxInt(u64) or segment.docs == 1)) return;
            break :blk error.Corrupt;
        },
    };
    const bytes = try written(testing.allocator, m);
    defer testing.allocator.free(bytes);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(want, Manifest.parse(arena.allocator(), .init(bytes), expected));
    if (want == error.SchemaMismatch) try expectMismatch(mismatch, m, expected);
}

/// The diagnostic names the first field, by place, that `recorded` and
/// `asked` hold otherwise or one of them alone, or else the term length.
fn expectMismatch(got: Manifest.Mismatch, recorded: Manifest, asked: Manifest.Expected) !void {
    const fields = @min(recorded.fields.len, asked.fields.len);
    for (0..fields + 1) |place| {
        const r: ?Manifest.Field = if (place < recorded.fields.len) recorded.fields[place] else null;
        const a: ?Manifest.Field = if (place < asked.fields.len) asked.fields[place] else null;
        if (r == null and a == null) break;
        if (r != null and a != null and std.mem.eql(u8, r.?.name, a.?.name) and std.meta.eql(withoutName(r.?), withoutName(a.?))) continue;
        const f = got.what.field;
        try testing.expectEqual(place, f.place);
        try testing.expectEqual(r == null, f.recorded == null);
        try testing.expectEqual(a == null, f.asked == null);
        if (r) |field| {
            try testing.expectEqualStrings(field.name, f.recorded.?.name);
            try testing.expectEqual(withoutName(field), withoutName(f.recorded.?));
        }
        if (a) |field| try testing.expectEqualStrings(field.name, f.asked.?.name);
        return;
    }
    try testing.expectEqual(Manifest.Mismatch.What{ .term_bytes = .{ .recorded = recorded.term_bytes, .asked = asked.term_bytes } }, got.what);
}

fn withoutName(f: Manifest.Field) Manifest.Field {
    var copy = f;
    copy.name = "";
    return copy;
}

test "each rule a manifest breaks is refused with its error" {
    try shakedown.check(testing.allocator, {}, breaks, .{ .seed = 0x62726b6e, .cases = 2000 });
}

test "a manifest is written to be read by a person" {
    const segments = [_]Manifest.Segment{ .{ .number = 3, .docs = 1000, .deletions = .{ .generation = 6, .count = 10 } }, .{ .number = 5, .docs = 20 } };
    const m: Manifest = .{ .generation = 7, .next_segment = 6, .term_bytes = 255, .fields = schema[1..2], .segments = &segments };
    const bytes = try written(testing.allocator, m);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(
        \\{
        \\  "format": 1,
        \\  "generation": 7,
        \\  "next_segment": 6,
        \\  "term_bytes": 255,
        \\  "fields": [
        \\    {
        \\      "name": "level",
        \\      "kind": "keyword",
        \\      "positions": false,
        \\      "offsets": false,
        \\      "analysis": "words",
        \\      "stored": true
        \\    }
        \\  ],
        \\  "segments": [
        \\    {
        \\      "number": 3,
        \\      "docs": 1000,
        \\      "deletions": {
        \\        "generation": 6,
        \\        "count": 10
        \\      }
        \\    },
        \\    {
        \\      "number": 5,
        \\      "docs": 20,
        \\      "deletions": null
        \\    }
        \\  ]
        \\}
        \\
    , bytes);
}

fn names(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var buffer: [Manifest.name_bytes]u8 = undefined;
    const generation = gen.int(s, u64);
    try testing.expectEqual(generation, Manifest.generationOf(Manifest.name(&buffer, generation)).?);
    // Any entry that reads as a generation is that generation's name exactly.
    var entry: [Manifest.name_bytes + 2]u8 = undefined;
    const len = gen.intRange(s, usize, Manifest.name_bytes - 1, entry.len);
    const named = Manifest.name(&buffer, gen.int(s, u64));
    for (entry[0..len], 0..) |*c, i| c.* = if (i < named.len and gen.intRange(s, u8, 0, 9) != 0) named[i] else "0aF.mx"[gen.intRange(s, usize, 0, 5)];
    if (Manifest.generationOf(entry[0..len])) |g| try testing.expectEqualStrings(entry[0..len], Manifest.name(&buffer, g));
}

test "names and generations map one to one" {
    try shakedown.check(testing.allocator, {}, names, .{ .seed = 0x6e616d65, .cases = 3000 });
}

fn keepsRules(m: Manifest) !void {
    try testing.expect(m.format >= 1 and m.format <= Manifest.current_format);
    var before: ?u64 = null;
    for (m.segments) |segment| {
        if (before) |b| try testing.expect(segment.number > b);
        try testing.expect(segment.number < m.next_segment and segment.docs > 0);
        if (segment.deletions) |d| try testing.expect(d.count > 0 and d.count < segment.docs and d.generation <= m.generation);
        before = segment.number;
    }
}

fn readAny(bytes: []const u8, expected: Manifest.Expected) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = Manifest.parse(arena.allocator(), .init(bytes), expected) catch |err| switch (err) {
        error.Corrupt, error.VersionTooNew, error.SchemaMismatch => return,
        error.OutOfMemory => return err,
    };
    try keepsRules(m);
}

fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    var bytes: [256]u8 = undefined;
    try readAny(gen.bytesInto(case.source, &bytes), .{ .generation = 0, .fields = &.{}, .term_bytes = 255 });
}

test "fuzz: any bytes are refused as a manifest, or read as one that keeps every rule" {
    try shakedown.check(testing.allocator, {}, anyBytes, .{ .seed = 0x66757a7a, .cases = 3000 });
}

fn damaged(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var segments: [12]Manifest.Segment = undefined;
    const m = manifestOf(s, &segments);
    const bytes = try written(testing.allocator, m);
    defer testing.allocator.free(bytes);
    for (0..gen.intRange(s, usize, 1, 4)) |_| {
        bytes[gen.intRange(s, usize, 0, bytes.len - 1)] = "0123456789-,:{}[]\" en"[gen.intRange(s, usize, 0, 20)];
    }
    try readAny(bytes, expectedOf(m));
}

test "fuzz: a damaged manifest is refused, or read as one that keeps every rule" {
    try shakedown.check(testing.allocator, {}, damaged, .{ .seed = 0x64616d67, .cases = 3000 });
}
