//! A segment's stored fields: for each document, the values of the fields
//! the schema stores, in blocks of about 16 KiB each compressed with LZ4
//! (warp), so a document is read by decompressing one block. The blocks
//! are written as they close, then their table; the table is held in
//! memory, and a block is read from the `Source` when a document of it is
//! asked for.
//!
//! A document's values, in the order of the stored fields: a text or
//! keyword value as its length and its bytes, a numeric value as itself,
//! each a varint. The store's section:
//!
//!     data         the blocks, each an LZ4 block
//!     table        per block: its first document and its length decoded,
//!                  u32 each, then where it starts in the data, u64, and
//!                  its length there, u32, little endian
//!     blocks       their count, u32 little endian
//!     check        the CRC-32C of the table and the count, u32 little
//!                  endian, so the table is checked whole when it is read
//!
//! What is read is checked: the table (its CRC-32C, first documents
//! rising from zero, the blocks contiguous in the data and filling it, each
//! no longer decoded than the caller's bound nor longer compressed than its
//! decoding allows), a block's decoded length, and each value inside it.
//! Bytes that break a rule are `error.Corrupt`.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const warp = @import("warp");
const Schema = @import("../Schema.zig");
const varint = @import("../encoding/varint.zig");
const source_mod = @import("source.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Source = source_mod.Source;

pub const Error = source_mod.Error;

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
    /// The blocks closed and not yet taken, and the data's bytes before them.
    data: std.ArrayList(u8) = .empty,
    taken_bytes: u64 = 0,
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
        const start = w.taken_bytes + w.data.items.len;
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

    /// The blocks closed since the last `take`, in order, to write out
    /// before the next ones.
    pub fn ready(w: *const Writer) []const u8 {
        return w.data.items;
    }

    /// Lets the blocks `ready` gave go, written.
    pub fn take(w: *Writer) void {
        w.taken_bytes += w.data.items.len;
        w.data.clearRetainingCapacity();
    }

    /// Appends to `out` what is left of the store's section after the
    /// blocks `take` let go: the last blocks, the table, its count and its
    /// check.
    pub fn finish(w: *Writer, out: *std.ArrayList(u8)) Allocator.Error!void {
        try w.close();
        try out.appendSlice(w.gpa, w.data.items);
        const start = out.items.len;
        try out.appendSlice(w.gpa, w.table.items);
        var tail: [8]u8 = undefined;
        std.mem.writeInt(u32, tail[0..4], w.blocks, .little);
        try out.appendSlice(w.gpa, tail[0..4]);
        std.mem.writeInt(u32, tail[4..8], warp.crc32c(0, out.items[start..]), .little);
        try out.appendSlice(w.gpa, tail[4..8]);
    }
};

/// The bytes after the table: the count of blocks and the check.
const trailer_bytes = 8;

/// One block's place in the table.
const Entry = struct {
    first: u32,
    raw: u32,
    start: u64,
    len: u32,
};

