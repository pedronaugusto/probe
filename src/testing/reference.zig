//! An exact reference for queries: every document of a snapshot held as
//! plain values (each text field's tokens, each keyword, each number), a
//! query evaluated on each document by its definition (`Tree.zig`), with
//! no postings, no skipping and no positions index. Its statistics are the
//! snapshot's, deleted documents counted, and its `f32` scores the same
//! expression in the same order as the search's, so a search's hits must
//! equal its hits bit for bit. `score64` computes BM25 apart, in `f64`
//! with the platform's logarithm, to bound the `f32` error.
//!
//! A phrase is matched by trying every chain of positions from each start,
//! where the search takes the first far enough each time.
const std = @import("std");
const query = @import("../query.zig");
const Tree = query.Tree;
const exec = query.exec;
const bm25 = @import("../bm25.zig");
const Schema = @import("../Schema.zig");
const spectra = @import("spectra");

const Allocator = std.mem.Allocator;
const Node = Tree.Node;

pub const Token = struct { term: []const u8, position: u32 };

/// A field's value in a document, as the index holds it: a text field's
/// tokens, a keyword cut to the term length, a column value.
pub const Value = union(enum) {
    text: []const Token,
    keyword: []const u8,
    numeric: u64,
};

/// A document of the snapshot: where it is, whether it is deleted, and its
/// values by place.
pub const Doc = struct {
    segment: u32,
    doc: u32,
    deleted: bool,
    values: []const Value,
};

