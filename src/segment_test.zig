//! A segment written from documents and read back, against a model built
//! from the same analysis: every term's postings, positions and offsets,
//! every document's lengths and id, the last document of each id, and terms
//! the segment does not hold.
const std = @import("std");
const shakedown = @import("shakedown");
const segment = @import("segment.zig");
const Schema = @import("Schema.zig");
const Pipeline = @import("analysis.zig").Pipeline;

const testing = std.testing;
const gen = shakedown.gen;
const write = segment.write;
const files = segment.files;
const positions = segment.positions;
const Posting = segment.postings.Posting;

const max_fields = 4;
const max_docs = 300;

const words = [_][]const u8{ "alpha", "Beta", "gamma_delta", "x", "parseSpan", "\u{e9}t\u{e9}", "Stra\u{df}e", "a", "HTTPServer", "std.mem" };
const between = [_][]const u8{ " ", ", ", ". ", "\n", "-" };

fn textOf(s: *shakedown.Source, buffer: []u8) []const u8 {
    var len: usize = 0;
    for (0..gen.intRange(s, usize, 0, 12)) |_| {
        const word = words[gen.intRange(s, usize, 0, words.len - 1)];
        const gap = between[gen.intRange(s, usize, 0, between.len - 1)];
        if (len + word.len + gap.len > buffer.len) break;
        @memcpy(buffer[len..][0..word.len], word);
        len += word.len;
        @memcpy(buffer[len..][0..gap.len], gap);
        len += gap.len;
    }
    return buffer[0..len];
}

/// One posting of the model: its doc, and its tokens.
const ModelPosting = struct { doc: u32, tokens: std.ArrayList(positions.Token) = .empty };

/// A field's terms in the model.
const ModelField = std.array_hash_map.String(std.ArrayList(ModelPosting));

const Model = struct {
    arena: std.heap.ArenaAllocator,
    fields: [max_fields]ModelField = @splat(.empty),
    lengths: [max_fields][max_docs]u32 = undefined,
    ids: [max_docs]u64 = undefined,
    numbers: [max_fields][max_docs]u64 = undefined,

    fn note(m: *Model, place: usize, term: []const u8, doc: u32, token: positions.Token) !void {
        const a = m.arena.allocator();
        const slot = try m.fields[place].getOrPut(a, term);
        if (!slot.found_existing) {
            slot.key_ptr.* = try a.dupe(u8, term);
            slot.value_ptr.* = .empty;
        }
        const list = slot.value_ptr;
        if (list.items.len == 0 or list.items[list.items.len - 1].doc != doc) try list.append(a, .{ .doc = doc });
        try list.items[list.items.len - 1].tokens.append(a, token);
    }
};

fn schemaOf(s: *shakedown.Source, out: *[max_fields]Schema.Field) []Schema.Field {
    const n = gen.intRange(s, usize, 1, max_fields);
    for (out[0..n]) |*f| {
        const kind = gen.enumValue(s, Schema.Kind);
        const keeps = kind == .text and gen.boolean(s);
        f.* = .{
            .name = "f",
            .kind = kind,
            .positions = keeps,
            .offsets = keeps and gen.boolean(s),
            .analysis = gen.enumValue(s, Schema.Analysis),
        };
    }
    return out[0..n];
}

