//! One term's postings in a segment: the documents it occurs in, rising,
//! each with how often, in blocks of 128 with a skip entry per block.
//!
//! The bytes, at the term's address in the postings file:
//!
//!     df                       the documents, a varint, at least one
//!     skip entry per block     ceil(df / 128) of them:
//!         last                 the block's last doc, less the block
//!                              before's (the first block's whole)
//!         bytes                the block's length
//!         impacts              their count (1 to 8), then each
//!                              (freq less one, length), freq rising
//!     block per block          a full block: its doc gaps (`bitpack.gaps`)
//!                              and its frequencies less one, each a bits
//!                              byte and its packed bytes; the last block,
//!                              when short, as varints: each doc's gap and
//!                              frequency less one
//!
//! A block's impacts are its competitive (frequency, length) pairs: those no
//! other pair of the block beats on both, a higher frequency at no greater
//! length or a shorter length at no lower frequency (Lucene's impacts). Past
//! eight, the block keeps one pair, its highest frequency and its shortest
//! length, which bounds every document of it in fixed space. A query bounds
//! a block's score from them with the snapshot's statistics.
//!
//! A reader walks forward only, skips a block by its skip entry without
//! decoding it, and checks what it reads: doc ids rise and stay inside the
//! segment, each block ends at the doc its skip entry says, and every
//! length the entries give stays inside the bytes. Bytes that break a rule
//! are `error.Corrupt`.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const bitpack = @import("../encoding/bitpack.zig");
const varint = @import("../encoding/varint.zig");

const Allocator = std.mem.Allocator;
const block_len = bitpack.block_len;

pub const Error = error{Corrupt};

/// A document of the term's, and how often the term occurs in it.
pub const Posting = struct {
    doc: u32,
    freq: u32,
};

/// A frequency and a document length that bound a block's documents.
pub const Impact = struct {
    freq: u32,
    length: u32,
};

/// The most impacts a block keeps.
pub const max_impacts = 8;

/// Appends the postings of one term to `out`. `postings` rise strictly by
/// doc, at least one, each freq at least one; `lengths` holds each doc's
/// length in the field, or is null for a field whose every document is one
/// term long (a keyword).
pub fn write(gpa: Allocator, out: *std.ArrayList(u8), postings: []const Posting, lengths: ?[]const u32) Allocator.Error!void {
    aegis.assert.invariant(postings.len > 0, "a term has at least one posting");
    var bodies: std.ArrayList(u8) = .empty;
    defer bodies.deinit(gpa);
    try varint.append(gpa, out, postings.len);
    var before: ?u32 = null;
    var at: usize = 0;
    while (at < postings.len) {
        const block = postings[at..@min(at + block_len, postings.len)];
        const start = bodies.items.len;
        if (block.len == block_len) {
            try packBlock(gpa, &bodies, block, before);
        } else {
            var prev = before;
            for (block) |p| {
                try varint.append(gpa, &bodies, if (prev) |b| p.doc - b - 1 else p.doc);
                try varint.append(gpa, &bodies, p.freq - 1);
                prev = p.doc;
            }
        }
        const last = block[block.len - 1].doc;
        try varint.append(gpa, out, if (before) |b| last - b else last);
        try varint.append(gpa, out, bodies.items.len - start);
        var impacts: [max_impacts]Impact = undefined;
        const kept = competitive(block, lengths, &impacts);
        try varint.append(gpa, out, kept.len);
        for (kept) |i| {
            try varint.append(gpa, out, i.freq - 1);
            try varint.append(gpa, out, i.length);
        }
        before = last;
        at += block.len;
    }
    try out.appendSlice(gpa, bodies.items);
}

fn packBlock(gpa: Allocator, out: *std.ArrayList(u8), block: []const Posting, before: ?u32) Allocator.Error!void {
    var docs: [block_len]u32 = undefined;
    var values: [block_len]u32 = undefined;
    var packed_bytes: [bitpack.max_block_bytes]u8 = undefined;
    for (block, &docs) |p, *d| d.* = p.doc;
    bitpack.gaps(&docs, before, &values);
    var bits = bitpack.bitsFor(&values);
    bitpack.pack(&values, bits, &packed_bytes);
    try out.append(gpa, bits);
    try out.appendSlice(gpa, packed_bytes[0..bitpack.packedBytes(bits)]);
    for (block, &values) |p, *v| v.* = p.freq - 1;
    bits = bitpack.bitsFor(&values);
    bitpack.pack(&values, bits, &packed_bytes);
    try out.append(gpa, bits);
    try out.appendSlice(gpa, packed_bytes[0..bitpack.packedBytes(bits)]);
}

