//! A text field's analysis: its stages, chosen by the field's `Analysis` and
//! composed at compile time, give the field's tokens in order.
//!
//! `.words`: each word (`words.zig`) is one token, its NFKC_Casefold.
//!
//! `.words_and_identifiers`: as `.words`, and a word with parts
//! (`identifier.zig`) is also each part. The parts take consecutive
//! positions from the word's own, which the whole word shares with its
//! first part, so a phrase of parts (`parse span`) finds the identifier
//! (`parseSpan`), and the next word's position follows the last part's.
//! This is Lucene's shape for an original kept beside its parts, with no
//! token graph: a query's text goes through the same analysis, so its
//! phrases meet the field's through the parts.
//!
//! A term is cut to the caller's buffer, never inside a code point; a word
//! whose fold is empty gives no token but keeps its position.
//!
//! This file is internal. `probe.zig` is the package.
const Schema = @import("../Schema.zig");
const words = @import("words.zig");
const identifier = @import("identifier.zig");

/// One token: a term, its position among the field's tokens, and the byte
/// range of the text it came from.
pub const Token = struct {
    /// Valid until the next call to `next`.
    term: []const u8,
    position: u32,
    start: u32,
    end: u32,
};

/// The tokens of a text under `analysis`.
pub fn Of(comptime analysis: Schema.Analysis) type {
    const identifiers = analysis == .words_and_identifiers;
    return struct {
        const Self = @This();

        words: words.Words,
        /// Where each term is folded and cut; its length is the longest term.
        term: []u8,
        /// The position the next word takes.
        position: u32 = 0,
        /// The word whose parts are being given, the parts left and the
        /// position the next part takes.
        parts: if (identifiers) ?Within else void = if (identifiers) null else {},

        const Within = struct {
            word: words.Word,
            parts: identifier.Parts,
            position: u32,
        };

        /// The tokens of `text`, each term cut to `term.len` bytes
        /// (`Limits.term_bytes`).
        pub fn init(text: []const u8, term: []u8) Self {
            return .{ .words = .init(text), .term = term };
        }

        /// The next token, or null at the end.
        pub fn next(p: *Self) ?Token {
            while (true) {
                if (identifiers) if (p.parts) |*within| {
                    if (within.parts.next()) |part| {
                        const position = within.position;
                        within.position += 1;
                        const term = words.fold(within.word.bytes[part.start..part.end], p.term);
                        if (term.len == 0) continue;
                        return .{ .term = term, .position = position, .start = within.word.start + part.start, .end = within.word.start + part.end };
                    }
                    p.parts = null;
                };
                const word = p.words.next() orelse return null;
                const position = p.position;
                var taken: u32 = 1;
                if (identifiers) {
                    const parts = identifier.count(word.bytes);
                    if (parts > 0) {
                        p.parts = .{ .word = word, .parts = .init(word.bytes), .position = position };
                        taken = parts;
                    }
                }
                p.position += taken;
                const term = words.fold(word.bytes, p.term);
                if (term.len == 0) continue;
                return .{ .term = term, .position = position, .start = word.start, .end = word.end };
            }
        }
    };
}
