//! A segment read back from its file's sections: the term dictionary, the
//! lengths, the ids and the columns held in memory, each already checked
//! by its CRC-32C; the postings, each term's positions after its postings,
//! and the stored blocks read from the file as they are asked for
//! (`source.zig`). It gives the
//! postings and positions a term's addresses lead to, each document's
//! length in each text field, the ids, each numeric field's column, and
//! each document's stored values.
//!
//! What `write.zig` wrote is checked as it is read: the lengths and ids
//! against the documents, a term's addresses against the files they point
//! into, positions present exactly where the schema keeps them. Bytes that
//! break a rule are `error.Corrupt`.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const Schema = @import("../Schema.zig");
const fst = @import("../encoding/fst.zig");
const varint = @import("../encoding/varint.zig");
const postings = @import("postings.zig");
const positions = @import("positions.zig");
const terms = @import("terms.zig");
const columns = @import("columns.zig");
const store = @import("store.zig");
const source_mod = @import("source.zig");
const files = @import("files.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Source = source_mod.Source;

pub const Error = source_mod.Error;

/// The bodies of a segment's files: those held in memory, and the sources
/// of those read as they are asked for.
pub const Bodies = struct {
    terms: []const u8,
    lengths: []const u8,
    ids: []const u8,
    columns: []const u8,
    /// Each term's postings, then its positions when its field keeps them.
    postings: Source,
    store: Source,
};

/// The bodies of a segment held in memory whole, its sections checked.
pub fn inMemory(sections: files.Sections) Bodies {
    const of = struct {
        fn of(s: files.Sections, section: files.Section) []const u8 {
            return s[@backingInt(section)];
        }
    }.of;
    return .{
        .terms = of(sections, .terms),
        .lengths = of(sections, .lengths),
        .ids = of(sections, .ids),
        .columns = of(sections, .columns),
        .postings = .{ .memory = of(sections, .postings) },
        .store = .{ .memory = of(sections, .store) },
    };
}

/// A term's postings, and its positions when its field keeps them.
pub const TermReader = struct {
    postings: postings.Reader,
    positions: ?positions.Reader,
};

/// A text field's lengths: their sum, and each document's.
const Lengths = struct {
    total: u64,
    each: []const u8,
};

/// A segment read back, borrowing its bodies and its sources.
pub const Segment = struct {
    schema: []const Schema.Field,
    docs: u32,
    dictionary: terms.Dictionary,
    /// Each term's postings, then its positions when its field keeps them.
    postings: Source,
    /// By place; a field that is not text has none.
    lengths: []?Lengths,
    /// By place; a field that is not numeric has none.
    columns: []?columns.Column,
    stored: store.Store,
    id_column: []const u8,
    /// Each document added after another with its id, and that one: pairs
    /// of `u32`, rising by the first.
    earlier: []const u8,
    id_map: fst.Fst,

    /// The segment `bodies` hold, of documents of `schema`, its stored
    /// blocks decoding to at most `max_block` bytes each, its store's table
    /// read on `io`. Its structure is checked here; a term's postings and
    /// positions, and a stored block, when they are read.
    pub fn parse(gpa: Allocator, io: Io, bodies: Bodies, schema: []const Schema.Field, max_block: u32) (Error || Allocator.Error)!Segment {
        var at: usize = 0;
        const docs: u32 = @intCast(try varint.readAtMost(bodies.ids, &at, std.math.maxInt(u32)));
        const column_bytes = @as(usize, docs) * 8;
        if (column_bytes > bodies.ids.len - at) return error.Corrupt;
        const id_column = bodies.ids[at..][0..column_bytes];
        at += column_bytes;
        const earlier_count = try varint.readAtMost(bodies.ids, &at, docs);
        const earlier_bytes: usize = @intCast(earlier_count * 8);
        if (earlier_bytes > bodies.ids.len - at) return error.Corrupt;
        const earlier = bodies.ids[at..][0..earlier_bytes];
        try checkEarlier(earlier, id_column, docs);
        const id_map = try fst.Fst.parse(bodies.ids[at + earlier_bytes ..]);
        if (id_map.keys > docs) return error.Corrupt;

        const lengths = try gpa.alloc(?Lengths, schema.len);
        errdefer gpa.free(lengths);
        @memset(lengths, null);
        try readLengths(bodies.lengths, schema, docs, lengths);

        const cols = try gpa.alloc(?columns.Column, schema.len);
        errdefer gpa.free(cols);
        @memset(cols, null);
        try readColumns(bodies.columns, schema, docs, cols);

        const dictionary = try terms.Dictionary.parse(bodies.terms, @intCast(schema.len));
        var stored = try store.Store.parse(gpa, io, bodies.store, docs, schema, max_block);
        errdefer stored.deinit(gpa);
        return .{
            .schema = schema,
            .docs = docs,
            .dictionary = dictionary,
            .postings = bodies.postings,
            .lengths = lengths,
            .columns = cols,
            .stored = stored,
            .id_column = id_column,
            .earlier = earlier,
            .id_map = id_map,
        };
    }

    pub fn deinit(s: *Segment, gpa: Allocator) void {
        gpa.free(s.lengths);
        gpa.free(s.columns);
        s.stored.deinit(gpa);
    }

    fn readColumns(body: []const u8, schema: []const Schema.Field, docs: u32, out: []?columns.Column) Error!void {
        var at: usize = 0;
        var numeric: u32 = 0;
        for (schema) |f| numeric += @intFromBool(f.kind == .numeric);
        if (try varint.read(body, &at) != numeric) return error.Corrupt;
        var before: ?usize = null;
        for (0..numeric) |_| {
            const place: usize = @intCast(try varint.readAtMost(body, &at, schema.len -| 1));
            if (schema[place].kind != .numeric) return error.Corrupt;
            if (before) |b| if (place <= b) return error.Corrupt;
            before = place;
            out[place] = try columns.Column.parse(try varint.readBytes(body, &at), docs);
        }
        if (at != body.len) return error.Corrupt;
    }

    /// `doc`'s stored values, one per stored field in order, into `out`; a
    /// text or keyword value points into `buffer`, valid until it changes.
    /// Its block is read on `io`.
    pub fn storedOf(s: *const Segment, io: Io, gpa: Allocator, doc: u32, buffer: *std.ArrayList(u8), out: []store.Value) (Error || Allocator.Error)!void {
        return s.stored.read(io, gpa, doc, buffer, out);
    }

    /// The column of the numeric field at `place`.
    pub fn column(s: *const Segment, place: u32) columns.Column {
        return s.columns[place].?;
    }

    fn readLengths(body: []const u8, schema: []const Schema.Field, docs: u32, out: []?Lengths) Error!void {
        var at: usize = 0;
        var text: u32 = 0;
        for (schema) |f| text += @intFromBool(f.kind == .text);
        if (try varint.read(body, &at) != text) return error.Corrupt;
        var before: ?usize = null;
        for (0..text) |_| {
            const place: usize = @intCast(try varint.readAtMost(body, &at, schema.len -| 1));
            if (schema[place].kind != .text) return error.Corrupt;
            if (before) |b| if (place <= b) return error.Corrupt;
            before = place;
            const each_bytes = @as(usize, docs) * 4;
            if (8 + each_bytes > body.len - at) return error.Corrupt;
            const sum_stored = std.mem.readInt(u64, body[at..][0..8], .little);
            const each = body[at + 8 ..][0..each_bytes];
            at += 8 + each_bytes;
            // The sum is the lengths', so a reader may take either.
            var sum: u64 = 0;
            for (0..docs) |d| sum += std.mem.readInt(u32, each[d * 4 ..][0..4], .little);
            if (sum != sum_stored) return error.Corrupt;
            out[place] = .{ .total = sum_stored, .each = each };
        }
        if (at != body.len) return error.Corrupt;
    }

    /// The postings of `term` in the field at `place`, and its positions
    /// when the field keeps them, or null when the segment holds no such
    /// term there; they read on `io`.
    pub fn term(s: *const Segment, io: Io, place: u32, bytes: []const u8) Error!?TermReader {
        const field = try s.dictionary.field(place) orelse return null;
        const address = try field.lookup(bytes) orelse return null;
        return try s.readerAt(io, place, address);
    }

    /// The postings and positions at `address`, a term's in the field at
    /// `place` (as a walk of the field's dictionary gives it), read on `io`.
    pub fn readerAt(s: *const Segment, io: Io, place: u32, address: terms.Address) Error!TermReader {
        const p = try postings.Reader.init(s.postings, io, address.postings, s.docs);
        const keeps = s.schema[place].positions;
        if (keeps != (address.positions != terms.no_positions)) return error.Corrupt;
        if (!keeps) return .{ .postings = p, .positions = null };
        return .{ .postings = p, .positions = try positions.Reader.init(s.postings, io, address.positions, p.docFreq(), s.schema[place].offsets) };
    }

    /// `doc`'s length in the text field at `place`.
    pub fn length(s: *const Segment, place: u32, doc: u32) u32 {
        const l = s.lengths[place].?;
        return std.mem.readInt(u32, l.each[@as(usize, doc) * 4 ..][0..4], .little);
    }

    /// The sum of every document's length in the text field at `place`.
    pub fn total(s: *const Segment, place: u32) u64 {
        return s.lengths[place].?.total;
    }

    /// `doc`'s id.
    pub fn idOf(s: *const Segment, doc: u32) u64 {
        return std.mem.readInt(u64, s.id_column[@as(usize, doc) * 8 ..][0..8], .little);
    }

    /// The last document added with `id`, or null when none was.
    pub fn docOf(s: *const Segment, id: u64) error{Corrupt}!?u32 {
        var key: [8]u8 = undefined;
        std.mem.writeInt(u64, &key, id, .big);
        const doc = try s.id_map.get(&key) orelse return null;
        if (doc >= s.docs or s.idOf(@intCast(doc)) != id) return error.Corrupt;
        return @intCast(doc);
    }

    /// Every document added with `id`, the last first.
    pub fn docsOf(s: *const Segment, id: u64) error{Corrupt}!DocsOf {
        return .{ .segment = s, .doc = try s.docOf(id) };
    }

    /// The document added before `doc` with its id, if one was.
    fn earlierOf(s: *const Segment, doc: u32) ?u32 {
        var lo: usize = 0;
        var hi: usize = s.earlier.len / 8;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const at = std.mem.readInt(u32, s.earlier[mid * 8 ..][0..4], .little);
            if (at == doc) return std.mem.readInt(u32, s.earlier[mid * 8 + 4 ..][0..4], .little);
            if (at < doc) lo = mid + 1 else hi = mid;
        }
        return null;
    }
};

/// The documents of an id in a segment, the last added first.
pub const DocsOf = struct {
    segment: *const Segment,
    doc: ?u32,

    pub fn next(d: *DocsOf) ?u32 {
        const doc = d.doc orelse return null;
        d.doc = d.segment.earlierOf(doc);
        return doc;
    }
};

/// The pairs of documents added one after another with an id: rising by
/// the later, each inside the segment, the earlier before it and of the
/// same id. So a walk from an id's last document back ends.
fn checkEarlier(earlier: []const u8, id_column: []const u8, docs: u32) error{Corrupt}!void {
    var last: ?u32 = null;
    for (0..earlier.len / 8) |i| {
        const doc = std.mem.readInt(u32, earlier[i * 8 ..][0..4], .little);
        const prev = std.mem.readInt(u32, earlier[i * 8 + 4 ..][0..4], .little);
        if (last) |l| if (doc <= l) return error.Corrupt;
        if (doc >= docs or prev >= doc) return error.Corrupt;
        if (!std.mem.eql(u8, id_column[@as(usize, doc) * 8 ..][0..8], id_column[@as(usize, prev) * 8 ..][0..8])) return error.Corrupt;
        last = doc;
    }
}