/// The block's competitive (frequency, length) pairs in `out`, frequency
/// rising, or past `max_impacts` the one pair of its highest frequency and
/// shortest length.
fn competitive(block: []const Posting, lengths: ?[]const u32, out: *[max_impacts]Impact) []const Impact {
    var pairs: [block_len]Impact = undefined;
    for (block, pairs[0..block.len]) |p, *pair| pair.* = .{ .freq = p.freq, .length = if (lengths) |l| l[p.doc] else 1 };
    const all = pairs[0..block.len];
    // Highest frequency first, shortest first among equals: a pair is
    // competitive when it is shorter than every pair before it.
    std.mem.sort(Impact, all, {}, struct {
        fn before(_: void, a: Impact, b: Impact) bool {
            return a.freq > b.freq or (a.freq == b.freq and a.length < b.length);
        }
    }.before);
    // Above every length, so the first pair, of the highest frequency, is
    // kept whatever its length.
    var shortest: u64 = std.math.maxInt(u64);
    var kept: usize = 0;
    for (all) |pair| {
        if (pair.length >= shortest) continue;
        shortest = pair.length;
        if (kept < max_impacts) out[kept] = pair;
        kept += 1;
    }
    if (kept > max_impacts) {
        out[0] = .{ .freq = all[0].freq, .length = @intCast(shortest) };
        return out[0..1];
    }
    std.mem.reverse(Impact, out[0..kept]);
    return out[0..kept];
}

