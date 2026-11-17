//! A segment built in memory, document by document, then written as its
//! file through `files.Stream`: each term's postings and positions, the
//! stored fields, the term dictionary, the lengths, the numeric columns and
//! the ids. The sections' writers are shared with the merge.
//!
//! A document comes as its values, one per field of the schema in order,
//! and its id. A text field's value is analyzed (`analysis/Pipeline.zig`)
//! and each token counted against its term: a posting per document, its
//! frequency, and its position and offsets when the field keeps them. A
//! keyword field's value is one term, its bytes cut to the longest term. A
//! document's length in a text field is its count of tokens there.
//!
//! The sections:
//!
//!     lengths   the text fields, a varint; per text field, rising by
//!               place: its place, a varint, the sum of its lengths, u64,
//!               and each document's length, u32, little endian
//!     ids       the documents, a varint; each document's id, u64 little
//!               endian; each document added after another with its id,
//!               a count, a varint, then by document, rising, the
//!               document and the one before it with its id, u32 each,
//!               little endian; then an FST from each id, eight bytes big
//!               endian so their order is the ids', to its last document
//!     columns   the numeric fields, a varint; per numeric field, rising by
//!               place: its place and its column's length, varints, and
//!               its column (`columns.zig`)
//!     store     the stored fields' values (`store.zig`)
//!
//! The term dictionary, postings and positions are `terms.zig`'s,
//! `postings.zig`'s and `positions.zig`'s.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const Schema = @import("../Schema.zig");
const Pipeline = @import("../analysis/Pipeline.zig");
const fst = @import("../encoding/fst.zig");
const varint = @import("../encoding/varint.zig");
const files = @import("files.zig");
const postings = @import("postings.zig");
const positions = @import("positions.zig");
const columns = @import("columns.zig");
const store = @import("store.zig");
const terms = @import("terms.zig");

const Allocator = std.mem.Allocator;

/// A field's value in a document.
pub const Value = union(enum) {
    text: []const u8,
    keyword: []const u8,
    numeric: u64,
};

/// A document: its id, and a value for each field of the schema, in order.
pub const Document = struct {
    id: u64,
    values: []const Value,
};

/// A term's postings and tokens being gathered.
const Term = struct {
    postings: std.ArrayList(postings.Posting) = .empty,
    /// Every token of every posting, in order; a posting's are its freq.
    tokens: std.ArrayList(positions.Token) = .empty,
};

/// A field's terms, for a text field its lengths, and for a numeric field
/// its column.
const Field = struct {
    places: std.StringHashMapUnmanaged(u32) = .empty,
    terms: std.ArrayList(Term) = .empty,
    lengths: std.ArrayList(u32) = .empty,
    total: u64 = 0,
    column: std.ArrayList(u64) = .empty,
};

