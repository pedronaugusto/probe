//! The query language for people, read into a query tree:
//!
//!     "segment merge" level:err path:src/* -test (alpha OR beta)^2 n:[10 TO *]
//!
//! - Clauses side by side must all match; `AND` between them says the
//!   same, `OR` joins alternatives and binds looser, `NOT x` or `-x`
//!   excludes `x`. Parentheses group.
//! - A word searches the default fields (`Options.fields`, every text field
//!   when null), any of them; `field:word` one field, `field:(...)` a group
//!   in one field. A word on a text field goes through the field's
//!   analysis, as its text did: one term, or when it splits into several (an
//!   identifier's parts, `parseSpan`; words joined by punctuation,
//!   `max-bytes`) the phrase of them on a field that keeps positions, all
//!   of them on one that does not. An identifier's whole word is left out
//!   beside its parts, which find it. A keyword field takes the word's bytes
//!   as they are.
//! - `"..."` is a phrase, `"..."~2` one with slop 2; on a keyword field the
//!   quoted bytes are one term.
//! - `word*` is a prefix: on a text field one word, case-folded; on a
//!   keyword field the bytes as they are.
//! - `field:[a TO b]` is a numeric range, both bounds included, either `*`
//!   for no bound; `field:5` the one value. A number is an integer, negative
//!   only on a signed field.
//! - `*` alone (or `*:*`) matches every document; `^2.5` after a clause boosts it.
//! - `\` takes the next byte as it is, so `\:`, `\*` and `\"` are plain.
//!
//! The text is `input.Untrusted`. What does not read is `error.Invalid`,
//! a query past `Limits.clauses` nodes `error.TooManyClauses` and past
//! `Limits.depth` `error.TooDeep`, each with a `Diagnostic` at the byte it
//! is found at; the reader nests no deeper than `Limits.depth`. A query
//! with no clause left (empty, or words that analyze to nothing) matches
//! nothing.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const Tree = @import("Tree.zig");
const Schema = @import("../Schema.zig");
const Limits = @import("../Limits.zig");
const Pipeline = @import("../analysis/Pipeline.zig");
const words = @import("../analysis/words.zig");

const Allocator = std.mem.Allocator;
const Node = Tree.Node;

pub const Error = error{ Invalid, TooManyClauses, TooDeep, OutOfMemory };

/// Why a query does not read.
pub const Problem = enum {
    /// A byte that cannot stand here, or a clause missing where one must.
    unexpected,
    unclosed_quote,
    unclosed_group,
    unclosed_range,
    /// A field the schema does not have.
    unknown_field,
    /// A clause the field does not take: a phrase on a text field without
    /// positions, a word or prefix on a numeric field, a range on one that
    /// is not numeric.
    wrong_kind,
    /// A number that does not read, or does not fit the field.
    bad_number,
    /// A prefix of more than one word on a text field.
    prefix_words,
    too_many_clauses,
    too_deep,
};

/// Where a query does not read, and why.
pub const Diagnostic = struct {
    offset: usize = 0,
    problem: Problem = .unexpected,
};

pub const Options = struct {
    /// The fields a word with no field searches, by name; every text field
    /// when null.
    fields: ?[]const []const u8 = null,
    limits: Limits = .{},
    /// Told where and why the query does not read.
    diagnostic: ?*Diagnostic = null,
};

/// The tree of `text`, a query of `schema`, its nodes and terms on an arena
/// of `gpa` the tree owns.
pub fn parse(gpa: Allocator, schema: []const Schema.Field, text: aegis.input.Untrusted([]const u8), options: Options) Error!Tree {
    return text.parse(Context{ .gpa = gpa, .schema = schema, .options = options }, read);
}

const Context = struct {
    gpa: Allocator,
    schema: []const Schema.Field,
    options: Options,
};

