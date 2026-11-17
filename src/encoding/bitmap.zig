//! A set of a segment's doc ids, one bit each: the documents a deletion
//! generation removes. Written as the bits in 64-bit words, little endian,
//! doc `i` at bit `i % 64` of word `i / 64`; the bits past the segment's last
//! doc are zero, so a segment's set has one spelling.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;

/// Bytes that are not the set of a segment of that many docs.
pub const Error = error{Corrupt};

/// The bytes the set of a segment of `docs` docs takes.
pub fn bytesFor(docs: u32) usize {
    return wordsFor(docs) * 8;
}

fn wordsFor(docs: u32) usize {
    return (@as(usize, docs) + 63) / 64;
}

/// A set being written: every doc out until it is added.
pub const Bitmap = struct {
    docs: u32,
    words: []u64,

    pub fn init(gpa: Allocator, docs: u32) Allocator.Error!Bitmap {
        const words = try gpa.alloc(u64, wordsFor(docs));
        @memset(words, 0);
        return .{ .docs = docs, .words = words };
    }

    pub fn deinit(b: *Bitmap, gpa: Allocator) void {
        gpa.free(b.words);
        b.* = undefined;
    }

    /// The set `view` holds, to add to: a new generation starts from the one
    /// before it.
    pub fn fromView(gpa: Allocator, view: View) Allocator.Error!Bitmap {
        const b = try init(gpa, view.docs);
        for (b.words, 0..) |*word, i| word.* = view.word(i);
        return b;
    }

    pub fn add(b: *Bitmap, doc: u32) void {
        aegis.assert.invariant(doc < b.docs, "a doc id is one of its segment's");
        b.words[doc / 64] |= @as(u64, 1) << @intCast(doc % 64);
    }

    pub fn has(b: Bitmap, doc: u32) bool {
        aegis.assert.invariant(doc < b.docs, "a doc id is one of its segment's");
        return b.words[doc / 64] & (@as(u64, 1) << @intCast(doc % 64)) != 0;
    }

    pub fn count(b: Bitmap) u32 {
        var n: u32 = 0;
        for (b.words) |word| n += @popCount(word);
        return n;
    }

    /// The set's bytes into `out`, which is `bytesFor(docs)` long.
    pub fn write(b: Bitmap, out: []u8) void {
        aegis.assert.invariant(out.len == bytesFor(b.docs), "a set's bytes are its words");
        for (b.words, 0..) |word, i| std.mem.writeInt(u64, out[i * 8 ..][0..8], word, .little);
    }
};

/// A set read from bytes, borrowing them.
pub const View = struct {
    docs: u32,
    bytes: []const u8,

    /// The set of a segment of `docs` docs that `bytes` hold: exactly its
    /// words, no bit set past its last doc.
    pub fn parse(bytes: []const u8, docs: u32) Error!View {
        if (bytes.len != bytesFor(docs)) return error.Corrupt;
        const view: View = .{ .docs = docs, .bytes = bytes };
        const tail = docs % 64;
        if (tail != 0 and view.word(wordsFor(docs) - 1) >> @intCast(tail) != 0) return error.Corrupt;
        return view;
    }

    fn word(v: View, i: usize) u64 {
        return std.mem.readInt(u64, v.bytes[i * 8 ..][0..8], .little);
    }

    pub fn has(v: View, doc: u32) bool {
        aegis.assert.invariant(doc < v.docs, "a doc id is one of its segment's");
        return v.word(doc / 64) & (@as(u64, 1) << @intCast(doc % 64)) != 0;
    }

    pub fn count(v: View) u32 {
        var n: u32 = 0;
        for (0..wordsFor(v.docs)) |i| n += @popCount(v.word(i));
        return n;
    }
};
