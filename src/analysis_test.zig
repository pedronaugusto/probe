//! A text field's tokens: words by UAX #29 folded by NFKC_Casefold and cut
//! on a code point, held to xenoglyph's own segmentation and normal form;
//! and an identifier's parts, cut where the case turns, at their positions.
const std = @import("std");
const shakedown = @import("shakedown");
const xenoglyph = @import("xenoglyph");
const analysis = @import("analysis.zig");

const testing = std.testing;
const gen = shakedown.gen;
const Pipeline = analysis.Pipeline;

const Expected = struct { term: []const u8, position: u32, start: u32, end: u32 };

fn expectTokens(comptime kind: @import("Schema.zig").Analysis, text: []const u8, term_bytes: usize, want: []const Expected) !void {
    var buffer: [64]u8 = undefined;
    var tokens: Pipeline.Of(kind) = .init(text, buffer[0..term_bytes]);
    for (want) |w| {
        const t = tokens.next() orelse {
            std.debug.print("missing \"{s}\"\n", .{w.term});
            return error.TestExpectedEqual;
        };
        try testing.expectEqualStrings(w.term, t.term);
        try testing.expectEqual(w.position, t.position);
        try testing.expectEqual(w.start, t.start);
        try testing.expectEqual(w.end, t.end);
    }
    try testing.expectEqual(null, tokens.next());
}

test "words are UAX #29's word-like segments, folded by NFKC_Casefold" {
    try expectTokens(.words, "Hello, W\u{f6}rld! 42 \u{fb01}le Stra\u{df}e \u{ff21}\u{ff22}", 64, &.{
        .{ .term = "hello", .position = 0, .start = 0, .end = 5 },
        .{ .term = "w\u{f6}rld", .position = 1, .start = 7, .end = 13 },
        .{ .term = "42", .position = 2, .start = 15, .end = 17 },
        .{ .term = "file", .position = 3, .start = 18, .end = 23 },
        .{ .term = "strasse", .position = 4, .start = 24, .end = 31 },
        .{ .term = "ab", .position = 5, .start = 32, .end = 38 },
    });
    // Ill-formed UTF-8 is U+FFFD, which is no word and ends the one before.
    try expectTokens(.words, "ab\xffcd", 64, &.{
        .{ .term = "ab", .position = 0, .start = 0, .end = 2 },
        .{ .term = "cd", .position = 1, .start = 3, .end = 5 },
    });
    try expectTokens(.words, "", 64, &.{});
    try expectTokens(.words, " ... !", 64, &.{});
}

test "a term longer than the buffer is cut on a code point" {
    try expectTokens(.words, "abcdefg", 4, &.{.{ .term = "abcd", .position = 0, .start = 0, .end = 7 }});
    try expectTokens(.words, "\u{e9}\u{e9}\u{e9}\u{e9}", 5, &.{.{ .term = "\u{e9}\u{e9}", .position = 0, .start = 0, .end = 8 }});
    try expectTokens(.words, "Stra\u{df}e", 6, &.{.{ .term = "strass", .position = 0, .start = 0, .end = 7 }});
    try expectTokens(.words, "\u{e9}", 1, &.{});
}

test "an identifier is also its parts, at consecutive positions from its own" {
    try expectTokens(.words_and_identifiers, "parseSpan max_record_bytes HTTPServer std.mem.eql utf8Decoder _x plain", 64, &.{
        .{ .term = "parsespan", .position = 0, .start = 0, .end = 9 },
        .{ .term = "parse", .position = 0, .start = 0, .end = 5 },
        .{ .term = "span", .position = 1, .start = 5, .end = 9 },
        .{ .term = "max_record_bytes", .position = 2, .start = 10, .end = 26 },
        .{ .term = "max", .position = 2, .start = 10, .end = 13 },
        .{ .term = "record", .position = 3, .start = 14, .end = 20 },
        .{ .term = "bytes", .position = 4, .start = 21, .end = 26 },
        .{ .term = "httpserver", .position = 5, .start = 27, .end = 37 },
        .{ .term = "http", .position = 5, .start = 27, .end = 31 },
        .{ .term = "server", .position = 6, .start = 31, .end = 37 },
        .{ .term = "std.mem.eql", .position = 7, .start = 38, .end = 49 },
        .{ .term = "std", .position = 7, .start = 38, .end = 41 },
        .{ .term = "mem", .position = 8, .start = 42, .end = 45 },
        .{ .term = "eql", .position = 9, .start = 46, .end = 49 },
        .{ .term = "utf8decoder", .position = 10, .start = 50, .end = 61 },
        .{ .term = "utf8", .position = 10, .start = 50, .end = 54 },
        .{ .term = "decoder", .position = 11, .start = 54, .end = 61 },
        .{ .term = "_x", .position = 12, .start = 62, .end = 64 },
        .{ .term = "x", .position = 12, .start = 63, .end = 64 },
        .{ .term = "plain", .position = 13, .start = 65, .end = 70 },
    });
    // A word of one part is not repeated; a mark stays with its letter.
    try expectTokens(.words_and_identifiers, "Decoder2 v2beta ABc e\u{301}Toile", 64, &.{
        .{ .term = "decoder2", .position = 0, .start = 0, .end = 8 },
        .{ .term = "v2beta", .position = 1, .start = 9, .end = 15 },
        .{ .term = "abc", .position = 2, .start = 16, .end = 19 },
        .{ .term = "a", .position = 2, .start = 16, .end = 17 },
        .{ .term = "bc", .position = 3, .start = 17, .end = 19 },
        .{ .term = "\u{e9}toile", .position = 4, .start = 20, .end = 28 },
        .{ .term = "\u{e9}", .position = 4, .start = 20, .end = 23 },
        .{ .term = "toile", .position = 5, .start = 23, .end = 28 },
    });
}