fn read(c: Context, text: []const u8) Error!Tree {
    var tree: Tree = .{ .arena = .init(c.gpa), .root = .none };
    errdefer tree.arena.deinit();
    const arena = tree.arena.allocator();
    var p: Parser = .{
        .arena = arena,
        .schema = c.schema,
        .limits = c.options.limits,
        .diagnostic = c.options.diagnostic,
        .text = text,
        .term = try arena.alloc(u8, c.options.limits.term_bytes),
        .defaults = undefined,
    };
    p.defaults = try p.defaultsOf(c.options.fields);
    p.skipSpace();
    if (p.at < text.len) {
        tree.root = try p.orExpr() orelse .none;
        p.skipSpace();
        if (p.at < text.len) return p.fail(p.at, .unexpected, error.Invalid);
    }
    Tree.check(&tree.root, c.schema, c.options.limits) catch |err| return switch (err) {
        error.TooManyClauses => p.fail(0, .too_many_clauses, error.TooManyClauses),
        error.TooDeep => p.fail(0, .too_deep, error.TooDeep),
        error.Invalid => aegis.assert.never("the parser builds only trees of its schema"),
    };
    return tree;
}

const Parser = struct {
    arena: Allocator,
    schema: []const Schema.Field,
    limits: Limits,
    diagnostic: ?*Diagnostic,
    text: []const u8,
    at: usize = 0,
    /// Where analysis writes a term.
    term: []u8,
    /// The places a word with no field searches.
    defaults: []const u32,
    /// The field a group is scoped to, if any.
    scope: ?u32 = null,
    clauses: u32 = 0,
    depth: u32 = 0,

    fn fail(p: *Parser, offset: usize, problem: Problem, err: Error) Error {
        if (p.diagnostic) |d| d.* = .{ .offset = offset, .problem = problem };
        return err;
    }

    fn defaultsOf(p: *Parser, names: ?[]const []const u8) Error![]const u32 {
        var out: std.ArrayList(u32) = .empty;
        if (names) |list| {
            for (list) |name| {
                const place = p.placeOf(name) orelse return p.fail(0, .unknown_field, error.Invalid);
                if (p.schema[place].kind == .numeric) return p.fail(0, .wrong_kind, error.Invalid);
                try out.append(p.arena, place);
            }
        } else for (p.schema, 0..) |f, place| {
            if (f.kind == .text) try out.append(p.arena, @intCast(place));
        }
        return out.items;
    }

    fn placeOf(p: *const Parser, name: []const u8) ?u32 {
        for (p.schema, 0..) |f, place| if (std.mem.eql(u8, f.name, name)) return @intCast(place);
        return null;
    }

    /// One more node, within the clauses allowed.
    fn node(p: *Parser, n: Node) Error!Node {
        p.clauses += 1;
        if (p.clauses > p.limits.clauses) return p.fail(p.at, .too_many_clauses, error.TooManyClauses);
        return n;
    }

    fn skipSpace(p: *Parser) void {
        while (p.at < p.text.len and std.ascii.isWhitespace(p.text[p.at])) p.at += 1;
    }

    /// Whether `operator` stands at the cursor, a whole word.
    fn keyword(p: *const Parser, operator: []const u8) bool {
        if (!std.mem.startsWith(u8, p.text[p.at..], operator)) return false;
        const after = p.at + operator.len;
        return after == p.text.len or std.ascii.isWhitespace(p.text[after]) or p.text[after] == '(' or p.text[after] == ')';
    }

    /// One level deeper, within the depth allowed.
    fn enter(p: *Parser) Error!void {
        p.depth += 1;
        if (p.depth > p.limits.depth) return p.fail(p.at, .too_deep, error.TooDeep);
    }

    fn orExpr(p: *Parser) Error!?Node {
        var children: std.ArrayList(Node) = .empty;
        if (try p.andExpr()) |n| try children.append(p.arena, n);
        while (true) {
            p.skipSpace();
            if (!p.keyword("OR")) break;
            p.at += 2;
            p.skipSpace();
            if (p.at == p.text.len or p.text[p.at] == ')' or p.keyword("OR")) return p.fail(p.at, .unexpected, error.Invalid);
            if (try p.andExpr()) |n| try children.append(p.arena, n);
        }
        return try p.joined(.@"or", children.items);
    }

    fn andExpr(p: *Parser) Error!?Node {
        var children: std.ArrayList(Node) = .empty;
        var any = false;
        while (true) {
            p.skipSpace();
            if (p.at == p.text.len or p.text[p.at] == ')' or p.keyword("OR")) break;
            if (p.keyword("AND")) {
                if (!any) return p.fail(p.at, .unexpected, error.Invalid);
                p.at += 3;
                p.skipSpace();
                if (p.at == p.text.len or p.text[p.at] == ')' or p.keyword("OR") or p.keyword("AND")) return p.fail(p.at, .unexpected, error.Invalid);
                continue;
            }
            any = true;
            if (try p.unary()) |n| try children.append(p.arena, n);
        }
        if (!any) return p.fail(p.at, .unexpected, error.Invalid);
        return try p.joined(.@"and", children.items);
    }

    /// `children` joined by `tag`: null for none, the one for one.
    fn joined(p: *Parser, comptime tag: std.meta.Tag(Node), children: []const Node) Error!?Node {
        return switch (children.len) {
            0 => null,
            1 => children[0],
            else => try p.node(@unionInit(Node, @tagName(tag), children)),
        };
    }

    fn unary(p: *Parser) Error!?Node {
        const negated = if (p.at + 1 < p.text.len and p.text[p.at] == '-' and !std.ascii.isWhitespace(p.text[p.at + 1])) w: {
            p.at += 1;
            break :w true;
        } else if (p.keyword("NOT")) w: {
            p.at += 3;
            p.skipSpace();
            if (p.at == p.text.len or p.text[p.at] == ')') return p.fail(p.at, .unexpected, error.Invalid);
            break :w true;
        } else false;
        if (negated) {
            try p.enter();
            defer p.depth -= 1;
            const child = try p.unary() orelse return null;
            const boxed = try p.arena.create(Node);
            boxed.* = child;
            return try p.node(.{ .not = boxed });
        }
        const n = try p.primary() orelse {
            // A clause that analyzed to nothing takes no boost either.
            _ = try p.boost();
            return null;
        };
        const by = try p.boost() orelse return n;
        const boxed = try p.arena.create(Node);
        boxed.* = n;
        return try p.node(.{ .boost = .{ .node = boxed, .by = by } });
    }

    /// A `^` and its factor after a clause, if one stands there.
    fn boost(p: *Parser) Error!?f32 {
        if (p.at == p.text.len or p.text[p.at] != '^') return null;
        p.at += 1;
        const start = p.at;
        while (p.at < p.text.len and (std.ascii.isDigit(p.text[p.at]) or p.text[p.at] == '.')) p.at += 1;
        const by = std.fmt.parseFloat(f32, p.text[start..p.at]) catch return p.fail(start, .bad_number, error.Invalid);
        if (!std.math.isFinite(by)) return p.fail(start, .bad_number, error.Invalid);
        return by;
    }

    fn primary(p: *Parser) Error!?Node {
        if (p.at == p.text.len) return p.fail(p.at, .unexpected, error.Invalid);
        switch (p.text[p.at]) {
            '(' => return p.group(),
            '"' => return p.phraseIn(p.scope),
            ')', '^', '~', ':' => return p.fail(p.at, .unexpected, error.Invalid),
            else => {},
        }
        if (std.mem.startsWith(u8, p.text[p.at..], "*:*") and p.endsWord(p.at + 3)) {
            p.at += 3;
            return try p.node(.all);
        }
        if (p.text[p.at] == '*' and p.endsWord(p.at + 1)) {
            p.at += 1;
            return try p.node(.all);
        }
        const start = p.at;
        const w = try p.word(p.scope == null);
        if (p.scope == null and p.at < p.text.len and p.text[p.at] == ':') {
            // A field, then its value.
            if (w.prefix or w.escaped) return p.fail(start, .unknown_field, error.Invalid);
            const place = p.placeOf(w.bytes) orelse return p.fail(start, .unknown_field, error.Invalid);
            p.at += 1;
            if (p.at == p.text.len) return p.fail(p.at, .unexpected, error.Invalid);
            p.scope = place;
            defer p.scope = null;
            return switch (p.text[p.at]) {
                '(' => p.group(),
                '"' => p.phraseIn(place),
                '[' => p.range(place),
                else => v: {
                    const at = p.at;
                    const value = try p.word(false);
                    break :v p.valueIn(place, value, at);
                },
            };
        }
        if (p.scope) |place| return p.valueIn(place, w, start);
        return p.anyDefault(w, start, null);
    }

    fn group(p: *Parser) Error!?Node {
        const open = p.at;
        try p.enter();
        p.at += 1;
        defer p.depth -= 1;
        p.skipSpace();
        if (p.at < p.text.len and p.text[p.at] == ')') return p.fail(p.at, .unexpected, error.Invalid);
        if (p.at == p.text.len) return p.fail(open, .unclosed_group, error.Invalid);
        const n = try p.orExpr();
        p.skipSpace();
        if (p.at == p.text.len or p.text[p.at] != ')') return p.fail(open, .unclosed_group, error.Invalid);
        p.at += 1;
        return n;
    }

    /// Whether a word ends at `i`: the text's end, a space or a group's.
    fn endsWord(p: *const Parser, i: usize) bool {
        return i == p.text.len or std.ascii.isWhitespace(p.text[i]) or p.text[i] == ')' or p.text[i] == '^';
    }

    const Word = struct { bytes: []const u8, prefix: bool, escaped: bool };

    /// A word, its escapes taken: up to a space, a group's end, a quote, a
    /// boost, or when `field` may follow a colon. A last unescaped `*`
    /// makes it a prefix.
    fn word(p: *Parser, field: bool) Error!Word {
        var out: std.ArrayList(u8) = .empty;
        var escaped = false;
        var prefix = false;
        const start = p.at;
        while (p.at < p.text.len) {
            const c = p.text[p.at];
            if (std.ascii.isWhitespace(c) or c == '(' or c == ')' or c == '"' or c == '^' or (field and c == ':')) break;
            if (c == '\\') {
                if (p.at + 1 == p.text.len) return p.fail(p.at, .unexpected, error.Invalid);
                try out.append(p.arena, p.text[p.at + 1]);
                p.at += 2;
                escaped = true;
                continue;
            }
            if (c == '*' and p.endsWord(p.at + 1)) {
                p.at += 1;
                prefix = true;
                break;
            }
            try out.append(p.arena, c);
            p.at += 1;
        }
        if (p.at == start) return p.fail(p.at, .unexpected, error.Invalid);
        return .{ .bytes = out.items, .prefix = prefix, .escaped = escaped };
    }

    /// A word with no field: in any default field.
    fn anyDefault(p: *Parser, w: Word, at: usize, slop: ?u32) Error!?Node {
        var children: std.ArrayList(Node) = .empty;
        var took: usize = 0;
        for (p.defaults) |place| {
            const f = p.schema[place];
            // A phrase searches the default fields that can hold one.
            if (slop != null and f.kind == .text and !f.positions) continue;
            took += 1;
            const n = if (slop) |s| try p.phraseOf(place, w.bytes, s, at) else try p.valueIn(place, w, at);
            if (n) |one| try children.append(p.arena, one);
        }
        if (slop != null and took == 0 and p.defaults.len > 0) return p.fail(at, .wrong_kind, error.Invalid);
        return p.joined(.@"or", children.items);
    }

    /// A word's clause in the field at `place`.
    fn valueIn(p: *Parser, place: u32, w: Word, at: usize) Error!?Node {
        const f = p.schema[place];
        switch (f.kind) {
            .numeric => {
                if (w.prefix) return p.fail(at, .wrong_kind, error.Invalid);
                const v = try p.number(place, w.bytes, at);
                return try p.node(.{ .range = .{ .field = place, .min = v, .max = v } });
            },
            .keyword => {
                const bytes = w.bytes[0..@min(w.bytes.len, p.term.len)];
                return try p.node(if (w.prefix) .{ .prefix = .{ .field = place, .bytes = bytes } } else .{ .term = .{ .field = place, .bytes = bytes } });
            },
            .text => {
                if (w.prefix) {
                    var it: words.Words = .init(w.bytes);
                    const first = it.next() orelse return null;
                    if (it.next() != null) return p.fail(at, .prefix_words, error.Invalid);
                    const folded = words.fold(first.bytes, p.term);
                    return try p.node(.{ .prefix = .{ .field = place, .bytes = try p.arena.dupe(u8, folded) } });
                }
                return p.analyzed(place, w.bytes, 0, f.positions);
            },
        }
    }

    /// The clause of `text` analyzed as the field at `place` analyzes: one
    /// term, or the phrase of several when `as_phrase`, else all of them.
    fn analyzed(p: *Parser, place: u32, text: []const u8, slop: u32, as_phrase: bool) Error!?Node {
        var terms: std.ArrayList([]const u8) = .empty;
        var positions: std.ArrayList(u32) = .empty;
        switch (p.schema[place].analysis) {
            inline else => |analysis| {
                var tokens: Pipeline.Of(analysis) = .init(text, p.term);
                while (tokens.next()) |t| {
                    // A whole word kept beside its parts shares its first
                    // part's position: the parts find it.
                    if (positions.items.len > 0 and positions.items[positions.items.len - 1] == t.position) {
                        terms.items[terms.items.len - 1] = try p.arena.dupe(u8, t.term);
                        continue;
                    }
                    try terms.append(p.arena, try p.arena.dupe(u8, t.term));
                    try positions.append(p.arena, t.position);
                }
            },
        }
        switch (terms.items.len) {
            0 => return null,
            1 => return try p.node(.{ .term = .{ .field = place, .bytes = terms.items[0] } }),
            else => {},
        }
        if (as_phrase) return try p.node(.{ .phrase = .{ .field = place, .terms = terms.items, .positions = positions.items, .slop = slop } });
        const children = try p.arena.alloc(Node, terms.items.len);
        for (children, terms.items) |*c, t| c.* = try p.node(.{ .term = .{ .field = place, .bytes = t } });
        return try p.node(.{ .@"and" = children });
    }

    /// A quoted phrase and its slop, in the field at `place` or the
    /// default fields.
    fn phraseIn(p: *Parser, scope: ?u32) Error!?Node {
        const open = p.at;
        p.at += 1;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (p.at == p.text.len) return p.fail(open, .unclosed_quote, error.Invalid);
            const c = p.text[p.at];
            if (c == '"') break;
            if (c == '\\' and p.at + 1 < p.text.len) {
                try out.append(p.arena, p.text[p.at + 1]);
                p.at += 2;
                continue;
            }
            try out.append(p.arena, c);
            p.at += 1;
        }
        p.at += 1;
        var slop: u32 = 0;
        if (p.at < p.text.len and p.text[p.at] == '~') {
            p.at += 1;
            const start = p.at;
            while (p.at < p.text.len and std.ascii.isDigit(p.text[p.at])) p.at += 1;
            slop = std.fmt.parseInt(u32, p.text[start..p.at], 10) catch return p.fail(start, .bad_number, error.Invalid);
        }
        const w: Word = .{ .bytes = out.items, .prefix = false, .escaped = false };
        if (scope) |place| return p.phraseOf(place, w.bytes, slop, open);
        return p.anyDefault(w, open, slop);
    }

    fn phraseOf(p: *Parser, place: u32, text: []const u8, slop: u32, at: usize) Error!?Node {
        const f = p.schema[place];
        return switch (f.kind) {
            .numeric => p.fail(at, .wrong_kind, error.Invalid),
            .keyword => try p.node(.{ .term = .{ .field = place, .bytes = text[0..@min(text.len, p.term.len)] } }),
            .text => if (!f.positions) p.fail(at, .wrong_kind, error.Invalid) else p.analyzed(place, text, slop, true),
        };
    }

    /// `[a TO b]` in the numeric field at `place`.
    fn range(p: *Parser, place: u32) Error!?Node {
        const open = p.at;
        if (p.schema[place].kind != .numeric) return p.fail(open, .wrong_kind, error.Invalid);
        p.at += 1;
        p.skipSpace();
        const min = try p.bound(place, 0);
        p.skipSpace();
        if (!p.keyword("TO")) return p.fail(p.at, if (p.at == p.text.len) .unclosed_range else .unexpected, error.Invalid);
        p.at += 2;
        p.skipSpace();
        const max = try p.bound(place, std.math.maxInt(u64));
        p.skipSpace();
        if (p.at == p.text.len) return p.fail(open, .unclosed_range, error.Invalid);
        if (p.text[p.at] != ']') return p.fail(p.at, .unexpected, error.Invalid);
        p.at += 1;
        return try p.node(.{ .range = .{ .field = place, .min = min, .max = max } });
    }

    /// A range's bound: `*` for `open`, else a number.
    fn bound(p: *Parser, place: u32, open: u64) Error!u64 {
        if (p.at == p.text.len) return p.fail(p.at, .unclosed_range, error.Invalid);
        if (p.text[p.at] == '*') {
            p.at += 1;
            return open;
        }
        const start = p.at;
        while (p.at < p.text.len and (std.ascii.isDigit(p.text[p.at]) or (p.at == start and p.text[p.at] == '-'))) p.at += 1;
        return p.number(place, p.text[start..p.at], start);
    }

    /// `text` as the column value of the numeric field at `place`.
    fn number(p: *Parser, place: u32, text: []const u8, at: usize) Error!u64 {
        if (p.schema[place].signed) {
            const v = std.fmt.parseInt(i64, text, 10) catch return p.fail(at, .bad_number, error.Invalid);
            return Schema.columnValue(v);
        }
        return std.fmt.parseInt(u64, text, 10) catch p.fail(at, .bad_number, error.Invalid);
    }
};

/// What `parse` builds for a word in the field at `place`, on `arena`: a
/// term, a phrase of its parts or all of them, a prefix when `prefix`, a
/// keyword's bytes, a numeric field's one value; null when it analyzes to
/// nothing. The query builders build words with it.
pub fn wordClause(arena: Allocator, schema: []const Schema.Field, limits: Limits, place: u32, text: []const u8, prefix: bool) Error!?Node {
    var p = try builder(arena, schema, limits);
    return p.valueIn(place, .{ .bytes = text, .prefix = prefix, .escaped = false }, 0);
}

/// What `parse` builds for a quoted phrase in the field at `place`.
pub fn phraseClause(arena: Allocator, schema: []const Schema.Field, limits: Limits, place: u32, text: []const u8, slop: u32) Error!?Node {
    var p = try builder(arena, schema, limits);
    return p.phraseOf(place, text, slop, 0);
}

fn builder(arena: Allocator, schema: []const Schema.Field, limits: Limits) Allocator.Error!Parser {
    return .{ .arena = arena, .schema = schema, .limits = limits, .diagnostic = null, .text = "", .term = try arena.alloc(u8, limits.term_bytes), .defaults = &.{} };
}
