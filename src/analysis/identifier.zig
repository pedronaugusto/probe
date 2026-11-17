//! An identifier's parts, for code and logs: `parseSpan` is `parse` and
//! `span`, `max_record_bytes` is `max`, `record` and `bytes`, `std.mem.eql`
//! is `std`, `mem` and `eql` (UAX #29 keeps each as one word).
//!
//! A part is a run of letters, digits and marks (by General_Category), cut
//! where the case turns: before an uppercase letter that follows a lowercase
//! letter or a digit (`utf8Decoder` is `utf8` and `Decoder`), and before
//! the last of a run of uppercase letters when a lowercase one follows it
//! (`HTTPServer` is `HTTP` and `Server`). Anything else (`_`, `.`, `'`, `:`
//! and every other punctuation mark or symbol) is between parts. A digit
//! after a letter stays in its part, as does a mark after anything.
//!
//! This file is internal. `probe.zig` is the package.
const xenoglyph = @import("xenoglyph");

/// A part's byte range in its word.
pub const Part = struct {
    start: u32,
    end: u32,
};

const Kind = enum { upper, lower, number, mark, between };

fn kindOf(cp: u21) Kind {
    return switch (xenoglyph.generalCategory(cp)) {
        .uppercase_letter, .titlecase_letter => .upper,
        .lowercase_letter, .modifier_letter, .other_letter => .lower,
        .decimal_number, .letter_number, .other_number => .number,
        .nonspacing_mark, .spacing_mark, .enclosing_mark => .mark,
        else => .between,
    };
}

/// The parts of a word, in order.
pub const Parts = struct {
    word: []const u8,
    at: u32 = 0,

    /// A word of at most `maxInt(u32)` bytes.
    pub fn init(word: []const u8) Parts {
        return .{ .word = word };
    }

    /// The next part, or null at the end.
    pub fn next(p: *Parts) ?Part {
        var at: usize = p.at;
        // Past what lies between parts.
        while (at < p.word.len) {
            const d = xenoglyph.utf8.decode(p.word[at..]);
            if (kindOf(d.code_point) != .between) break;
            at += d.len;
        }
        if (at == p.word.len) {
            p.at = @intCast(at);
            return null;
        }
        const start = at;
        const first = xenoglyph.utf8.decode(p.word[at..]);
        var last: Kind = switch (kindOf(first.code_point)) {
            .mark => .lower,
            else => |k| k,
        };
        at += first.len;
        while (at < p.word.len) {
            const d = xenoglyph.utf8.decode(p.word[at..]);
            const kind = kindOf(d.code_point);
            switch (kind) {
                .between => break,
                .mark => {},
                .upper => {
                    if (last == .lower or last == .number) break;
                    if (last == .upper and kindAfter(p.word, at + d.len) == .lower) break;
                },
                .lower, .number => {},
            }
            if (kind != .mark) last = kind;
            at += d.len;
        }
        p.at = @intCast(at);
        return .{ .start = @intCast(start), .end = @intCast(at) };
    }
};

/// The kind of the first code point at or after `at` that is not a mark,
/// or `.between` at the end.
fn kindAfter(word: []const u8, from: usize) Kind {
    var at = from;
    while (at < word.len) {
        const d = xenoglyph.utf8.decode(word[at..]);
        const kind = kindOf(d.code_point);
        if (kind != .mark) return kind;
        at += d.len;
    }
    return .between;
}

/// How many parts `word` is indexed as besides itself: none when its only
/// part is the whole word, every part otherwise (`_x` is also `x`).
pub fn count(word: []const u8) u32 {
    var parts: Parts = .init(word);
    const first = parts.next() orelse return 0;
    var n: u32 = 1;
    while (parts.next()) |_| n += 1;
    if (n == 1 and first.start == 0 and first.end == word.len) return 0;
    return n;
}
