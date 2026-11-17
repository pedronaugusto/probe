//! One term's positions in a segment, and their byte offsets when the
//! field keeps them: for each document of its postings, in their order,
//! the positions the term holds there, rising (two tokens may share one).
//!
//! They are grouped as the postings are, one chunk per postings block, so
//! a reader that passes a postings block passes its chunk too. The bytes,
//! at the term's address in the positions file:
//!
//!     chunk lengths      one varint per postings block
//!     chunk per block    its positions, document after document, in
//!                        groups of 128: each position's distance from the
//!                        one before it in its document (the first's from
//!                        zero), and with offsets each token's start's
//!                        distance from the one before (the first's from
//!                        zero) and its length; a full group as a bits
//!                        byte and packed bytes per stream, a short last
//!                        group as varints, a token's values together
//!
//! A reader goes forward only: `enter` moves to a postings block's chunk,
//! `skip` passes a document's positions, `next` gives the next one of the
//! document. A full group is passed by its bits bytes without unpacking.
//! What it reads is checked: positions and offsets stay in `u32`, every
//! length stays inside the bytes. Bytes that break a rule are
//! `error.Corrupt`.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const bitpack = @import("../encoding/bitpack.zig");
const varint = @import("../encoding/varint.zig");

const Allocator = std.mem.Allocator;
const group_len = bitpack.block_len;

pub const Error = error{Corrupt};

/// A token of a term in a document: its position, and its bytes in the
/// field's text when the field keeps offsets.
pub const Token = struct {
    position: u32,
    start: u32 = 0,
    end: u32 = 0,
};

/// Appends the positions of one term to `out`. `docs` holds, for each
/// posting in order, its tokens, rising by position and by start;
/// `offsets` says whether starts and ends are kept. A posting block is
/// 128 documents, as the postings group them.
pub fn write(gpa: Allocator, out: *std.ArrayList(u8), docs: []const []const Token, offsets: bool) Allocator.Error!void {
    aegis.assert.invariant(docs.len > 0, "a term has at least one posting");
    var chunks: std.ArrayList(u8) = .empty;
    defer chunks.deinit(gpa);
    var values: Values = .{ .offsets = offsets };
    var at: usize = 0;
    while (at < docs.len) {
        const block = docs[at..@min(at + bitpack.block_len, docs.len)];
        const start = chunks.items.len;
        values.n = 0;
        for (block) |tokens| {
            var position: u32 = 0;
            var from: u32 = 0;
            for (tokens) |t| {
                aegis.assert.invariant(t.position >= position and (!offsets or (t.start >= from and t.end > t.start)), "a document's tokens rise, each at least a byte long");
                values.add(t.position - position, if (offsets) t.start - from else 0, if (offsets) t.end - t.start else 0);
                position = t.position;
                from = t.start;
                if (values.n == group_len) try values.pack(gpa, &chunks);
            }
        }
        try values.tail(gpa, &chunks);
        try varint.append(gpa, out, chunks.items.len - start);
        at += block.len;
    }
    try out.appendSlice(gpa, chunks.items);
}

/// A group of tokens' values being gathered.
const Values = struct {
    offsets: bool,
    n: usize = 0,
    gaps: [group_len]u32 = undefined,
    starts: [group_len]u32 = undefined,
    lengths: [group_len]u32 = undefined,

    fn add(v: *Values, gap: u32, start: u32, length: u32) void {
        v.gaps[v.n] = gap;
        v.starts[v.n] = start;
        v.lengths[v.n] = length;
        v.n += 1;
    }

    fn pack(v: *Values, gpa: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
        try packStream(gpa, out, &v.gaps);
        if (v.offsets) {
            try packStream(gpa, out, &v.starts);
            try packStream(gpa, out, &v.lengths);
        }
        v.n = 0;
    }

    fn tail(v: *Values, gpa: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
        for (0..v.n) |i| {
            try varint.append(gpa, out, v.gaps[i]);
            if (v.offsets) {
                try varint.append(gpa, out, v.starts[i]);
                try varint.append(gpa, out, v.lengths[i]);
            }
        }
        v.n = 0;
    }
};

fn packStream(gpa: Allocator, out: *std.ArrayList(u8), values: *const [group_len]u32) Allocator.Error!void {
    var packed_bytes: [bitpack.max_block_bytes]u8 = undefined;
    const bits = bitpack.bitsFor(values);
    bitpack.pack(values, bits, &packed_bytes);
    try out.append(gpa, bits);
    try out.appendSlice(gpa, packed_bytes[0..bitpack.packedBytes(bits)]);
}