/// A segment being built.
pub const Builder = struct {
    gpa: Allocator,
    /// Holds each term's bytes once.
    arena: std.heap.ArenaAllocator,
    schema: []const Schema.Field,
    fields: []Field,
    term_buffer: []u8,
    ids: std.ArrayList(u64) = .empty,
    docs: u32 = 0,
    store: store.Writer,
    /// A document's stored values, gathered for the store.
    stored: []store.Value,

    /// A builder for documents of `schema`, each term cut to `term_bytes`.
    pub fn init(gpa: Allocator, schema: []const Schema.Field, term_bytes: u16) Allocator.Error!Builder {
        const fields = try gpa.alloc(Field, schema.len);
        errdefer gpa.free(fields);
        @memset(fields, .{});
        const term_buffer = try gpa.alloc(u8, term_bytes);
        errdefer gpa.free(term_buffer);
        const stored = try gpa.alloc(store.Value, schema.len);
        errdefer gpa.free(stored);
        return .{ .gpa = gpa, .arena = .init(gpa), .schema = schema, .fields = fields, .term_buffer = term_buffer, .store = try .init(gpa), .stored = stored };
    }

    pub fn deinit(b: *Builder) void {
        for (b.fields) |*f| {
            for (f.terms.items) |*t| {
                t.postings.deinit(b.gpa);
                t.tokens.deinit(b.gpa);
            }
            f.terms.deinit(b.gpa);
            f.places.deinit(b.gpa);
            f.lengths.deinit(b.gpa);
            f.column.deinit(b.gpa);
        }
        b.gpa.free(b.fields);
        b.gpa.free(b.term_buffer);
        b.ids.deinit(b.gpa);
        b.store.deinit();
        b.gpa.free(b.stored);
        b.arena.deinit();
    }

    /// Adds `doc`, which becomes the segment's next document; its doc id.
    pub fn add(b: *Builder, doc: Document) Allocator.Error!u32 {
        aegis.assert.invariant(doc.values.len == b.schema.len, "a document has a value for each field");
        aegis.assert.invariant(b.docs < std.math.maxInt(u32), "a segment holds fewer than 2^32 documents");
        const id = b.docs;
        for (b.schema, b.fields, doc.values) |schema, *field, value| switch (value) {
            .text => |text| {
                aegis.assert.invariant(schema.kind == .text, "a text value is a text field's");
                const count = switch (schema.analysis) {
                    inline else => |analysis| try b.analyze(Pipeline.Of(analysis), schema, field, id, text),
                };
                try field.lengths.append(b.gpa, count);
                field.total += count;
            },
            .keyword => |bytes| {
                aegis.assert.invariant(schema.kind == .keyword, "a keyword value is a keyword field's");
                try b.note(field, bytes[0..@min(bytes.len, b.term_buffer.len)], id, null);
            },
            .numeric => |number| {
                aegis.assert.invariant(schema.kind == .numeric, "a numeric value is a numeric field's");
                try field.column.append(b.gpa, number);
            },
        };
        var n: usize = 0;
        for (b.schema, doc.values) |schema, value| {
            if (!schema.stored) continue;
            b.stored[n] = switch (value) {
                .text, .keyword => |bytes| .{ .bytes = bytes },
                .numeric => |number| .{ .numeric = number },
            };
            n += 1;
        }
        try b.store.add(b.stored[0..n]);
        try b.ids.append(b.gpa, doc.id);
        b.docs += 1;
        return id;
    }

    fn analyze(b: *Builder, comptime Tokens: type, schema: Schema.Field, field: *Field, doc: u32, text: []const u8) Allocator.Error!u32 {
        var tokens: Tokens = .init(text, b.term_buffer);
        var count: u32 = 0;
        while (tokens.next()) |t| {
            count += 1;
            const token: ?positions.Token = if (!schema.positions) null else if (schema.offsets) .{ .position = t.position, .start = t.start, .end = t.end } else .{ .position = t.position };
            try b.note(field, t.term, doc, token);
        }
        return count;
    }

    /// Counts one occurrence of `term` in `doc`.
    fn note(b: *Builder, field: *Field, term: []const u8, doc: u32, token: ?positions.Token) Allocator.Error!void {
        const slot = try field.places.getOrPut(b.gpa, term);
        if (!slot.found_existing) {
            errdefer _ = field.places.remove(term);
            slot.key_ptr.* = try b.arena.allocator().dupe(u8, term);
            slot.value_ptr.* = @intCast(field.terms.items.len);
            try field.terms.append(b.gpa, .{});
        }
        const t = &field.terms.items[slot.value_ptr.*];
        const items = t.postings.items;
        if (items.len == 0 or items[items.len - 1].doc != doc) try t.postings.append(b.gpa, .{ .doc = doc, .freq = 0 });
        t.postings.items[t.postings.items.len - 1].freq += 1;
        if (token) |tk| try t.tokens.append(b.gpa, tk);
    }

    /// The segment's file, as segment `segment`: its bytes, the caller's.
    pub fn finish(b: *Builder, segment: u64) Allocator.Error!std.ArrayList(u8) {
        var out: std.Io.Writer.Allocating = .init(b.gpa);
        errdefer out.deinit();
        // An allocating writer fails only for memory.
        b.write(&out.writer, segment) catch return error.OutOfMemory;
        return out.toArrayList();
    }

    /// The segment's file, as segment `segment`, streamed into `out`.
    pub fn write(b: *Builder, out: *std.Io.Writer, segment: u64) WriteError!void {
        const gpa = b.gpa;
        var stream = try files.Stream.begin(out, segment);
        var dictionary: std.ArrayList(u8) = .empty;
        defer dictionary.deinit(gpa);
        var entry: std.ArrayList(u8) = .empty;
        defer entry.deinit(gpa);
        var indexed: u32 = 0;
        for (b.fields) |f| indexed += @intFromBool(f.terms.items.len > 0);
        try terms.begin(gpa, &dictionary, indexed);
        for (b.schema, b.fields, 0..) |schema, *field, place| {
            if (field.terms.items.len == 0) continue;
            try b.writeField(schema, field, @intCast(place), &stream, &entry, &dictionary);
        }
        stream.end(.postings);

        try stream.write(b.store.ready());
        b.store.take();
        entry.clearRetainingCapacity();
        try b.store.finish(&entry);
        try stream.write(entry.items);
        stream.end(.store);

        try stream.write(dictionary.items);
        stream.end(.terms);

        const lengths = try gpa.alloc([]const u32, b.schema.len);
        defer gpa.free(lengths);
        const totals = try gpa.alloc(u64, b.schema.len);
        defer gpa.free(totals);
        const cols = try gpa.alloc([]const u64, b.schema.len);
        defer gpa.free(cols);
        for (b.fields, lengths, totals, cols) |f, *l, *t, *c| {
            l.* = f.lengths.items;
            t.* = f.total;
            c.* = f.column.items;
        }
        entry.clearRetainingCapacity();
        try appendLengths(gpa, &entry, b.schema, lengths, totals);
        try stream.write(entry.items);
        stream.end(.lengths);
        entry.clearRetainingCapacity();
        try appendColumns(gpa, &entry, b.schema, cols);
        try stream.write(entry.items);
        stream.end(.columns);
        entry.clearRetainingCapacity();
        try appendIds(gpa, &entry, b.ids.items);
        try stream.write(entry.items);
        stream.end(.ids);
        try stream.finish();
    }

    fn writeField(b: *Builder, schema: Schema.Field, field: *Field, place: u32, stream: *files.Stream, entry: *std.ArrayList(u8), dictionary: *std.ArrayList(u8)) WriteError!void {
        const gpa = b.gpa;
        // The terms in byte order.
        const order = try gpa.alloc(Order, field.terms.items.len);
        defer gpa.free(order);
        var it = field.places.iterator();
        var n: usize = 0;
        while (it.next()) |e| : (n += 1) order[n] = .{ .term = e.key_ptr.*, .index = e.value_ptr.* };
        std.mem.sort(Order, order, {}, Order.lessThan);
        var writer: terms.FieldWriter = .init(gpa);
        defer writer.deinit();
        var slices: std.ArrayList([]const positions.Token) = .empty;
        defer slices.deinit(gpa);
        for (order) |o| {
            const t = &field.terms.items[o.index];
            slices.clearRetainingCapacity();
            if (schema.positions) {
                var at: usize = 0;
                for (t.postings.items) |p| {
                    try slices.append(gpa, t.tokens.items[at..][0..p.freq]);
                    at += p.freq;
                }
            }
            entry.clearRetainingCapacity();
            const address = try appendEntry(gpa, entry, stream.at(), schema, t.postings.items, if (schema.kind == .text) field.lengths.items else null, slices.items);
            try stream.write(entry.items);
            writer.add(o.term, address) catch |err| return rising(err);
        }
        try writer.finish(place, dictionary);
    }

    const Order = struct {
        term: []const u8,
        index: u32,

        fn lessThan(_: void, a: Order, c: Order) bool {
            return std.mem.order(u8, a.term, c.term) == .lt;
        }
    };
};

