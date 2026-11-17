//! A segment's stored fields: for each document, the values of the fields
//! the schema stores, in blocks of about 16 KiB each compressed with LZ4
//! (warp), so a document is read by decompressing one block.
//!
//! A document's values, in the order of the stored fields: a text or
//! keyword value as its length and its bytes, a numeric value as itself,
//! each a varint. The body of the store file:
//!
//!     blocks       a varint
//!     table        per block: its first document and its length decoded,
//!                  u32 each, then where it starts in the data, u64, and
//!                  its length there, u32, little endian
//!     data         the blocks, each an LZ4 block
//!
//! What is read is checked: the table (first documents rising from zero,
//! the blocks contiguous in the data, each no longer decoded than the
//! caller's bound), a block's decoded length, and each value inside it.
//! Bytes that break a rule are `error.Corrupt`.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const warp = @import("warp");
const Schema = @import("../Schema.zig");
const varint = @import("../encoding/varint.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{Corrupt};

/// A block is closed once it holds this much.
pub const block_bytes = 16 * 1024;

const entry_bytes = 20;

/// A stored value.
pub const Value = union(enum) {
    bytes: []const u8,
    numeric: u64,
};

/// The store being written, a document at a time.
pub const Writer = struct {
    gpa: Allocator,
    compressor: warp.lz4.Compressor,
    /// The block being gathered, its first document, and the documents so far.
    raw: std.ArrayList(u8) = .empty,
    first: u32 = 0,
    docs: u32 = 0,
    table: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    blocks: u32 = 0,

    pub fn init(gpa: Allocator) Allocator.Error!Writer {
        return .{ .gpa = gpa, .compressor = try .init(gpa, .{}) };
    }

    pub fn deinit(w: *Writer) void {
        w.raw.deinit(w.gpa);
        w.table.deinit(w.gpa);
        w.data.deinit(w.gpa);
        w.compressor.deinit();
    }

    /// The next document's stored values, in the order of the stored fields.
    pub fn add(w: *Writer, values: []const Value) Allocator.Error!void {
        for (values) |v| switch (v) {
            .bytes => |b| {
                try varint.append(w.gpa, &w.raw, b.len);
                try w.raw.appendSlice(w.gpa, b);
            },
            .numeric => |n| try varint.append(w.gpa, &w.raw, n),
        };
        w.docs += 1;
        if (w.raw.items.len >= block_bytes) try w.close();
    }

    /// Compresses the block gathered so far, if it holds a document.
    fn close(w: *Writer) Allocator.Error!void {
        if (w.docs == w.first) return;
        aegis.assert.invariant(w.raw.items.len <= std.math.maxInt(u32), "a block decodes to less than 4 GiB");
        const start = w.data.items.len;
        try w.data.ensureUnusedCapacity(w.gpa, warp.lz4.blockBound(w.raw.items.len));
        const len = w.compressor.compressBlock(w.raw.items, w.data.unusedCapacitySlice(), .{}) catch aegis.assert.never("an output of blockBound bytes always holds the block");
        w.data.items.len += len;
        var entry: [entry_bytes]u8 = undefined;
        std.mem.writeInt(u32, entry[0..4], w.first, .little);
        std.mem.writeInt(u32, entry[4..8], @intCast(w.raw.items.len), .little);
        std.mem.writeInt(u64, entry[8..16], start, .little);
        std.mem.writeInt(u32, entry[16..20], @intCast(len), .little);
        try w.table.appendSlice(w.gpa, &entry);
        w.blocks += 1;
        w.first = w.docs;
        w.raw.clearRetainingCapacity();
    }

    /// Appends the store's body to `out`.
    pub fn finish(w: *Writer, out: *std.ArrayList(u8)) Allocator.Error!void {
        try w.close();
        try varint.append(w.gpa, out, w.blocks);
        try out.appendSlice(w.gpa, w.table.items);
        try out.appendSlice(w.gpa, w.data.items);
    }
};

/// One block's place in the table.
const Entry = struct {
    first: u32,
    raw: u32,
    start: u64,
    len: u32,
};

/// A store read back, borrowing its body.
pub const Store = struct {
    docs: u32,
    fields: []const Schema.Field,
    blocks: u32,
    table: []const u8,
    data: []const u8,

    /// The store `body` holds for `docs` documents of `schema`, each block
    /// decoding to at most `max_block` bytes.
    pub fn parse(body: []const u8, docs: u32, schema: []const Schema.Field, max_block: u32) Error!Store {
        var at: usize = 0;
        const blocks: u32 = @intCast(try varint.readAtMost(body, &at, docs));
        const table_len = @as(usize, blocks) * entry_bytes;
        if (table_len > body.len - at) return error.Corrupt;
        const s: Store = .{ .docs = docs, .fields = schema, .blocks = blocks, .table = body[at..][0..table_len], .data = body[at + table_len ..] };
        var expected: u64 = 0;
        var before: ?u32 = null;
        for (0..blocks) |b| {
            const e = s.entry(@intCast(b));
            if (if (before) |f| e.first <= f else e.first != 0) return error.Corrupt;
            if (e.first >= docs or e.raw > max_block or e.start != expected) return error.Corrupt;
            expected += e.len;
            if (expected > s.data.len) return error.Corrupt;
            before = e.first;
        }
        if (expected != s.data.len or (blocks == 0) != (docs == 0)) return error.Corrupt;
        return s;
    }

    fn entry(s: Store, block: u32) Entry {
        const e = s.table[@as(usize, block) * entry_bytes ..][0..entry_bytes];
        return .{
            .first = std.mem.readInt(u32, e[0..4], .little),
            .raw = std.mem.readInt(u32, e[4..8], .little),
            .start = std.mem.readInt(u64, e[8..16], .little),
            .len = std.mem.readInt(u32, e[16..20], .little),
        };
    }

    /// `doc`'s stored values, one per stored field, in `out`; the bytes ones
    /// point into `buffer`, which holds the decoded block afterwards.
    pub fn read(s: Store, gpa: Allocator, doc: u32, buffer: *std.ArrayList(u8), out: []Value) (Error || Allocator.Error)!void {
        aegis.assert.invariant(doc < s.docs, "a doc id is below the segment's documents");
        var slots: usize = 0;
        for (s.fields) |f| slots += @intFromBool(f.stored);
        aegis.assert.invariant(out.len == slots, "a value for each stored field");
        // The last block whose first document is at or before `doc`.
        var lo: u32 = 0;
        var hi: u32 = s.blocks;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (s.entry(mid).first <= doc) lo = mid else hi = mid;
        }
        const e = s.entry(lo);
        const end_doc = if (lo + 1 < s.blocks) s.entry(lo + 1).first else s.docs;
        try buffer.resize(gpa, e.raw);
        const decoded = warp.lz4.decompressBlock(s.data[@intCast(e.start)..][0..e.len], buffer.items, .{}) catch return error.Corrupt;
        if (decoded.out_len != e.raw) return error.Corrupt;
        var at: usize = 0;
        var d = e.first;
        while (d < end_doc) : (d += 1) {
            var slot: usize = 0;
            for (s.fields) |f| {
                if (!f.stored) continue;
                const value = try readValue(buffer.items, &at, f.kind);
                if (d == doc) out[slot] = value;
                slot += 1;
            }
        }
        if (at != buffer.items.len) return error.Corrupt;
    }
};

fn readValue(raw: []const u8, at: *usize, kind: Schema.Kind) Error!Value {
    switch (kind) {
        .numeric => return .{ .numeric = try varint.read(raw, at) },
        .text, .keyword => {
            const len: usize = @intCast(try varint.readAtMost(raw, at, raw.len - at.*));
            const bytes = raw[at.*..][0..len];
            at.* += len;
            return .{ .bytes = bytes };
        },
    }
}