/// A term's postings read from the bytes at its address, forward only.
pub const Reader = struct {
    bytes: []const u8,
    /// The segment's documents: every doc id is below.
    docs: u32,
    df: u32,
    blocks: u32,
    /// The blocks entered so far; the reader stands in the last of them.
    entered: u32 = 0,
    /// Where the next skip entry starts, and the body of the block the
    /// reader stands in (the first block's before it enters one).
    skip_at: usize,
    body_at: usize,
    /// The skip entry of the block the reader stands in, and the last doc
    /// of the block before it.
    last: u32 = 0,
    before: ?u32 = null,
    body_bytes: usize = 0,
    impact_buffer: [max_impacts]Impact = undefined,
    impact_count: u8 = 0,
    /// The block's postings once decoded, and the next one to give.
    decoded: bool = false,
    doc_buffer: [block_len]u32 = undefined,
    freq_buffer: [block_len]u32 = undefined,
    count: u8 = 0,
    index: u8 = 0,

    /// The postings at the start of `bytes` (which may run past them) in a
    /// segment of `docs` documents. Every skip entry is read and checked
    /// here, and the bodies' lengths against the bytes; each block is
    /// checked as it is decoded.
    pub fn parse(bytes: []const u8, docs: u32) Error!Reader {
        var at: usize = 0;
        const df: u32 = @intCast(try varint.readAtMost(bytes, &at, docs));
        if (df == 0) return error.Corrupt;
        const blocks: u32 = @intCast((@as(u64, df) + block_len - 1) / block_len);
        const skip_at = at;
        var body_bytes: usize = 0;
        var last: ?u32 = null;
        for (0..blocks) |_| {
            const entry = try readEntry(bytes, &at, last, docs);
            last = entry.last;
            body_bytes = std.math.add(usize, body_bytes, entry.bytes) catch return error.Corrupt;
        }
        if (body_bytes > bytes.len - at) return error.Corrupt;
        return .{ .bytes = bytes, .docs = docs, .df = df, .blocks = blocks, .skip_at = skip_at, .body_at = at };
    }

    const Entry = struct { last: u32, bytes: usize, impacts: [max_impacts]Impact, count: u8 };

    fn readEntry(bytes: []const u8, at: *usize, before: ?u32, docs: u32) Error!Entry {
        const step = try varint.readAtMost(bytes, at, docs);
        const last = if (before) |b| @as(u64, b) + step else step;
        if ((before != null and step == 0) or last >= docs) return error.Corrupt;
        var e: Entry = .{ .last = @intCast(last), .bytes = try varint.readAtMost(bytes, at, bytes.len), .impacts = undefined, .count = 0 };
        const count = try varint.readAtMost(bytes, at, max_impacts);
        if (count == 0) return error.Corrupt;
        for (e.impacts[0..count]) |*i| {
            i.freq = @intCast(1 + try varint.readAtMost(bytes, at, std.math.maxInt(u32) - 1));
            i.length = @intCast(try varint.readAtMost(bytes, at, std.math.maxInt(u32)));
        }
        e.count = @intCast(count);
        return e;
    }

    /// The number of documents the term occurs in.
    pub fn docFreq(r: *const Reader) u32 {
        return r.df;
    }

    /// The next posting, or null past the last.
    pub fn next(r: *Reader) Error!?Posting {
        while (true) {
            if (r.decoded and r.index < r.count) {
                defer r.index += 1;
                return .{ .doc = r.doc_buffer[r.index], .freq = r.freq_buffer[r.index] };
            }
            if (!try r.nextBlock()) return null;
            try r.decode();
        }
    }

    /// The first posting at or past `target` from where the reader stands,
    /// or null when none is. A block whose last doc is below `target` is
    /// passed by its skip entry, never decoded.
    pub fn advance(r: *Reader, target: u32) Error!?Posting {
        while (r.entered == 0 or r.last < target) {
            if (!try r.nextBlock()) return null;
        }
        if (!r.decoded) try r.decode();
        while (try r.next()) |p| if (p.doc >= target) return p;
        return null;
    }

    /// The impacts of the block the reader stands in: every posting of it
    /// has a frequency at most and a length at least one of theirs.
    pub fn impacts(r: *const Reader) []const Impact {
        return r.impact_buffer[0..r.impact_count];
    }

    /// The last doc of the block the reader stands in.
    pub fn blockLast(r: *const Reader) u32 {
        return r.last;
    }

    /// Enters the next block by its skip entry; false past the last.
    fn nextBlock(r: *Reader) Error!bool {
        if (r.entered == r.blocks) return false;
        if (r.entered > 0) {
            r.before = r.last;
            r.body_at += r.body_bytes;
        }
        const e = try readEntry(r.bytes, &r.skip_at, r.before, r.docs);
        r.last = e.last;
        r.body_bytes = e.bytes;
        r.impact_buffer = e.impacts;
        r.impact_count = e.count;
        r.decoded = false;
        r.count = 0;
        r.index = 0;
        r.entered += 1;
        return true;
    }

    fn decode(r: *Reader) Error!void {
        const body = r.bytes[r.body_at..][0..r.body_bytes];
        const full = r.entered < r.blocks or r.df % block_len == 0;
        const count: usize = if (full) block_len else r.df % block_len;
        var at: usize = 0;
        if (full) {
            var values: [block_len]u32 = undefined;
            try unpackInto(body, &at, &values);
            bitpack.ungap(&values, r.before, &r.doc_buffer) catch return error.Corrupt;
            try unpackInto(body, &at, &r.freq_buffer);
            for (&r.freq_buffer) |*f| f.* = std.math.add(u32, f.*, 1) catch return error.Corrupt;
        } else {
            var prev = r.before;
            for (r.doc_buffer[0..count], r.freq_buffer[0..count]) |*d, *f| {
                const gap = try varint.readAtMost(body, &at, r.docs);
                const doc = if (prev) |b| @as(u64, b) + gap + 1 else gap;
                if (doc >= r.docs) return error.Corrupt;
                d.* = @intCast(doc);
                f.* = @intCast(1 + try varint.readAtMost(body, &at, std.math.maxInt(u32) - 1));
                prev = d.*;
            }
        }
        // The block is exactly its bytes and ends where its skip entry says;
        // gaps keep its docs rising, so all lie below the last.
        if (at != body.len or r.doc_buffer[count - 1] != r.last) return error.Corrupt;
        r.count = @intCast(count);
        r.index = 0;
        r.decoded = true;
    }
};

fn unpackInto(body: []const u8, at: *usize, out: *[block_len]u32) Error!void {
    if (at.* >= body.len) return error.Corrupt;
    const bits = body[at.*];
    at.* += 1;
    if (bits > bitpack.max_bits) return error.Corrupt;
    const n = bitpack.packedBytes(@intCast(bits));
    if (n > body.len - at.*) return error.Corrupt;
    bitpack.unpack(body[at.*..][0..n], @intCast(bits), out);
    at.* += n;
}