fn againstModel(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var schema_buffer: [max_fields]Schema.Field = undefined;
    const schema = schemaOf(s, &schema_buffer);
    const term_bytes: u16 = if (gen.intRange(s, u8, 0, 4) == 0) gen.intRange(s, u16, 1, 4) else 255;
    var model: Model = .{ .arena = .init(gpa) };
    defer model.arena.deinit();
    var builder: write.Builder = try .init(gpa, schema, term_bytes);
    defer builder.deinit();

    const docs = if (gen.boolean(s)) gen.intRange(s, u32, 120, max_docs) else gen.intRange(s, u32, 0, 20);
    var term_buffer: [255]u8 = undefined;
    for (0..docs) |d| {
        const doc: u32 = @intCast(d);
        var texts: [max_fields][96]u8 = undefined;
        var values: [max_fields]write.Value = undefined;
        for (schema, 0..) |f, place| {
            switch (f.kind) {
                .text => {
                    const text = textOf(s, &texts[place]);
                    values[place] = .{ .text = text };
                    var count: u32 = 0;
                    switch (f.analysis) {
                        inline else => |analysis| {
                            var tokens: Pipeline.Of(analysis) = .init(text, term_buffer[0..term_bytes]);
                            while (tokens.next()) |t| {
                                count += 1;
                                try model.note(place, t.term, doc, .{ .position = t.position, .start = if (f.offsets) t.start else 0, .end = if (f.offsets) t.end else 0 });
                            }
                        },
                    }
                    model.lengths[place][doc] = count;
                },
                .keyword => {
                    const word = words[gen.intRange(s, usize, 0, words.len - 1)];
                    values[place] = .{ .keyword = word };
                    try model.note(place, word[0..@min(word.len, term_bytes)], doc, .{ .position = 0 });
                },
                .numeric => {
                    model.numbers[place][doc] = if (gen.boolean(s)) gen.int(s, u64) else gen.intRange(s, u64, 0, 50);
                    values[place] = .{ .numeric = model.numbers[place][doc] };
                },
            }
        }
        model.ids[doc] = gen.intRange(s, u64, 0, 2 * docs);
        try testing.expectEqual(doc, try builder.add(.{ .id = model.ids[doc], .values = values[0..schema.len] }));
    }

    const segment_number = gen.int(s, u64);
    var out = try builder.finish(segment_number);
    defer out.deinit(gpa);
    var bodies: segment.read.Bodies = undefined;
    inline for (.{ "terms", "postings", "positions", "lengths", "ids", "columns" }) |name| {
        const kind = @field(files.Kind, name);
        const e: files.Expected = .{ .kind = kind, .segment = segment_number };
        @field(bodies, name) = (try e.check(.init(out.of(kind)))).bytes;
    }
    var seg = try segment.read.Segment.parse(gpa, bodies, schema);
    defer seg.deinit(gpa);
    try testing.expectEqual(docs, seg.docs);

    for (schema, 0..) |f, p| {
        const place: u32 = @intCast(p);
        var it = model.fields[p].iterator();
        while (it.next()) |entry| {
            var r = (try seg.term(place, entry.key_ptr.*)) orelse return error.TestExpectedEqual;
            try expectPostings(&r, entry.value_ptr.items, f);
        }
        // A term the field does not hold.
        if (!model.fields[p].contains("zz")) try testing.expectEqual(null, try seg.term(place, "zz"));
        if (f.kind == .text) {
            var total: u64 = 0;
            for (0..docs) |d| {
                try testing.expectEqual(model.lengths[p][d], seg.length(place, @intCast(d)));
                total += model.lengths[p][d];
            }
            try testing.expectEqual(total, seg.total(place));
        }
        if (f.kind == .numeric) {
            var cursor: segment.columns.Cursor = .init(seg.column(place));
            for (0..docs) |d| try testing.expectEqual(model.numbers[p][d], try cursor.get(@intCast(d)));
        }
    }
    for (0..docs) |d| {
        try testing.expectEqual(model.ids[d], seg.idOf(@intCast(d)));
        var last: u32 = @intCast(d);
        for (d + 1..docs) |later| if (model.ids[later] == model.ids[d]) {
            last = @intCast(later);
        };
        try testing.expectEqual(last, (try seg.docOf(model.ids[d])).?);
    }
    if (docs == 0) try testing.expectEqual(null, try seg.docOf(7));
}

fn expectPostings(r: *segment.read.TermReader, want: []const ModelPosting, f: Schema.Field) !void {
    var block: u32 = 0;
    var at: usize = 0;
    while (at < want.len) : (block += 1) {
        const docs = want[at..@min(at + 128, want.len)];
        if (r.positions) |*pos| {
            var tokens: u64 = 0;
            for (docs) |d| tokens += d.tokens.items.len;
            try pos.enter(block, tokens);
        }
        for (docs) |d| {
            const got = (try r.postings.next()) orelse return error.TestExpectedEqual;
            try testing.expectEqual(Posting{ .doc = d.doc, .freq = @intCast(d.tokens.items.len) }, got);
            if (r.positions) |*pos| {
                try pos.document(got.freq);
                for (d.tokens.items) |t| try testing.expectEqual(t, (try pos.next()).?);
                try testing.expectEqual(null, try pos.next());
            }
        }
        at += docs.len;
    }
    try testing.expectEqual(null, try r.postings.next());
    try testing.expectEqual(f.positions, r.positions != null);
}

test "a segment reads back as its documents: postings, positions, offsets, lengths and ids" {
    try shakedown.check(testing.allocator, {}, againstModel, .{ .seed = 0x7365676d, .cases = 200 });
}

fn anyBodies(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var schema_buffer: [max_fields]Schema.Field = undefined;
    const schema = schemaOf(s, &schema_buffer);
    var buffers: [6][128]u8 = undefined;
    const bodies: segment.read.Bodies = .{
        .terms = gen.bytesInto(s, &buffers[0]),
        .postings = gen.bytesInto(s, &buffers[1]),
        .positions = gen.bytesInto(s, &buffers[2]),
        .lengths = gen.bytesInto(s, &buffers[3]),
        .ids = gen.bytesInto(s, &buffers[4]),
        .columns = gen.bytesInto(s, &buffers[5]),
    };
    var seg = segment.read.Segment.parse(gpa, bodies, schema) catch return;
    defer seg.deinit(gpa);
    for (schema, 0..) |f, p| {
        const place: u32 = @intCast(p);
        const found = seg.term(place, words[gen.intRange(s, usize, 0, words.len - 1)]) catch null;
        if (found) |r| {
            var reader = r;
            while (reader.postings.next() catch null) |_| {}
        }
        if (f.kind == .text) for (0..seg.docs) |d| {
            _ = seg.length(place, @intCast(d));
        };
        if (f.kind == .numeric) {
            var cursor: segment.columns.Cursor = .init(seg.column(place));
            for (0..seg.docs) |d| _ = cursor.get(@intCast(d)) catch break;
        }
    }
    for (0..seg.docs) |d| _ = seg.docOf(seg.idOf(@intCast(d))) catch {};
}

test "fuzz: any bodies are refused as a segment, or read within it" {
    try shakedown.check(testing.allocator, {}, anyBodies, .{ .seed = 0x66757a7a, .cases = 3000 });
}
