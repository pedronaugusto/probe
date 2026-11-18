//! A regex term query's pattern, made to read a text field's terms as the
//! field folds them, and compiled.
//!
//! A text field's terms are their NFKC_Casefold (`words.fold`). spectra's
//! case-insensitive mode matches by simple case-fold orbits, which agree
//! with NFKC_Casefold where a letter folds to one letter (`É` and `é`; `Σ`,
//! `σ` and `ς`; `Ж` and `ж`) and not where it folds to several or by a
//! compatibility mapping: `ß` folds to `ss`, `ﬁ` to `fi`, a fullwidth `Ａ`
//! to `a`. So the pattern's literal characters are folded as the field
//! folds its text, each written as the regex of what it folds to, and the
//! pattern is compiled case-insensitive on top, for what a literal fold does
//! not reach: classes, escapes and the ranges in them, where simple folding
//! is what a regex can say. Lucene folds a multi-term query through its
//! analyzer's normalization the same way.
//!
//! A keyword field's terms are its bytes as they are, and so is its pattern.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const spectra = @import("spectra");
const xenoglyph = @import("xenoglyph");
const words = @import("../analysis/words.zig");

const Allocator = std.mem.Allocator;

/// How a pattern of a text field (`fold`) or a keyword field compiles.
pub fn options(fold: bool) spectra.Regex.Options {
    return .{ .syntax = .{ .case_insensitive = fold } };
}

/// `pattern` as a regex term query reads it, on `arena`: folded for a text
/// field (`fold`), as it is for a keyword field. `error.Invalid` where it
/// does not compile, or holds a lookaround spectra could not run on a term
/// of `longest` bytes.
pub fn prepare(arena: Allocator, pattern: []const u8, fold: bool, longest: usize) error{ Invalid, OutOfMemory }![]const u8 {
    const source = if (fold) try folded(arena, pattern) else try arena.dupe(u8, pattern);
    var re = spectra.Regex.compile(arena, .init(source), options(fold)) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Invalid, error.Unsupported, error.TooLarge => error.Invalid,
    };
    defer re.deinit();
    if (re.longestHaystack(.find)) |most| if (most < longest) return error.Invalid;
    return source;
}

/// The longest run of bytes folded as one: a character and the marks on
/// it, and no more, so a fold's buffer holds what it writes.
const unit_bytes = 32;

/// `pattern` with each literal character, and the combining marks after
/// it, written as the regex of its NFKC_Casefold; escapes, classes, group
/// heads and counted repetitions are copied as they are.
pub fn folded(arena: Allocator, pattern: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < pattern.len) {
        const c = pattern[at];
        const end = switch (c) {
            '\\' => escapeEnd(pattern, at),
            '[' => classEnd(pattern, at),
            '(' => if (at + 1 < pattern.len and pattern[at + 1] == '?') headEnd(pattern, at) else at + 1,
            '{' => if (std.mem.findScalarPos(u8, pattern, at, '}')) |close| close + 1 else pattern.len,
            else => if (c < 0x80 and !std.ascii.isAlphanumeric(c)) at + 1 else {
                at = try foldUnit(arena, &out, pattern, at);
                continue;
            },
        };
        try out.appendSlice(arena, pattern[at..end]);
        at = end;
    }
    return out.toOwnedSlice(arena);
}

/// Where the escape at `at` ends: `\p{..}`, `\x{..}` and `\u{..}` at their
/// brace, `\xHH` after its digits, any other after the byte it escapes.
fn escapeEnd(pattern: []const u8, at: usize) usize {
    if (at + 1 >= pattern.len) return pattern.len;
    const kind = pattern[at + 1];
    const braced = kind == 'p' or kind == 'P' or kind == 'x' or kind == 'u' or kind == 'U';
    if (braced and at + 2 < pattern.len and pattern[at + 2] == '{') return if (std.mem.findScalarPos(u8, pattern, at + 2, '}')) |close| close + 1 else pattern.len;
    if (kind == 'x') return @min(at + 4, pattern.len);
    if (kind == 'p' or kind == 'P') return @min(at + 3, pattern.len);
    // The escaped byte may begin a longer character: take it whole.
    const len = std.unicode.utf8ByteSequenceLength(kind) catch 1;
    return @min(at + 1 + len, pattern.len);
}

