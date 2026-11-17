//! A segment read back from its files' bodies, each already checked by
//! `files.Expected.check`: the term dictionary, the postings and positions
//! a term's addresses lead to, each document's length in each text field,
//! and the ids.
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

const Allocator = std.mem.Allocator;

pub const Error = error{Corrupt};

/// The bodies of a segment's files.
pub const Bodies = struct {
    terms: []const u8,
    postings: []const u8,
    positions: []const u8,
    lengths: []const u8,
    ids: []const u8,
};

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

/// A segment read back, borrowing its bodies.
pub const Segment = struct {
    schema: []const Schema.Field,
    docs: u32,
    dictionary: terms.Dictionary,
    postings: []const u8,
    positions: []const u8,
    /// By place; a field that is not text has none.
    lengths: []?Lengths,
    id_column: []const u8,
    id_map: fst.Fst,

    /// The segment `bodies` hold, of documents of `schema`. Its structure
    /// is checked here; a term's postings and positions when they are read.
    pub fn parse(gpa: Allocator, bodies: Bodies, schema: []const Schema.Field) (Error || Allocator.Error)!Segment {
        var at: usize = 0;
        const docs: u32 = @intCast(try varint.readAtMost(bodies.ids, &at, std.math.maxInt(u32)));
        const column_bytes = @as(usize, docs) * 8;
        if (column_bytes > bodies.ids.len - at) return error.Corrupt;
        const id_column = bodies.ids[at..][0..column_bytes];
        const id_map = try fst.Fst.parse(bodies.ids[at + column_bytes ..]);
        if (id_map.keys > docs) return error.Corrupt;

        const lengths = try gpa.alloc(?Lengths, schema.len);
        errdefer gpa.free(lengths);
        @memset(lengths, null);
        try readLengths(bodies.lengths, schema, docs, lengths);

        const dictionary = try terms.Dictionary.parse(bodies.terms, @intCast(schema.len));
        return .{
            .schema = schema,
            .docs = docs,
            .dictionary = dictionary,
            .postings = bodies.postings,
            .positions = bodies.positions,
            .lengths = lengths,
            .id_column = id_column,
            .id_map = id_map,
        };
    }

    pub fn deinit(s: *Segment, gpa: Allocator) void {
        gpa.free(s.lengths);
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
    /// term there.
    pub fn term(s: *const Segment, place: u32, bytes: []const u8) Error!?TermReader {
        const field = try s.dictionary.field(place) orelse return null;
        const address = try field.lookup(bytes) orelse return null;
        return try s.readerAt(place, address);
    }

    /// The postings and positions at `address`, a term's in the field at
    /// `place` (as a walk of the field's dictionary gives it).
    pub fn readerAt(s: *const Segment, place: u32, address: terms.Address) Error!TermReader {
        if (address.postings >= s.postings.len) return error.Corrupt;
        const p = try postings.Reader.parse(s.postings[@intCast(address.postings)..], s.docs);
        const keeps = s.schema[place].positions;
        if (keeps != (address.positions != terms.no_positions)) return error.Corrupt;
        if (!keeps) return .{ .postings = p, .positions = null };
        if (address.positions >= s.positions.len) return error.Corrupt;
        return .{ .postings = p, .positions = try positions.Reader.parse(s.positions[@intCast(address.positions)..], p.docFreq(), s.schema[place].offsets) };
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
    pub fn docOf(s: *const Segment, id: u64) Error!?u32 {
        var key: [8]u8 = undefined;
        std.mem.writeInt(u64, &key, id, .big);
        const doc = try s.id_map.get(&key) orelse return null;
        if (doc >= s.docs or s.idOf(@intCast(doc)) != id) return error.Corrupt;
        return @intCast(doc);
    }
};
