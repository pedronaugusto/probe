//! A query as a tree of nodes, as the parser builds it and as a program
//! builds it in code. A node names its field by its place in the schema,
//! and its terms by the bytes the index holds (analyzed already).
//!
//! What a node matches, and how it scores (Lucene's):
//!
//! - `term`: the documents holding the term in the field, scored by BM25.
//! - `phrase`: the documents holding its terms in order, each at least its
//!   distance in the query past the one before, the whole at most `slop`
//!   positions longer than the phrase; scored by BM25 with the sum of its
//!   terms' idfs and a frequency of `1 / (1 + extra)` for each position of
//!   its first term that starts a match, `extra` the shortest match's
//!   length past the phrase's (so 1 per match when exact).
//! - `prefix`: the documents holding a term that starts with its bytes,
//!   scored 1.
//! - `regex`: the documents holding a term its pattern matches whole, scored
//!   1; the pattern folded as a text field folds its terms (`pattern.zig`).
//! - `range`: the documents whose column value lies in its bounds, both
//!   included, scored 1.
//! - `all`: every document, scored 1; `none`: no document.
//! - `and`: the documents every child matches, a `not` child among them
//!   excluding what it names and adding nothing; scored by the sum of its
//!   other children's. An `and` of only `not` children is `all` less what
//!   they match, scored as `all`.
//! - `or`: the documents any child matches; scored by the sum of the
//!   matching children's.
//! - `not` anywhere else: `all` less what its child matches, scored as
//!   `all`.
//! - `boost`: its child's documents, scored by its child's times `by`.
//!
//! Sums are taken in the children's order, so a score's bits depend only
//! on the query and the snapshot.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const Schema = @import("../Schema.zig");
const Limits = @import("../Limits.zig");

const Tree = @This();

pub const Node = union(enum) {
    term: Term,
    phrase: Phrase,
    prefix: Term,
    regex: Regex,
    range: Range,
    all,
    none,
    @"and": []const Node,
    @"or": []const Node,
    not: *const Node,
    boost: Boost,
};

/// Bytes in a text or keyword field.
pub const Term = struct {
    field: u32,
    bytes: []const u8,
};

/// A regex term query: `pattern` as `pattern.prepare` made it, read
/// case-insensitive where `fold` (a text field's).
pub const Regex = struct {
    field: u32,
    pattern: []const u8,
    fold: bool,
};

/// Terms of a text field that keeps positions, each with its position in
/// the query, rising strictly from the first's.
pub const Phrase = struct {
    field: u32,
    terms: []const []const u8,
    positions: []const u32,
    slop: u32 = 0,
};

/// Column values of a numeric field (`Schema.columnValue`), both included.
pub const Range = struct {
    field: u32,
    min: u64,
    max: u64,
};

pub const Boost = struct {
    node: *const Node,
    /// Finite and not below 0.
    by: f32,
};

/// A tree its nodes are allocated in.
arena: std.heap.ArenaAllocator,
root: Node,

pub fn deinit(t: *Tree) void {
    t.arena.deinit();
    t.* = undefined;
}

pub const CheckError = error{ Invalid, TooManyClauses, TooDeep };

/// Whether `node` is a query of `schema` within `limits`: each node of a
/// field of its kind (a phrase's field keeping positions), a phrase's
/// positions rising, a boost finite and not below 0, its clauses (every
/// node) at most `limits.clauses` and its depth at most `limits.depth`.
pub fn check(node: *const Node, schema: []const Schema.Field, limits: Limits) CheckError!void {
    var clauses: u32 = 0;
    try checkAt(node, schema, limits, &clauses, 1);
}

fn checkAt(node: *const Node, schema: []const Schema.Field, limits: Limits, clauses: *u32, depth: u32) CheckError!void {
    if (depth > limits.depth) return error.TooDeep;
    clauses.* += 1;
    if (clauses.* > limits.clauses) return error.TooManyClauses;
    switch (node.*) {
        .term, .prefix => |t| {
            const kind = (try fieldOf(schema, t.field)).kind;
            if (kind == .numeric) return error.Invalid;
        },
        .phrase => |p| {
            const f = try fieldOf(schema, p.field);
            if (f.kind != .text or !f.positions) return error.Invalid;
            if (p.terms.len == 0 or p.terms.len != p.positions.len) return error.Invalid;
            for (p.positions[1..], p.positions[0 .. p.positions.len - 1]) |after, before| {
                if (after <= before) return error.Invalid;
            }
        },
        .regex => |r| {
            const kind = (try fieldOf(schema, r.field)).kind;
            if (kind == .numeric or r.fold != (kind == .text)) return error.Invalid;
        },
        .range => |r| if ((try fieldOf(schema, r.field)).kind != .numeric) return error.Invalid,
        .all, .none => {},
        .@"and", .@"or" => |children| for (children) |*c| try checkAt(c, schema, limits, clauses, depth + 1),
        .not => |child| try checkAt(child, schema, limits, clauses, depth + 1),
        .boost => |b| {
            if (!std.math.isFinite(b.by) or b.by < 0) return error.Invalid;
            try checkAt(b.node, schema, limits, clauses, depth + 1);
        },
    }
}

fn fieldOf(schema: []const Schema.Field, place: u32) CheckError!Schema.Field {
    if (place >= schema.len) return error.Invalid;
    return schema[place];
}