/// Pieces of text: letters of each case, digits, connectors, marks, a
/// ligature, full-width forms, an ideograph, space, punctuation, a symbol
/// and ill-formed bytes.
const pieces = [_][]const u8{
    "a",        "Z",        "q",        "R",         "7",        "_",        ".",      "'",
    ":",        " ",        "\n",       "-",         "\u{e9}",   "E\u{301}", "\u{df}", "\u{fb01}",
    "\u{ff21}", "\u{65e5}", "\u{130}",  "\u{3a3}",   "\u{1c5}",  "\u{2160}", "\u{ad}", "\u{1f600}",
    "\xff",     "\xc3",     "\u{2163}", "\u{10400}", "\u{2026}", "\u{a0}",
};

fn textOf(s: *shakedown.Source, buffer: []u8) []const u8 {
    if (gen.intRange(s, u8, 0, 3) == 0) return gen.bytesInto(s, buffer);
    var len: usize = 0;
    for (0..gen.intRange(s, usize, 0, 24)) |_| {
        const piece = pieces[gen.intRange(s, usize, 0, pieces.len - 1)];
        if (len + piece.len > buffer.len) break;
        @memcpy(buffer[len..][0..piece.len], piece);
        len += piece.len;
    }
    return buffer[0..len];
}

/// NFKC_Casefold by xenoglyph's writer, cut to `out.len` bytes on a code
/// point: the longest prefix that ends where a code point does.
fn referenceFold(text: []const u8, out: []u8) ![]const u8 {
    // Room for the largest expansion, eighteen code points from three bytes.
    var out_buffer: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buffer);
    try xenoglyph.normalize.write(.nfkc_casefold, text, &w);
    const folded = w.buffered();
    var len = @min(out.len, folded.len);
    while (len > 0 and len < folded.len and folded[len] & 0xc0 == 0x80) len -= 1;
    @memcpy(out[0..len], folded[0..len]);
    return out[0..len];
}

fn wordsAgainstXenoglyph(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var text_buffer: [96]u8 = undefined;
    const text = textOf(s, &text_buffer);
    var term_buffer: [32]u8 = undefined;
    const term_bytes = gen.intRange(s, usize, 1, term_buffer.len);
    var tokens: Pipeline.Of(.words) = .init(text, term_buffer[0..term_bytes]);
    var segments = xenoglyph.words(text);
    var position: u32 = 0;
    while (segments.nextSpan()) |span| {
        const segment = span.of(text);
        if (!xenoglyph.word.isWordLike(segment)) continue;
        defer position += 1;
        var want_buffer: [32]u8 = undefined;
        const want = try referenceFold(segment, want_buffer[0..term_bytes]);
        if (want.len == 0) continue;
        const t = tokens.next() orelse return error.TestExpectedEqual;
        try testing.expectEqualStrings(want, t.term);
        try testing.expectEqual(position, t.position);
        try testing.expectEqual(span.start.raw(), t.start);
        try testing.expectEqual(span.end.raw(), t.end);
    }
    try testing.expectEqual(null, tokens.next());
}

test "words and their terms are xenoglyph's word-like segments and NFKC_Casefold, cut on a code point" {
    try shakedown.check(testing.allocator, {}, wordsAgainstXenoglyph, .{ .seed = 0x776f7264, .cases = 3000 });
}

const Kind = enum { part, between };

/// The rule's classes: letters, digits and marks are in parts.
fn kindOf(cp: u21) Kind {
    const gc = xenoglyph.generalCategory(cp);
    return if (gc.isLetter() or gc.isNumber() or gc.isMark()) .part else .between;
}