/// A store read back: its table held, its blocks read from the source a
/// block at a time.
pub const Store = struct {
    docs: u32,
    fields: []const Schema.Field,
    blocks: u32,
    /// The table, its count and its check, as read: the section's last
    /// bytes.
    table: []const u8,
    source: Source,
    /// The blocks' bytes, from the section's start.
    data_len: u64,

    /// The store in `source`, a store's section, for `docs` documents of
    /// `schema`, each block decoding to at most `max_block` bytes: its
    /// table read on `io` into memory from `gpa`, and checked whole.
    pub fn parse(gpa: Allocator, io: Io, source: Source, docs: u32, schema: []const Schema.Field, max_block: u32) (Error || Allocator.Error)!Store {
        const len = source.len();
        if (len < trailer_bytes) return error.Corrupt;
        var tail: [trailer_bytes]u8 = undefined;
        try source.read(io, len - trailer_bytes, &tail);
        const blocks = std.mem.readInt(u32, tail[0..4], .little);
        if (blocks > docs) return error.Corrupt;
        const table_len = @as(u64, blocks) * entry_bytes;
        if (table_len > len - trailer_bytes) return error.Corrupt;
        const data_len = len - trailer_bytes - table_len;
        const held = try source.alloc(io, gpa, data_len, table_len + trailer_bytes);
        errdefer gpa.free(held);
        const checked = held[0..@intCast(table_len + 4)];
        if (std.mem.readInt(u32, held[checked.len..][0..4], .little) != warp.crc32c(0, checked)) return error.Corrupt;
        const s: Store = .{ .docs = docs, .fields = schema, .blocks = blocks, .table = held, .source = source, .data_len = data_len };
        var expected: u64 = 0;
        var before: ?u32 = null;
        for (0..blocks) |b| {
            const e = s.entry(@intCast(b));
            if (if (before) |f| e.first <= f else e.first != 0) return error.Corrupt;
            if (e.first >= docs or e.raw > max_block or e.len > warp.lz4.blockBound(max_block)) return error.Corrupt;
            if (e.start != expected) return error.Corrupt;
            expected += e.len;
            if (expected > data_len) return error.Corrupt;
            before = e.first;
        }
        if (expected != data_len or (blocks == 0) != (docs == 0)) return error.Corrupt;
        return s;
    }

    pub fn deinit(s: *Store, gpa: Allocator) void {
        gpa.free(s.table);
        s.* = undefined;
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

    /// A block decoded: the documents it holds, from `first` to before
    /// `end`.
    pub const Block = struct { first: u32, end: u32 };

    /// Block `block` read on `io` into `compressed` as it is in the store,
    /// and decoded into `raw`, for reading a store in order (a merge). Its
    /// documents' values are read from `raw` by `values`, in turn.
    pub fn readBlock(s: Store, io: Io, gpa: Allocator, b: u32, compressed: *std.ArrayList(u8), raw: *std.ArrayList(u8)) (Error || Allocator.Error)!Block {
        aegis.assert.invariant(b < s.blocks, "a block of the store");
        const e = s.entry(b);
        try compressed.resize(gpa, e.len);
        try s.source.read(io, e.start, compressed.items);
        try raw.resize(gpa, e.raw);
        errdefer raw.clearRetainingCapacity();
        const decoded = warp.lz4.decompressBlock(compressed.items, raw.items, .{}) catch return error.Corrupt;
        if (decoded.out_len != e.raw) return error.Corrupt;
        return .{ .first = e.first, .end = if (b + 1 < s.blocks) s.entry(b + 1).first else s.docs };
    }

    /// The next document's values in a decoded block `raw`, from `at`, one
    /// per stored field, into `out`.
    pub fn values(s: Store, raw: []const u8, at: *usize, out: []Value) Error!void {
        var slot: usize = 0;
        for (s.fields) |f| {
            if (!f.stored) continue;
            out[slot] = try readValue(raw, at, f.kind);
            slot += 1;
        }
    }

    /// `doc`'s stored values, one per stored field, in `out`, its block read
    /// on `io`; the bytes ones point into `buffer`, which holds the decoded
    /// block afterwards.
    pub fn read(s: Store, io: Io, gpa: Allocator, doc: u32, buffer: *std.ArrayList(u8), out: []Value) (Error || Allocator.Error)!void {
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
        // The compressed block is read in after the room for its decoding,
        // then the buffer is cut to the decoded block.
        try buffer.resize(gpa, @as(usize, e.raw) + e.len);
        // A refused block leaves the buffer empty.
        errdefer buffer.clearRetainingCapacity();
        const compressed = buffer.items[e.raw..];
        try s.source.read(io, e.start, compressed);
        const decoded = warp.lz4.decompressBlock(compressed, buffer.items[0..e.raw], .{}) catch return error.Corrupt;
        if (decoded.out_len != e.raw) return error.Corrupt;
        buffer.shrinkRetainingCapacity(e.raw);
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
        .text, .keyword => return .{ .bytes = try varint.readBytes(raw, at) },
    }
}