pub const WriteError = std.Io.Writer.Error || Allocator.Error;

/// Appends to `entry` a term's entry in the postings section, which starts
/// there at `at`: its postings (`postings_list`, with each document's
/// length in a text field for its impacts), then its positions when its
/// field keeps them (`tokens`, a document's per posting). Its address.
pub fn appendEntry(
    gpa: Allocator,
    entry: *std.ArrayList(u8),
    at: u64,
    schema: Schema.Field,
    postings_list: []const postings.Posting,
    lengths: ?[]const u32,
    tokens: []const []const positions.Token,
) Allocator.Error!terms.Address {
    const start = entry.items.len;
    var address: terms.Address = .{ .postings = at };
    try postings.write(gpa, entry, postings_list, lengths);
    if (schema.positions) {
        aegis.assert.invariant(tokens.len == postings_list.len, "a posting's tokens each");
        address.positions = at + (entry.items.len - start);
        try positions.write(gpa, entry, tokens, schema.offsets);
    }
    return address;
}

/// Appends the lengths section: per text field of `schema`, `totals` and
/// each document's of `lengths`, by place.
pub fn appendLengths(gpa: Allocator, out: *std.ArrayList(u8), schema: []const Schema.Field, lengths: []const []const u32, totals: []const u64) Allocator.Error!void {
    var text: u32 = 0;
    for (schema) |s| text += @intFromBool(s.kind == .text);
    try varint.append(gpa, out, text);
    for (schema, lengths, totals, 0..) |s, each, total, place| {
        if (s.kind != .text) continue;
        try varint.append(gpa, out, place);
        try appendInt(gpa, out, u64, total);
        for (each) |l| try appendInt(gpa, out, u32, l);
    }
}