fn identifiersAgainstWords(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var text_buffer: [96]u8 = undefined;
    const text = textOf(s, &text_buffer);
    var term_buffer: [32]u8 = undefined;
    const term_bytes = gen.intRange(s, usize, 1, term_buffer.len);
    var whole: Pipeline.Of(.words) = .init(text, term_buffer[0..term_bytes]);
    var with_parts_buffer: [32]u8 = undefined;
    var tokens: Pipeline.Of(.words_and_identifiers) = .init(text, with_parts_buffer[0..term_bytes]);
    var segments = xenoglyph.words(text);
    // The word the tokens are in, and where its parts have reached.
    var word: ?struct { start: usize, end: usize, at: usize } = null;
    var last_position: u32 = 0;
    while (tokens.next()) |t| {
        try testing.expect(t.start < t.end and t.end <= text.len);
        try testing.expect(t.term.len > 0 and t.term.len <= term_bytes);
        try testing.expect(std.unicode.utf8ValidateSlice(t.term));
        try testing.expect(t.position >= last_position);
        last_position = t.position;
        // Every term is its text's fold, cut.
        var want_buffer: [32]u8 = undefined;
        try testing.expectEqualStrings(try referenceFold(text[t.start..t.end], want_buffer[0..term_bytes]), t.term);
        // The word-like segment the token lies in.
        if (word == null or t.start >= word.?.end) {
            while (segments.nextSpan()) |span| {
                if (!xenoglyph.word.isWordLike(span.of(text)) or span.end.raw() <= t.start) continue;
                word = .{ .start = span.start.raw(), .end = span.end.raw(), .at = span.start.raw() };
                break;
            } else return error.TestUnexpectedResult;
        }
        const w = &word.?;
        try testing.expect(t.start >= w.start and t.end <= w.end);
        if (t.start == w.start and t.end == w.end) {
            // The whole word, before its parts, as `.words` gives it.
            try testing.expectEqual(w.start, w.at);
            const next = whole.next() orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings(next.term, t.term);
            try testing.expectEqual(next.start, t.start);
            try testing.expectEqual(next.end, t.end);
        } else {
            // A part, after the one before it.
            try testing.expect(t.start >= w.at);
            w.at = t.end;
        }
    }
    try testing.expectEqual(null, whole.next());
}

test "with identifiers, the words are as without, each followed by its parts in order inside it" {
    try shakedown.check(testing.allocator, {}, identifiersAgainstWords, .{ .seed = 0x6964656e, .cases = 3000 });
}

fn partsCoverTheirClasses(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var buffer: [64]u8 = undefined;
    const word = textOf(s, &buffer);
    var inside: [64]bool = @splat(false);
    var parts: analysis.identifier.Parts = .init(word);
    var n: u32 = 0;
    var last_end: u32 = 0;
    while (parts.next()) |part| {
        try testing.expect(part.start >= last_end and part.start < part.end and part.end <= word.len);
        // Parts that touch meet where the case turns: before an uppercase
        // letter, never before a mark, a digit or a lowercase letter.
        if (n > 0 and part.start == last_end) {
            const gc = xenoglyph.generalCategory(xenoglyph.utf8.decode(word[part.start..]).code_point);
            try testing.expect(gc == .uppercase_letter or gc == .titlecase_letter);
        }
        last_end = part.end;
        @memset(inside[part.start..part.end], true);
        n += 1;
    }
    // A code point is in a part when it is a letter, a digit or a mark.
    var at: usize = 0;
    while (at < word.len) {
        const d = xenoglyph.utf8.decode(word[at..]);
        try testing.expectEqual(kindOf(d.code_point) == .part, inside[at]);
        for (inside[at..][0..d.len]) |b| try testing.expectEqual(inside[at], b);
        at += d.len;
    }
    const counted = analysis.identifier.count(word);
    try testing.expect(counted == n or (counted == 0 and n == 1));
}

test "an identifier's parts hold exactly its letters, digits and marks, in order" {
    try shakedown.check(testing.allocator, {}, partsCoverTheirClasses, .{ .seed = 0x70617274, .cases = 3000 });
}

fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var buffer: [256]u8 = undefined;
    const text = gen.bytesInto(s, &buffer);
    var term_buffer: [16]u8 = undefined;
    var tokens: Pipeline.Of(.words_and_identifiers) = .init(text, &term_buffer);
    var count: usize = 0;
    while (tokens.next()) |t| {
        try testing.expect(t.end <= text.len and std.unicode.utf8ValidateSlice(t.term));
        count += 1;
    }
    // A token is at most two per byte: a word and a part of it.
    try testing.expect(count <= 2 * text.len);
}

test "fuzz: any bytes give tokens within the text, their terms well-formed" {
    try shakedown.check(testing.allocator, {}, anyBytes, .{ .seed = 0x66757a7a, .cases = 3000 });
}