pub const Snapshot = struct {
    schema: []const Schema.Field,
    docs: []const Doc,
    /// Per field, each term's documents and the documents' total length,
    /// counted once by `init` (deleted documents among them).
    dfs: []const std.StringHashMapUnmanaged(u64),
    totals: []const u64,
    /// Per regex leaf (field, fold, pattern), the field's terms it matches
    /// whole, found on first use by trying every term of the field.
    matches: *std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)),
    arena: Allocator,

    /// The snapshot of `docs`, its counts on `arena`.
    pub fn init(arena: Allocator, schema: []const Schema.Field, docs: []const Doc) Allocator.Error!Snapshot {
        const dfs = try arena.alloc(std.StringHashMapUnmanaged(u64), schema.len);
        const totals = try arena.alloc(u64, schema.len);
        @memset(dfs, .empty);
        @memset(totals, 0);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (docs) |d| {
            for (d.values, dfs, totals) |v, *counts, *sum| {
                seen.clearRetainingCapacity();
                switch (v) {
                    .text => |tokens| {
                        sum.* += tokens.len;
                        for (tokens) |t| try seen.put(arena, t.term, {});
                    },
                    .keyword => |k| try seen.put(arena, k, {}),
                    .numeric => {},
                }
                var it = seen.keyIterator();
                while (it.next()) |term| {
                    const slot = try counts.getOrPut(arena, term.*);
                    if (!slot.found_existing) slot.value_ptr.* = 0;
                    slot.value_ptr.* += 1;
                }
            }
        }
        const matches = try arena.create(std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)));
        matches.* = .empty;
        return .{ .schema = schema, .docs = docs, .dfs = dfs, .totals = totals, .matches = matches, .arena = arena };
    }

    /// The terms of `x.field` that `x` matches whole: every term searched,
    /// nothing pruned, what the walk's pruning must give. The pattern is
    /// compiled once per snapshot.
    fn matched(s: Snapshot, x: Tree.Regex) Allocator.Error!*const std.StringHashMapUnmanaged(void) {
        const key = try std.mem.concat(s.arena, u8, &.{ &std.mem.toBytes(x.field), &.{@intFromBool(x.fold)}, x.pattern });
        const slot = try s.matches.getOrPut(s.arena, key);
        if (slot.found_existing) return slot.value_ptr;
        slot.value_ptr.* = .empty;
        var re = spectra.Regex.compile(s.arena, .init(x.pattern), query.pattern.options(x.fold)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable, // unreachable: the parser compiled it
        };
        defer re.deinit();
        var c = try re.cache(s.arena);
        defer c.deinit();
        var it = s.dfs[x.field].keyIterator();
        while (it.next()) |term| {
            const found = re.find(&c, .{ .haystack = term.*, .span = .{ .start = 0, .end = term.len }, .whole = true }) catch unreachable; // unreachable: no lookaround in these patterns
            if (found != null) try slot.value_ptr.put(s.arena, term.*, {});
        }
        return slot.value_ptr;
    }

    fn total(s: Snapshot, place: u32) u64 {
        return s.totals[place];
    }

    fn holds(d: Doc, place: u32, bytes: []const u8) u32 {
        return switch (d.values[place]) {
            .text => |tokens| n: {
                var n: u32 = 0;
                for (tokens) |t| n += @intFromBool(std.mem.eql(u8, t.term, bytes));
                break :n n;
            },
            .keyword => |k| @intFromBool(std.mem.eql(u8, k, bytes)),
            .numeric => unreachable,
        };
    }

    fn df(s: Snapshot, place: u32, bytes: []const u8) u64 {
        return s.dfs[place].get(bytes) orelse 0;
    }

    fn length(s: Snapshot, d: Doc, place: u32) u32 {
        return if (s.schema[place].kind == .text) @intCast(d.values[place].text.len) else 1;
    }

    fn weight(s: Snapshot, place: u32, idf: f32) bm25.Weight {
        const f = s.schema[place];
        return .{ .idf = idf, .params = f.bm25, .average = if (f.kind == .text) bm25.average(s.docs.len, s.total(place)) else 1 };
    }

    /// `node`'s score of `d`, or null when it does not match.
    pub fn score(s: Snapshot, gpa: Allocator, node: *const Node, d: Doc) Allocator.Error!?f32 {
        switch (node.*) {
            .term => |t| {
                const freq = holds(d, t.field, t.bytes);
                if (freq == 0) return null;
                const w = s.weight(t.field, bm25.idf(s.docs.len, s.df(t.field, t.bytes)));
                return w.score(@floatFromInt(freq), s.length(d, t.field));
            },
            .phrase => |p| {
                const freq = try phraseFrequency(gpa, d.values[p.field].text, p);
                if (freq == 0) return null;
                var idf: f32 = 0;
                for (p.terms) |t| idf += bm25.idf(s.docs.len, s.df(p.field, t));
                return s.weight(p.field, idf).score(freq, s.length(d, p.field));
            },
            .prefix => |t| switch (d.values[t.field]) {
                .text => |tokens| {
                    for (tokens) |tk| if (std.mem.startsWith(u8, tk.term, t.bytes)) return 1;
                    return null;
                },
                .keyword => |k| return if (std.mem.startsWith(u8, k, t.bytes)) 1 else null,
                .numeric => unreachable,
            },
            .regex => |x| {
                const terms = try s.matched(x);
                switch (d.values[x.field]) {
                    .text => |tokens| for (tokens) |tk| if (terms.contains(tk.term)) return 1,
                    .keyword => |k| if (terms.contains(k)) return 1,
                    .numeric => unreachable,
                }
                return null;
            },
            .range => |r| {
                const v = d.values[r.field].numeric;
                return if (v >= r.min and v <= r.max) 1 else null;
            },
            .all => return 1,
            .none => return null,
            .@"and" => |children| {
                var sum: f32 = 0;
                var positive = false;
                for (children) |*c| switch (c.*) {
                    .not => |child| if (try s.score(gpa, child, d) != null) return null,
                    else => {
                        sum += try s.score(gpa, c, d) orelse return null;
                        positive = true;
                    },
                };
                return if (positive) sum else 1;
            },
            .@"or" => |children| {
                var sum: f32 = 0;
                var any = false;
                for (children) |*c| if (try s.score(gpa, c, d)) |v| {
                    sum += v;
                    any = true;
                };
                return if (any) sum else null;
            },
            .not => |child| return if (try s.score(gpa, child, d) == null) 1 else null,
            .boost => |b| return if (try s.score(gpa, b.node, d)) |v| v * b.by else null,
        }
    }

    /// `node`'s score of `d` in `f64`, BM25 computed apart with the
    /// platform's logarithm, or null when it does not match.
    pub fn score64(s: Snapshot, gpa: Allocator, node: *const Node, d: Doc) Allocator.Error!?f64 {
        switch (node.*) {
            .term => |t| {
                const freq = holds(d, t.field, t.bytes);
                if (freq == 0) return null;
                return s.bm25of(t.field, s.idf64(t.field, t.bytes), @floatFromInt(freq), d);
            },
            .phrase => |p| {
                const freq = try phraseFrequency(gpa, d.values[p.field].text, p);
                if (freq == 0) return null;
                var idf: f64 = 0;
                for (p.terms) |t| idf += s.idf64(p.field, t);
                return s.bm25of(p.field, idf, freq, d);
            },
            .@"and" => |children| {
                var sum: f64 = 0;
                var positive = false;
                for (children) |*c| switch (c.*) {
                    .not => |child| if (try s.score64(gpa, child, d) != null) return null,
                    else => {
                        sum += try s.score64(gpa, c, d) orelse return null;
                        positive = true;
                    },
                };
                return if (positive) sum else 1;
            },
            .@"or" => |children| {
                var sum: f64 = 0;
                var any = false;
                for (children) |*c| if (try s.score64(gpa, c, d)) |v| {
                    sum += v;
                    any = true;
                };
                return if (any) sum else null;
            },
            .not => |child| return if (try s.score64(gpa, child, d) == null) 1 else null,
            .boost => |b| return if (try s.score64(gpa, b.node, d)) |v| v * b.by else null,
            else => return if (try s.score(gpa, node, d)) |v| v else null,
        }
    }

    fn idf64(s: Snapshot, place: u32, bytes: []const u8) f64 {
        const n: f64 = @floatFromInt(s.docs.len);
        const f: f64 = @floatFromInt(s.df(place, bytes));
        return @log(1 + (n - f + 0.5) / (f + 0.5));
    }

    fn bm25of(s: Snapshot, place: u32, idf: f64, freq: f64, d: Doc) f64 {
        const field = s.schema[place];
        const average: f64 = if (field.kind == .text) @as(f64, @floatFromInt(s.total(place))) / @as(f64, @floatFromInt(s.docs.len)) else 1;
        const l: f64 = @floatFromInt(s.length(d, place));
        const k1: f64 = field.bm25.k1;
        const b: f64 = field.bm25.b;
        return idf * freq / (freq + k1 * (1 - b + b * l / average));
    }

    /// The `top` best live hits, best first, which the caller frees.
    pub fn search(s: Snapshot, gpa: Allocator, root: *const Node, top: u32) Allocator.Error![]exec.Hit {
        var hits: std.ArrayList(exec.Hit) = .empty;
        defer hits.deinit(gpa);
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        for (s.docs) |d| {
            if (d.deleted) continue;
            defer _ = scratch.reset(.retain_capacity);
            if (try s.score(scratch.allocator(), root, d)) |v| try hits.append(gpa, .{ .segment = d.segment, .doc = d.doc, .score = v });
        }
        std.mem.sort(exec.Hit, hits.items, {}, struct {
            fn lessThan(_: void, a: exec.Hit, b: exec.Hit) bool {
                return a.before(b);
            }
        }.lessThan);
        hits.shrinkRetainingCapacity(@min(hits.items.len, top));
        return hits.toOwnedSlice(gpa);
    }

    pub fn count(s: Snapshot, gpa: Allocator, root: *const Node) Allocator.Error!u64 {
        var n: u64 = 0;
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        for (s.docs) |d| {
            defer _ = scratch.reset(.retain_capacity);
            if (!d.deleted and try s.score(scratch.allocator(), root, d) != null) n += 1;
        }
        return n;
    }

    pub fn find(s: Snapshot, segment: u32, doc: u32) Doc {
        for (s.docs) |d| if (d.segment == segment and d.doc == doc) return d;
        unreachable;
    }
};