/// Appends the columns section: per numeric field of `schema`, its
/// column of `values`, by place.
pub fn appendColumns(gpa: Allocator, out: *std.ArrayList(u8), schema: []const Schema.Field, values: []const []const u64) Allocator.Error!void {
    var column: std.ArrayList(u8) = .empty;
    defer column.deinit(gpa);
    var numeric: u32 = 0;
    for (schema) |s| numeric += @intFromBool(s.kind == .numeric);
    try varint.append(gpa, out, numeric);
    for (schema, values, 0..) |s, each, place| {
        if (s.kind != .numeric) continue;
        column.clearRetainingCapacity();
        try columns.write(gpa, &column, each);
        try varint.append(gpa, out, place);
        try varint.append(gpa, out, column.items.len);
        try out.appendSlice(gpa, column.items);
    }
}

/// Appends the ids section of documents whose ids are `ids`, by doc.
pub fn appendIds(gpa: Allocator, out: *std.ArrayList(u8), ids: []const u64) Allocator.Error!void {
    try varint.append(gpa, out, ids.len);
    for (ids) |id| try appendInt(gpa, out, u64, id);
    // Sorted by id, then by doc: each run is an id's documents.
    const pairs = try gpa.alloc([2]u64, ids.len);
    defer gpa.free(pairs);
    for (pairs, ids, 0..) |*p, id, doc| p.* = .{ id, doc };
    std.mem.sort([2]u64, pairs, {}, struct {
        fn lessThan(_: void, x: [2]u64, y: [2]u64) bool {
            return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]);
        }
    }.lessThan);
    // Each document added after another with its id, and that one, by doc.
    var earlier: std.ArrayList([2]u32) = .empty;
    defer earlier.deinit(gpa);
    var later: usize = 1;
    while (later < pairs.len) : (later += 1) {
        const one = pairs[later - 1];
        const two = pairs[later];
        if (one[0] == two[0]) try earlier.append(gpa, .{ @intCast(two[1]), @intCast(one[1]) });
    }
    std.mem.sort([2]u32, earlier.items, {}, struct {
        fn lessThan(_: void, x: [2]u32, y: [2]u32) bool {
            return x[0] < y[0];
        }
    }.lessThan);
    try varint.append(gpa, out, earlier.items.len);
    for (earlier.items) |e| {
        try appendInt(gpa, out, u32, e[0]);
        try appendInt(gpa, out, u32, e[1]);
    }
    // Each id to its last document: the last of each run.
    var map: fst.Builder = .init(gpa);
    defer map.deinit();
    for (pairs, 0..) |p, i| {
        if (i + 1 < pairs.len and pairs[i + 1][0] == p[0]) continue;
        var key: [8]u8 = undefined;
        std.mem.writeInt(u64, &key, p[0], .big);
        map.add(&key, p[1]) catch |err| return rising(err);
    }
    // `finish` writes into a list of its own, which it clears first.
    var keys: std.ArrayList(u8) = .empty;
    defer keys.deinit(gpa);
    try map.finish(&keys);
    try out.appendSlice(gpa, keys.items);
}

/// An FST add's error where the keys are distinct and sorted by
/// construction: only running out of memory.
pub fn rising(err: fst.Builder.AddError) Allocator.Error {
    return switch (err) {
        error.NotRising => aegis.assert.never("a field's terms and a segment's ids are added distinct and sorted"),
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn appendInt(gpa: Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) Allocator.Error!void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try out.appendSlice(gpa, &bytes);
}
