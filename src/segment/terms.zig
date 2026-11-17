//! A segment's term dictionary: for each indexed field, its terms in an FST
//! from each term to its ordinal, and a table giving each ordinal its
//! postings' address and its positions' address. The body of the terms
//! file:
//!
//!     fields                   a varint
//!     per field, rising by place:
//!         place                the field's place in the schema, a varint
//!         terms                a varint
//!         fst length           a varint, then the FST's bytes
//!         table                per term, by ordinal: its postings address
//!                              and its positions address, u64 each, little
//!                              endian; `no_positions` for a field without
//!
//! The ordinal is the term's place among the field's terms in byte order,
//! so a walk of the FST gives ordinals rising. A dictionary is checked whole
//! when parsed (each field's lengths against the bytes, its FST's footer
//! and key count against its terms); a term's ordinal when it is looked up.
//! Bytes that break a rule are `error.Corrupt`.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const fst = @import("../encoding/fst.zig");
const varint = @import("../encoding/varint.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{Corrupt};

/// The positions address of a term in a field that keeps none.
pub const no_positions = std.math.maxInt(u64);

/// Where a term's postings and positions start in their files' bodies.
pub const Address = struct {
    postings: u64,
    positions: u64 = no_positions,
};

const entry_bytes = 16;

/// One field's terms, added in strictly rising byte order.
pub const FieldWriter = struct {
    keys: fst.Builder,
    table: std.ArrayList(u8) = .empty,
    terms: u64 = 0,

    pub fn init(gpa: Allocator) FieldWriter {
        return .{ .keys = .init(gpa) };
    }

    pub fn deinit(w: *FieldWriter) void {
        w.table.deinit(w.keys.gpa);
        w.keys.deinit();
    }

    /// The next term and its addresses; `error.NotRising` unless the term
    /// is past the one before.
    pub fn add(w: *FieldWriter, term: []const u8, address: Address) fst.Builder.AddError!void {
        try w.keys.add(term, w.terms);
        var entry: [entry_bytes]u8 = undefined;
        std.mem.writeInt(u64, entry[0..8], address.postings, .little);
        std.mem.writeInt(u64, entry[8..16], address.positions, .little);
        try w.table.appendSlice(w.keys.gpa, &entry);
        w.terms += 1;
    }

    /// Appends the field, at `place` in the schema, to `out`.
    pub fn finish(w: *FieldWriter, place: u32, out: *std.ArrayList(u8)) Allocator.Error!void {
        const gpa = w.keys.gpa;
        var keys: std.ArrayList(u8) = .empty;
        defer keys.deinit(gpa);
        try w.keys.finish(&keys);
        try varint.append(gpa, out, place);
        try varint.append(gpa, out, w.terms);
        try varint.append(gpa, out, keys.items.len);
        try out.appendSlice(gpa, keys.items);
        try out.appendSlice(gpa, w.table.items);
    }
};

/// Starts a dictionary of `fields` fields, each then appended by its
/// writer's `finish`, rising by place.
pub fn begin(gpa: Allocator, out: *std.ArrayList(u8), fields: u32) Allocator.Error!void {
    try varint.append(gpa, out, fields);
}

/// A field's terms read back.
pub const Field = struct {
    place: u32,
    terms: u64,
    keys: fst.Fst,
    table: []const u8,

    /// The addresses of `term`, or null when the field does not hold it.
    pub fn lookup(f: Field, term: []const u8) Error!?Address {
        const ordinal = try f.keys.get(term) orelse return null;
        return try f.address(ordinal);
    }

    /// The addresses of the term at `ordinal`, as a walk of `keys` gives it.
    pub fn address(f: Field, ordinal: u64) Error!Address {
        if (ordinal >= f.terms) return error.Corrupt;
        const entry = f.table[@intCast(ordinal * entry_bytes)..][0..entry_bytes];
        return .{ .postings = std.mem.readInt(u64, entry[0..8], .little), .positions = std.mem.readInt(u64, entry[8..16], .little) };
    }
};

/// A term dictionary read from a terms file's body, borrowing it.
pub const Dictionary = struct {
    body: []const u8,
    fields: u32,

    /// The dictionary `body` holds, every field's structure checked, in a
    /// segment whose schema has `places` fields.
    pub fn parse(body: []const u8, places: u32) Error!Dictionary {
        var at: usize = 0;
        const fields: u32 = @intCast(try varint.readAtMost(body, &at, places));
        var before: ?u32 = null;
        for (0..fields) |_| {
            const f = try readField(body, &at, places);
            if (before) |b| if (f.place <= b) return error.Corrupt;
            before = f.place;
        }
        if (at != body.len) return error.Corrupt;
        return .{ .body = body, .fields = fields };
    }

    /// The field at `place` in the schema, or null when the segment holds
    /// no terms of it.
    pub fn field(d: Dictionary, place: u32) Error!?Field {
        var at: usize = 0;
        _ = try varint.read(d.body, &at);
        for (0..d.fields) |_| {
            const f = try readField(d.body, &at, std.math.maxInt(u32));
            if (f.place == place) return f;
            if (f.place > place) return null;
        }
        return null;
    }

    fn readField(body: []const u8, at: *usize, places: u32) Error!Field {
        const place: u32 = @intCast(try varint.readAtMost(body, at, places -| 1));
        const terms = try varint.readAtMost(body, at, body.len / entry_bytes);
        const keys = try fst.Fst.parse(try varint.readBytes(body, at));
        if (keys.keys != terms) return error.Corrupt;
        const table_len: usize = @intCast(terms * entry_bytes);
        if (table_len > body.len - at.*) return error.Corrupt;
        const table = body[at.*..][0..table_len];
        at.* += table_len;
        return .{ .place = place, .terms = terms, .keys = keys, .table = table };
    }
};
