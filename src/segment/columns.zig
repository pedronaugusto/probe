//! A numeric field's column in a segment: every document's value, as its
//! column's `u64` (`Schema.columnValue`), in blocks of 128 documents, each
//! with its least and greatest value so a range can pass a block whole.
//!
//! The bytes of one column:
//!
//!     headers     per block: its least value, its greatest, and where its
//!                 data starts in the data, u64 each, little endian
//!     data        per block: a bits byte; for 0 to 32, each value's
//!                 distance from the least packed to that many bits
//!                 (`bitpack`), the short last block padded with zeros; for
//!                 64, the 128 values themselves, u64 little endian
//!
//! A column is read through a cursor that holds one block decoded. What it
//! reads is checked: a block's data inside the bytes, its values inside its
//! least and greatest. Bytes that break a rule are `error.Corrupt`.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const bitpack = @import("../encoding/bitpack.zig");

const Allocator = std.mem.Allocator;
const block_len = bitpack.block_len;

pub const Error = error{Corrupt};

const header_bytes = 24;
const raw_bits = 64;

fn blocksOf(docs: u32) usize {
    return (@as(usize, docs) + block_len - 1) / block_len;
}

/// A block's least and greatest value.
pub const Bounds = struct {
    min: u64,
    max: u64,
};

/// Appends the column of `values`, one per document, to `out`.
pub fn write(gpa: Allocator, out: *std.ArrayList(u8), values: []const u64) Allocator.Error!void {
    aegis.assert.invariant(values.len <= std.math.maxInt(u32), "a segment holds fewer than 2^32 documents");
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var at: usize = 0;
    while (at < values.len) : (at += block_len) {
        const block = values[at..@min(at + block_len, values.len)];
        const min = std.mem.min(u64, block);
        const max = std.mem.max(u64, block);
        var header: [header_bytes]u8 = undefined;
        std.mem.writeInt(u64, header[0..8], min, .little);
        std.mem.writeInt(u64, header[8..16], max, .little);
        std.mem.writeInt(u64, header[16..24], data.items.len, .little);
        try out.appendSlice(gpa, &header);
        if (max - min <= std.math.maxInt(u32)) {
            var deltas: [block_len]u32 = @splat(0);
            for (block, deltas[0..block.len]) |v, *d| d.* = @intCast(v - min);
            var packed_bytes: [bitpack.max_block_bytes]u8 = undefined;
            const bits = bitpack.bitsFor(&deltas);
            bitpack.pack(&deltas, bits, &packed_bytes);
            try data.append(gpa, bits);
            try data.appendSlice(gpa, packed_bytes[0..bitpack.packedBytes(bits)]);
        } else {
            try data.append(gpa, raw_bits);
            for (0..block_len) |i| {
                var raw: [8]u8 = undefined;
                std.mem.writeInt(u64, &raw, if (i < block.len) block[i] else min, .little);
                try data.appendSlice(gpa, &raw);
            }
        }
    }
    try out.appendSlice(gpa, data.items);
}

/// A column read back, borrowing its bytes.
pub const Column = struct {
    docs: u32,
    headers: []const u8,
    data: []const u8,

    /// The column of `docs` documents that `bytes` hold, exactly.
    pub fn parse(bytes: []const u8, docs: u32) Error!Column {
        const header_len = blocksOf(docs) * header_bytes;
        if (header_len > bytes.len) return error.Corrupt;
        const c: Column = .{ .docs = docs, .headers = bytes[0..header_len], .data = bytes[header_len..] };
        // Each block's data starts where the one before ends.
        var expected: u64 = 0;
        for (0..blocksOf(docs)) |b| {
            const h = c.headers[b * header_bytes ..][0..header_bytes];
            if (std.mem.readInt(u64, h[0..8], .little) > std.mem.readInt(u64, h[8..16], .little)) return error.Corrupt;
            if (std.mem.readInt(u64, h[16..24], .little) != expected) return error.Corrupt;
            if (expected >= c.data.len) return error.Corrupt;
            const bits = c.data[@intCast(expected)];
            const len: usize = if (bits == raw_bits) block_len * 8 else if (bits <= bitpack.max_bits) bitpack.packedBytes(@intCast(bits)) else return error.Corrupt;
            expected += 1 + len;
            if (expected > c.data.len) return error.Corrupt;
        }
        if (expected != c.data.len) return error.Corrupt;
        return c;
    }

    /// The bounds of block `block`: of documents `block * 128` on.
    pub fn bounds(c: Column, block: u32) Bounds {
        const h = c.headers[@as(usize, block) * header_bytes ..][0..header_bytes];
        return .{ .min = std.mem.readInt(u64, h[0..8], .little), .max = std.mem.readInt(u64, h[8..16], .little) };
    }

    /// The column's blocks.
    pub fn blocks(c: Column) u32 {
        return @intCast(blocksOf(c.docs));
    }
};

/// A column's values read a block at a time.
pub const Cursor = struct {
    column: Column,
    block: ?u32 = null,
    values: [block_len]u64 = undefined,

    pub fn init(column: Column) Cursor {
        return .{ .column = column };
    }

    /// `doc`'s value; `doc` is below the column's documents.
    pub fn get(c: *Cursor, doc: u32) Error!u64 {
        aegis.assert.invariant(doc < c.column.docs, "a doc id is below the segment's documents");
        const block = doc / block_len;
        if (c.block != block) try c.load(block);
        return c.values[doc % block_len];
    }

    fn load(c: *Cursor, block: u32) Error!void {
        c.block = null;
        const b = c.column.bounds(block);
        const h = c.column.headers[@as(usize, block) * header_bytes ..][0..header_bytes];
        const at: usize = @intCast(std.mem.readInt(u64, h[16..24], .little));
        const bits = c.column.data[at];
        if (bits == raw_bits) {
            for (&c.values, 0..) |*v, i| v.* = std.mem.readInt(u64, c.column.data[at + 1 + i * 8 ..][0..8], .little);
            for (c.values[0..lenOf(c.column.docs, block)]) |v| if (v < b.min or v > b.max) return error.Corrupt;
        } else {
            var deltas: [block_len]u32 = undefined;
            bitpack.unpack(c.column.data[at + 1 ..][0..bitpack.packedBytes(@intCast(bits))], @intCast(bits), &deltas);
            for (&c.values, deltas) |*v, d| {
                v.* = std.math.add(u64, b.min, d) catch return error.Corrupt;
            }
            for (c.values[0..lenOf(c.column.docs, block)]) |v| if (v > b.max) return error.Corrupt;
        }
        c.block = block;
    }
};

fn lenOf(docs: u32, block: u32) usize {
    return @min(block_len, @as(usize, docs) - @as(usize, block) * block_len);
}
