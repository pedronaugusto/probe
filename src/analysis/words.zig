//! A text's words by UAX #29 (xenoglyph's default word boundaries), each
//! with its byte range: the segments that hold a letter, a digit or a
//! connector. Runs of space, punctuation, symbols and emoji are not words,
//! and neither is an ill-formed UTF-8 sequence, which reads as U+FFFD.
//!
//! And the term a word is indexed as: its NFKC_Casefold, cut to the
//! caller's buffer on a code point boundary.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const xenoglyph = @import("xenoglyph");

/// One word and where it lies in the text, in bytes.
pub const Word = struct {
    bytes: []const u8,
    start: u32,
    end: u32,
};

/// The words of a text, in order.
pub const Words = struct {
    segments: xenoglyph.word.Iterator,

    /// A text of at most `maxInt(u32)` bytes, which `Limits.document_bytes`
    /// keeps every field to.
    pub fn init(text: []const u8) Words {
        aegis.assert.invariant(text.len <= std.math.maxInt(u32), "a field's text is at most 4 GiB, so its offsets are u32");
        return .{ .segments = xenoglyph.word.iterate(text) };
    }

    /// The next word, or null at the end.
    pub fn next(w: *Words) ?Word {
        while (w.segments.nextSpan()) |span| {
            const bytes = span.of(w.segments.bytes);
            if (!xenoglyph.word.isWordLike(bytes)) continue;
            return .{ .bytes = bytes, .start = @intCast(span.start.raw()), .end = @intCast(span.end.raw()) };
        }
        return null;
    }
};

/// `text`'s NFKC_Casefold written into `out`, as far as whole code points
/// fit: a longer term is cut, never split inside a code point. The result
/// may be empty: NFKC_Casefold maps some code points to nothing.
pub fn fold(text: []const u8, out: []u8) []u8 {
    if (ascii(text)) {
        const n = @min(text.len, out.len);
        for (out[0..n], text[0..n]) |*o, c| o.* = std.ascii.toLower(c);
        return out[0..n];
    }
    var folded: xenoglyph.normalize.Iterator(.nfkc_casefold) = .init(text);
    var len: usize = 0;
    while (folded.next()) |cp| {
        const n = std.unicode.utf8CodepointSequenceLength(cp) catch aegis.assert.never("a normal form holds only scalar values");
        if (len + n > out.len) break;
        _ = std.unicode.utf8Encode(cp, out[len..]) catch aegis.assert.never("a normal form holds only scalar values");
        len += n;
    }
    return out[0..len];
}

fn ascii(text: []const u8) bool {
    for (text) |c| if (c >= 0x80) return false;
    return true;
}