/// A phrase's frequency in a field's tokens by its definition: for each
/// distinct position of its first term, rising, every chain of positions
/// tried, the shortest kept.
pub fn phraseFrequency(gpa: Allocator, tokens: []const Token, p: Tree.Phrase) Allocator.Error!f32 {
    const lists = try gpa.alloc(std.ArrayList(u32), p.terms.len);
    defer {
        for (lists) |*l| l.deinit(gpa);
        gpa.free(lists);
    }
    @memset(lists, .empty);
    for (p.terms, lists) |term, *list| {
        for (tokens) |t| if (std.mem.eql(u8, t.term, term)) try list.append(gpa, t.position);
        std.mem.sort(u32, list.items, {}, std.sort.asc(u32));
    }
    const span = p.positions[p.positions.len - 1] - p.positions[0];
    var freq: f32 = 0;
    var before: ?u32 = null;
    for (lists[0].items) |x| {
        if (before == x) continue;
        before = x;
        const end = shortest(lists, p.positions, 1, x) orelse continue;
        const extra = end - x - span;
        if (extra <= p.slop) freq += 1 / @as(f32, @floatFromInt(1 + extra));
    }
    return freq;
}

/// The least last position of any chain from term `i` on, the one before
/// at `at`, or null when none is.
fn shortest(lists: []const std.ArrayList(u32), offsets: []const u32, i: usize, at: u32) ?u32 {
    if (i == lists.len) return at;
    var best: ?u32 = null;
    for (lists[i].items) |p| {
        if (p < at + (offsets[i] - offsets[i - 1])) continue;
        const end = shortest(lists, offsets, i + 1, p) orelse continue;
        best = if (best) |b| @min(b, end) else end;
    }
    return best;
}