/// A term's positions read from the bytes at its address, forward only, in
/// step with its postings.
pub const Reader = struct {
    bytes: []const u8,
    offsets: bool,
    blocks: u32,
    /// The chunks entered so far, where the next chunk's length is read and
    /// where it starts, and the chunk the reader stands in.
    entered: u32 = 0,
    length_at: usize = 0,
    next_chunk: usize,
    chunk: []const u8 = &.{},
    chunk_at: usize = 0,
    /// The tokens of the chunk not yet read; a full group holds 128.
    left: u64 = 0,
    /// The group being read: its values, how many and the next.
    group: Values,
    group_count: usize = 0,
    group_index: usize = 0,
    /// The document being read: its tokens left, and the last position and
    /// start given.
    doc_left: u32 = 0,
    position: u32 = 0,
    start: u32 = 0,

    /// The positions at the start of `bytes` (which may run past them) of a
    /// term whose postings have `df` documents, so `ceil(df / 128)` chunks.
    pub fn parse(bytes: []const u8, df: u32, offsets: bool) Error!Reader {
        const blocks: u32 = @intCast((@as(u64, df) + bitpack.block_len - 1) / bitpack.block_len);
        var at: usize = 0;
        var total: usize = 0;
        for (0..blocks) |_| total = std.math.add(usize, total, try varint.readAtMost(bytes, &at, bytes.len)) catch return error.Corrupt;
        if (total > bytes.len - at) return error.Corrupt;
        return .{ .bytes = bytes, .offsets = offsets, .blocks = blocks, .next_chunk = at, .group = .{ .offsets = offsets } };
    }

    /// Moves to postings block `block`'s chunk, forward only, whose
    /// documents hold `tokens` tokens together: the sum of their
    /// frequencies.
    pub fn enter(r: *Reader, block: u32, tokens: u64) Error!void {
        aegis.assert.invariant(block >= r.entered and block < r.blocks, "chunks are entered forward, each of a postings block");
        // The lengths were read and their total checked against the bytes
        // when parsed; read again, they are the same.
        while (r.entered <= block) {
            const length = try varint.readAtMost(r.bytes, &r.length_at, r.bytes.len - r.next_chunk);
            r.chunk = r.bytes[r.next_chunk..][0..length];
            r.next_chunk += length;
            r.entered += 1;
        }
        r.chunk_at = 0;
        r.left = tokens;
        r.group_count = 0;
        r.group_index = 0;
        r.doc_left = 0;
    }

    /// Starts the next document of the chunk, which holds `freq` tokens,
    /// past what is left of the one before.
    pub fn document(r: *Reader, freq: u32) Error!void {
        try r.skip();
        r.doc_left = freq;
        r.position = 0;
        r.start = 0;
    }

    /// Passes the document's tokens left without giving them. A whole
    /// group the document holds is passed without unpacking it.
    pub fn skip(r: *Reader) Error!void {
        while (r.doc_left > 0) {
            if (r.group_index == r.group_count and r.left >= group_len and r.doc_left >= group_len) {
                try r.passGroup();
                r.doc_left -= group_len;
                continue;
            }
            _ = try r.next();
        }
    }

    /// The document's next token, or null past its last.
    pub fn next(r: *Reader) Error!?Token {
        if (r.doc_left == 0) return null;
        if (r.group_index == r.group_count) try r.load();
        const i = r.group_index;
        r.group_index += 1;
        r.doc_left -= 1;
        r.position = std.math.add(u32, r.position, r.group.gaps[i]) catch return error.Corrupt;
        if (!r.offsets) return .{ .position = r.position };
        r.start = std.math.add(u32, r.start, r.group.starts[i]) catch return error.Corrupt;
        const end = std.math.add(u32, r.start, r.group.lengths[i]) catch return error.Corrupt;
        if (end == r.start) return error.Corrupt;
        return .{ .position = r.position, .start = r.start, .end = end };
    }

    /// Reads the chunk's next group.
    fn load(r: *Reader) Error!void {
        if (r.left == 0) return error.Corrupt;
        if (r.left >= group_len) {
            try unpack(r.chunk, &r.chunk_at, &r.group.gaps);
            if (r.offsets) {
                try unpack(r.chunk, &r.chunk_at, &r.group.starts);
                try unpack(r.chunk, &r.chunk_at, &r.group.lengths);
            }
            r.group_count = group_len;
        } else {
            const n: usize = @intCast(r.left);
            for (0..n) |i| {
                r.group.gaps[i] = @intCast(try varint.readAtMost(r.chunk, &r.chunk_at, std.math.maxInt(u32)));
                if (r.offsets) {
                    r.group.starts[i] = @intCast(try varint.readAtMost(r.chunk, &r.chunk_at, std.math.maxInt(u32)));
                    r.group.lengths[i] = @intCast(try varint.readAtMost(r.chunk, &r.chunk_at, std.math.maxInt(u32)));
                }
            }
            r.group_count = n;
        }
        r.left -= r.group_count;
        r.group_index = 0;
        try r.endsWhole();
    }

    fn passGroup(r: *Reader) Error!void {
        try passStream(r.chunk, &r.chunk_at);
        if (r.offsets) {
            try passStream(r.chunk, &r.chunk_at);
            try passStream(r.chunk, &r.chunk_at);
        }
        r.left -= group_len;
        try r.endsWhole();
    }

    /// A chunk read to its last token is read to its last byte.
    fn endsWhole(r: *const Reader) Error!void {
        if (r.left == 0 and r.chunk_at != r.chunk.len) return error.Corrupt;
    }
};

fn unpack(bytes: []const u8, at: *usize, out: *[group_len]u32) Error!void {
    const n = try streamBytes(bytes, at);
    bitpack.unpack(bytes[at.*..][0..n.bytes], n.bits, out);
    at.* += n.bytes;
}

fn passStream(bytes: []const u8, at: *usize) Error!void {
    // `streamBytes` moves `at` past the bits byte first, so its result is
    // added after it returns.
    const stream = try streamBytes(bytes, at);
    at.* += stream.bytes;
}

fn streamBytes(bytes: []const u8, at: *usize) Error!struct { bits: bitpack.Bits, bytes: usize } {
    if (at.* >= bytes.len) return error.Corrupt;
    const bits = bytes[at.*];
    at.* += 1;
    if (bits > bitpack.max_bits) return error.Corrupt;
    const n = bitpack.packedBytes(@intCast(bits));
    if (n > bytes.len - at.*) return error.Corrupt;
    return .{ .bits = @intCast(bits), .bytes = n };
}