/// Where the class opened at `at` ends: after its `]`, nested classes and
/// escapes inside it read past, a `]` first in it (after any `^`) its own.
fn classEnd(pattern: []const u8, at: usize) usize {
    var i = at + 1;
    if (i < pattern.len and pattern[i] == '^') i += 1;
    if (i < pattern.len and pattern[i] == ']') i += 1;
    var depth: usize = 1;
    while (i < pattern.len) {
        switch (pattern[i]) {
            '\\' => {
                i = escapeEnd(pattern, i);
                continue;
            },
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
        i += 1;
    }
    return pattern.len;
}

/// Where the head of the group opened at `at` (a `(?`) ends: after its
/// flags and name, at the first `)`, `:` or `>`.
fn headEnd(pattern: []const u8, at: usize) usize {
    const close = std.mem.findAnyPos(u8, pattern, at + 2, "):>") orelse return pattern.len;
    return close + 1;
}

/// The literal character at `at` and the marks after it, as the regex of
/// their fold: a single character as itself, anything else (several, or
/// none) as a group, every ASCII byte that is not a letter or a digit
/// escaped. Returns where the unit ends.
fn foldUnit(arena: Allocator, out: *std.ArrayList(u8), pattern: []const u8, at: usize) Allocator.Error!usize {
    var end = nextCodePoint(pattern, at);
    while (end < pattern.len and end - at < unit_bytes) {
        const after = nextCodePoint(pattern, end);
        const cp = std.unicode.utf8Decode(pattern[end..after]) catch break;
        if (xenoglyph.normalize.combiningClass(cp) == 0) break;
        end = after;
    }
    const unit = pattern[at..end];
    // Bytes that are not UTF-8 are the compiler's to refuse.
    if (!std.unicode.utf8ValidateSlice(unit)) {
        try out.appendSlice(arena, unit);
        return end;
    }
    // A fold writes at most 18 code points of 4 bytes for each it reads.
    var buffer: [unit_bytes * 18 * 4]u8 = undefined;
    const fold = words.fold(unit, &buffer);
    const one = fold.len > 0 and (std.unicode.utf8ByteSequenceLength(fold[0]) catch fold.len) == fold.len;
    if (!one) try out.appendSlice(arena, "(?:");
    for (fold) |b| {
        if (b < 0x80 and !std.ascii.isAlphanumeric(b)) try out.append(arena, '\\');
        try out.append(arena, b);
    }
    if (!one) try out.append(arena, ')');
    return end;
}

/// Where the code point at `at` ends; a byte that begins none, after it.
fn nextCodePoint(pattern: []const u8, at: usize) usize {
    const len = std.unicode.utf8ByteSequenceLength(pattern[at]) catch 1;
    return @min(at + len, pattern.len);
}

test "a pattern's literals fold as a text field's terms do, and its syntax stays" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "ÉCOLE", "école" },
        .{ "straße", "stra(?:ss)e" },
        .{ "ＡＢ+", "ab+" },
        .{ "e\u{301}cole", "école" },
        .{ "\\W[ÀÉ]\\p{Lu}(?i:Σ){2,3}", "\\W[ÀÉ]\\p{Lu}(?i:σ){2,3}" },
        .{ "a\u{AD}+", "a(?:)+" },
        .{ "x\u{A0}y", "x\\ y" },
        .{ "\\xC9\\x{C9}", "\\xC9\\x{C9}" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case[1], try folded(a, case[0]));
}

test "a folded pattern compiles; one that does not read is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "straße", "x\u{A0}y", "a\u{AD}+", "ＡＢ+", "ΣΟΦΙΑ.*" }) |p| _ = try prepare(a, p, true, 64);
    try std.testing.expectError(error.Invalid, prepare(a, "a(b", true, 64));
    try std.testing.expectError(error.Invalid, prepare(a, "[z-a]", false, 64));
}
