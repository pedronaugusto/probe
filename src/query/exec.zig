//! A query run over a snapshot: its statistics taken once, then each
//! segment's documents walked by iterators over its postings, positions
//! and columns, compiled from the tree. Every iterator moves forward only,
//! by `seek(target)`, to its first document at or past `target`.
//!
//! - A term walks its postings, passing blocks by their skip entries and
//!   galloping inside one.
//! - A conjunction leads with its cheapest child (the rarest term) and
//!   moves the others to the leader's document; a `not` child is checked
//!   last, on documents every other child matched.
//! - A phrase is a conjunction of its terms whose documents are then
//!   checked through their positions (`phrase.zig`).
//! - A prefix expands through each segment's dictionary, at most
//!   `Limits.expansions` terms in a segment (`error.TooManyTerms` past
//!   them, before any is read), into the set of their documents.
//! - A range passes a column block whose least and greatest value lie
//!   outside it whole.
//! - A disjunction at the root runs block-max WAND for the best hits:
//!   a block of postings whose bound from its impacts, with the bounds of
//!   the other clauses there, cannot pass the worst hit held is passed
//!   unscored (`wand.zig`; the bounds are never below a score, so the hits
//!   are the ones every document scored would give).
//!
//! Hits are ordered by score, highest first, and equal scores by their
//! place in the snapshot: segment, then document. Deleted documents are
//! matched by the iterators and dropped as they are collected.
//!
//! A search checks `io.checkCancel()` every 64 postings blocks it enters
//! and every 8192 documents it collects; its reads are canceled where
//! they wait.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const Tree = @import("Tree.zig");
const phrase = @import("phrase.zig");
const wand = @import("wand.zig");
const bm25 = @import("../bm25.zig");
const Schema = @import("../Schema.zig");
const Limits = @import("../Limits.zig");
const Reader = @import("../Reader.zig");
const segment = @import("../segment.zig");
const fst = @import("../encoding.zig").fst;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Node = Tree.Node;
const postings = segment.postings;
const positions = segment.positions;
const columns = segment.columns;
const block_len = 128;

pub const Error = error{ TooManyTerms, Canceled, ReadFailed, Corrupt, OutOfMemory };

/// A document a query matched: its segment's place in the snapshot, its
/// doc id there and its score.
pub const Hit = struct {
    segment: u32,
    doc: u32,
    score: f32,

    /// Whether `a` ranks before `b`: a higher score, or an equal one
    /// earlier in the snapshot.
    pub fn before(a: Hit, b: Hit) bool {
        if (a.score != b.score) return a.score > b.score;
        if (a.segment != b.segment) return a.segment < b.segment;
        return a.doc < b.doc;
    }
};

pub const Options = struct {
    /// The most hits to give, at least 1.
    top: u32 = 10,
    limits: Limits = .{},
    /// Whether a disjunction at the root runs block-max WAND; else every
    /// document it matches is scored.
    wand: bool = true,
    /// Told what the search did.
    report: ?*Report = null,
};

/// What a search did: the documents it scored, and the stretches of
/// documents block-max WAND passed without scoring.
pub const Report = struct {
    scored: u64 = 0,
    skipped: u64 = 0,
};

/// The `options.top` best hits of `root` in `snapshot`, best first, which
/// the caller frees with `gpa`. `root` is a query of the snapshot's schema
/// (`Tree.check`).
pub fn search(gpa: Allocator, io: Io, snapshot: *const Reader, root: *const Node, options: Options) Error![]Hit {
    aegis.assert.invariant(options.top > 0, "a search asks for a hit at least");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var run: Run = try .init(arena.allocator(), io, snapshot, root, options.limits);
    var best: Best = .{ .gpa = gpa, .top = options.top };
    defer best.deinit();
    var report: Report = .{};
    defer if (options.report) |r| {
        r.* = report;
    };
    for (snapshot.segments, 0..) |*s, place| {
        var it = try run.compile(s);
        defer run.reset();
        if (options.wand and it.kind == .@"or") {
            try wandSegment(&run, &best, &report, @intCast(place), s, it.kind.@"or");
            continue;
        }
        var doc: u32 = 0;
        while (true) : (doc += 1) {
            doc = try it.seek(doc);
            if (doc == done) break;
            try run.collected();
            if (s.isDeleted(doc)) continue;
            report.scored += 1;
            try best.add(.{ .segment = @intCast(place), .doc = doc, .score = try it.score() });
        }
    }
    return best.finish();
}

/// A disjunction's best hits in one segment by block-max WAND (Ding and
/// Suel). Its children are kept in order of the document each stands on.
/// Once `best` is full, a document must score above the worst hit held to
/// enter it: one that only ties it comes later in the snapshot than every
/// hit held, so it ranks after them. The pivot is the first child at which
/// the children's bounds anywhere, summed in that order, pass the
/// threshold: no document before it can. Then the bounds of the blocks
/// holding the pivot's document, of every child on it or before it,
/// summed: when they do not pass the threshold, no document up to the
/// first block's end (or the next child's document) can, and those
/// children move past it unscored. Otherwise the children before the pivot
/// move to its document, and once all stand on it, it is scored.
fn wandSegment(run: *Run, best: *Best, report: *Report, place: u32, s: *const Reader.Segment, children: []Iter) Error!void {
    const n = children.len;
    const order = try run.segment_arena.allocator().alloc(usize, n);
    for (order, children, 0..) |*o, *c, i| {
        o.* = i;
        _ = try c.seek(0);
    }
    while (true) {
        // By document: few children, nearly in order each time.
        std.sort.insertion(usize, order, children, struct {
            fn lessThan(its: []Iter, a: usize, b: usize) bool {
                return its[a].doc.? < its[b].doc.?;
            }
        }.lessThan);
        const threshold = best.threshold();
        var anywhere: f64 = 0;
        const pivot: usize = for (order, 0..) |c, i| {
            if (children[c].doc.? == done) return;
            anywhere += children[c].bound();
            if (threshold == null or wand.sum(anywhere, n) > @as(f64, threshold.?)) break i;
        } else return;
        const doc = children[order[pivot]].doc.?;
        // Every child standing on the pivot's document is with it.
        var end = pivot + 1;
        while (end < n and children[order[end]].doc.? == doc) end += 1;
        if (threshold) |t| {
            var bound: f64 = 0;
            var next: u64 = if (end < n) children[order[end]].doc.? else done;
            for (order[0..end]) |c| {
                const b = try children[c].blockBound(doc);
                bound += b.bound;
                next = @min(next, @as(u64, b.last) + 1);
            }
            if (wand.sum(bound, n) <= @as(f64, t)) {
                report.skipped += 1;
                const target: u32 = @intCast(@min(next, done));
                for (order[0..end]) |c| _ = try children[c].seek(target);
                continue;
            }
        }
        if (children[order[0]].doc.? != doc) {
            for (order[0..pivot]) |c| _ = try children[c].seek(doc);
            continue;
        }
        try run.collected();
        if (!s.isDeleted(doc)) {
            report.scored += 1;
            // The sum in the query's order, as the disjunction scores it.
            var score: f32 = 0;
            for (children) |*c| if (c.doc.? == doc) {
                score += try c.score();
            };
            try best.add(.{ .segment = place, .doc = doc, .score = score });
        }
        for (order[0..end]) |c| _ = try children[c].seek(doc + 1);
    }
}

/// How many live documents of `snapshot` match `root`.
pub fn count(gpa: Allocator, io: Io, snapshot: *const Reader, root: *const Node, limits: Limits) Error!u64 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var run: Run = try .init(arena.allocator(), io, snapshot, root, limits);
    var n: u64 = 0;
    for (snapshot.segments) |*s| {
        var it = try run.compile(s);
        defer run.reset();
        var doc: u32 = 0;
        while (true) : (doc += 1) {
            doc = try it.seek(doc);
            if (doc == done) break;
            try run.collected();
            if (!s.isDeleted(doc)) n += 1;
        }
    }
    return n;
}

/// Past every document of a segment.
const done = std.math.maxInt(u32);

/// The best hits so far, the worst of them on top of a heap.
const Best = struct {
    gpa: Allocator,
    top: u32,
    heap: std.ArrayList(Hit) = .empty,

    fn deinit(b: *Best) void {
        b.heap.deinit(b.gpa);
    }

    /// The score a hit must pass to enter, once full: the worst held.
    fn threshold(b: *const Best) ?f32 {
        return if (b.heap.items.len == b.top) b.heap.items[0].score else null;
    }

    fn add(b: *Best, hit: Hit) Allocator.Error!void {
        const items = b.heap.items;
        if (items.len == b.top) {
            if (!hit.before(items[0])) return;
            items[0] = hit;
            b.down(0);
            return;
        }
        try b.heap.append(b.gpa, hit);
        var i = b.heap.items.len - 1;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (!b.heap.items[parent].before(b.heap.items[i])) break;
            std.mem.swap(Hit, &b.heap.items[parent], &b.heap.items[i]);
            i = parent;
        }
    }

    /// Moves the hit at `start` down to its place: a parent ranks after
    /// its children.
    fn down(b: *Best, start: usize) void {
        const items = b.heap.items;
        var i = start;
        while (true) {
            var worst = i;
            for ([_]usize{ 2 * i + 1, 2 * i + 2 }) |child| {
                if (child < items.len and items[worst].before(items[child])) worst = child;
            }
            if (worst == i) return;
            std.mem.swap(Hit, &items[i], &items[worst]);
            i = worst;
        }
    }

    fn finish(b: *Best) Allocator.Error![]Hit {
        std.mem.sort(Hit, b.heap.items, {}, struct {
            fn lessThan(_: void, x: Hit, y: Hit) bool {
                return x.before(y);
            }
        }.lessThan);
        return b.heap.toOwnedSlice(b.gpa);
    }
};

/// A query over a snapshot: its weights, from the snapshot's statistics,
/// and the iterators of the segment being walked.
const Run = struct {
    arena: Allocator,
    io: Io,
    schema: []const Schema.Field,
    limits: Limits,
    /// The longest term the index holds: a prefix walk's key buffer.
    term_bytes: u16,
    plan: Plan,
    /// The iterators of one segment, released when it is walked.
    segment_arena: std.heap.ArenaAllocator,
    /// Postings blocks entered and documents collected since the last
    /// cancel check.
    blocks: u32 = 0,
    documents: u32 = 0,

    fn init(arena: Allocator, io: Io, snapshot: *const Reader, root: *const Node, limits: Limits) Error!Run {
        const stats: Stats = try .of(arena, snapshot);
        return .{
            .arena = arena,
            .io = io,
            .schema = snapshot.schema,
            .limits = limits,
            .term_bytes = snapshot.options.term_bytes,
            .plan = try planOf(arena, io, snapshot, &stats, root),
            .segment_arena = .init(arena),
        };
    }

    fn reset(r: *Run) void {
        _ = r.segment_arena.reset(.retain_capacity);
    }

    /// One more document collected.
    fn collected(r: *Run) Io.Cancelable!void {
        r.documents += 1;
        if (r.documents < 64 * block_len) return;
        r.documents = 0;
        try r.io.checkCancel();
    }

    /// `n` more postings blocks entered.
    fn entered(r: *Run, n: u32) Io.Cancelable!void {
        r.blocks += n;
        if (r.blocks < 64) return;
        r.blocks = 0;
        try r.io.checkCancel();
    }

    fn compile(r: *Run, s: *const Reader.Segment) Error!Iter {
        return compileNode(r, s.read(), &r.plan);
    }
};

/// The snapshot's documents, and each text field's total length, deleted
/// documents counted.
const Stats = struct {
    docs: u64,
    totals: []u64,

    fn of(arena: Allocator, snapshot: *const Reader) Allocator.Error!Stats {
        const totals = try arena.alloc(u64, snapshot.schema.len);
        @memset(totals, 0);
        var docs: u64 = 0;
        for (snapshot.segments) |*s| {
            docs += s.docs();
            for (snapshot.schema, totals, 0..) |f, *t, place| {
                if (f.kind == .text) t.* += s.read().total(@intCast(place));
            }
        }
        return .{ .docs = docs, .totals = totals };
    }

    /// What scores a term or phrase of `idf` in the field at `place`.
    fn weight(s: *const Stats, schema: []const Schema.Field, place: u32, term_idf: f32) bm25.Weight {
        const f = schema[place];
        return .{ .idf = term_idf, .params = f.bm25, .average = if (f.kind == .text) bm25.average(s.docs, s.totals[place]) else 1 };
    }

    /// The idf of `bytes` in the field at `place`: its documents read from
    /// each segment's dictionary and postings head.
    fn idf(s: *const Stats, io: Io, snapshot: *const Reader, place: u32, bytes: []const u8) Error!f32 {
        var df: u64 = 0;
        for (snapshot.segments) |*seg| {
            const t = try seg.read().term(io, place, bytes) orelse continue;
            df += t.postings.docFreq();
        }
        if (df > s.docs) return error.Corrupt;
        return bm25.idf(s.docs, df);
    }
};

/// The tree with each term's and phrase's weight in the snapshot.
const Plan = union(enum) {
    term: struct { term: Tree.Term, weight: bm25.Weight },
    phrase: struct { phrase: Tree.Phrase, weight: bm25.Weight },
    prefix: Tree.Term,
    range: Tree.Range,
    all,
    none,
    @"and": []const Plan,
    @"or": []const Plan,
    not: *const Plan,
    boost: struct { plan: *const Plan, by: f32 },
};

fn planOf(arena: Allocator, io: Io, snapshot: *const Reader, stats: *const Stats, node: *const Node) Error!Plan {
    const schema = snapshot.schema;
    return switch (node.*) {
        .term => |t| .{ .term = .{ .term = t, .weight = stats.weight(schema, t.field, try stats.idf(io, snapshot, t.field, t.bytes)) } },
        .phrase => |p| {
            // The sum of its terms' idfs, in the phrase's order.
            var sum: f32 = 0;
            for (p.terms) |t| sum += try stats.idf(io, snapshot, p.field, t);
            return .{ .phrase = .{ .phrase = p, .weight = stats.weight(schema, p.field, sum) } };
        },
        .prefix => |t| .{ .prefix = t },
        .range => |r| .{ .range = r },
        .all => .all,
        .none => .none,
        inline .@"and", .@"or" => |children, tag| {
            const plans = try arena.alloc(Plan, children.len);
            for (children, plans) |*c, *p| p.* = try planOf(arena, io, snapshot, stats, c);
            return @unionInit(Plan, @tagName(tag), plans);
        },
        .not => |child| {
            const p = try arena.create(Plan);
            p.* = try planOf(arena, io, snapshot, stats, child);
            return .{ .not = p };
        },
        .boost => |b| {
            const p = try arena.create(Plan);
            p.* = try planOf(arena, io, snapshot, stats, b.node);
            return .{ .boost = .{ .plan = p, .by = b.by } };
        },
    };
}

/// A plan's iterator over one segment.
const Iter = struct {
    /// The document it stands on, `done` past the last, null before the
    /// first.
    doc: ?u32 = null,
    kind: Kind,

    const Kind = union(enum) {
        term: *Term,
        phrase: *Phrase,
        set: *Set,
        range: *Range,
        all: u32,
        none,
        @"and": *And,
        @"or": []Iter,
        not: *Not,
        boost: *Boost,
    };

    /// Its first document at or past `target`; where it stands when that
    /// is there already.
    fn seek(it: *Iter, target: u32) Error!u32 {
        if (it.doc) |d| if (d >= target) return d;
        const d: u32 = switch (it.kind) {
            .term => |t| try t.seek(target),
            .phrase => |p| try p.seek(target),
            .set => |s| s.seek(target),
            .range => |r| try r.seek(target),
            .all => |docs| if (target < docs) target else done,
            .none => done,
            .@"and" => |a| try a.seek(target),
            .@"or" => |children| min: {
                var least: u32 = done;
                for (children) |*c| least = @min(least, try c.seek(target));
                break :min least;
            },
            .not => |n| try n.seek(target),
            .boost => |b| try b.child.seek(target),
        };
        it.doc = d;
        return d;
    }

    /// The score of the document it stands on.
    fn score(it: *const Iter) Error!f32 {
        return switch (it.kind) {
            .term => |t| t.score(),
            .phrase => |p| p.score(),
            .set, .range, .all, .not => 1,
            // Never stands on a document.
            .none => 0,
            .@"and" => |a| a.score(),
            .@"or" => |children| sum: {
                var sum: f32 = 0;
                for (children) |*c| if (c.doc == it.doc) {
                    sum += try c.score();
                };
                break :sum sum;
            },
            .boost => |b| (try b.child.score()) * b.by,
        };
    }

    /// The most it scores any document, raised past rounding (`wand.zig`).
    fn bound(it: *const Iter) f64 {
        return switch (it.kind) {
            .term => |t| wand.anywhere(t.weight),
            .phrase => |p| wand.anywhere(p.weight),
            // Exactly 1 in `f32`.
            .set, .range, .all, .not => 1,
            .none => 0,
            .@"and" => |a| if (a.positive.len == 0) 1 else boundOf(a.positive),
            .@"or" => |children| boundOf(children),
            .boost => |b| wand.boost(b.child.bound(), b.by),
        };
    }

    /// The most it scores a document from `target` to the returned `last`,
    /// raised past rounding: a term's from the impacts of its block holding
    /// `target`, any other's its bound anywhere.
    fn blockBound(it: *Iter, target: u32) Error!Block {
        return switch (it.kind) {
            .term => |t| t.blockBound(target),
            .boost => |b| {
                const c = try b.child.blockBound(target);
                return .{ .bound = wand.boost(c.bound, b.by), .last = c.last };
            },
            else => .{ .bound = it.bound(), .last = done - 1 },
        };
    }

    /// About how many documents it matches: what a conjunction leads by.
    fn cost(it: *const Iter) u64 {
        return switch (it.kind) {
            .term => |t| t.reader.docFreq(),
            .phrase => |p| p.leadCost(),
            .set => |s| s.count,
            .range => |r| r.segment.docs,
            .all => |docs| docs,
            .none => 0,
            .@"and" => |a| if (a.positive.len == 0) a.lead_all else a.positive[a.order[0]].cost(),
            .@"or" => |children| sum: {
                var sum: u64 = 0;
                for (children) |*c| sum += c.cost();
                break :sum sum;
            },
            .not => |n| n.docs,
            .boost => |b| b.child.cost(),
        };
    }
};

/// A bound on the scores of the documents up to `last`.
const Block = struct {
    bound: f64,
    last: u32,
};

/// The bound of a sum of `children`, in any order.
fn boundOf(children: []const Iter) f64 {
    var sum: f64 = 0;
    for (children) |*c| sum += c.bound();
    return wand.sum(sum, children.len);
}

/// A term's postings in a segment, and its positions when a phrase reads
/// them.
const Term = struct {
    run: *Run,
    segment: *const segment.read.Segment,
    place: u32,
    keyword: bool,
    weight: bm25.Weight,
    reader: postings.Reader,
    positions: ?positions.Reader,
    /// Blocks entered, as counted for the cancel check.
    counted: u32 = 0,
    /// The posting it stands on, null before the first.
    doc: ?u32 = null,
    freq: u32 = 0,
    /// The positions' chunk entered, and the place in it of the document
    /// whose positions are read next.
    chunk: ?u32 = null,
    next_place: u32 = 0,

    /// Its first posting's doc at or past `target`, or `done`: where it
    /// stands when that is there already, since the postings reader moves
    /// on from the posting it gave.
    fn seek(t: *Term, target: u32) Error!u32 {
        if (t.doc) |d| if (d >= target) return d;
        const p = try t.reader.advance(target);
        try t.run.entered(t.reader.entered - t.counted);
        t.counted = t.reader.entered;
        const posting = p orelse {
            t.doc = done;
            return done;
        };
        t.doc = posting.doc;
        t.freq = posting.freq;
        return posting.doc;
    }

    fn score(t: *const Term) f32 {
        return t.weight.score(@floatFromInt(t.freq), t.length());
    }

    /// The bound of its block holding the first doc at or past `target`,
    /// reached by skip entries alone; 0 when no doc is there.
    fn blockBound(t: *Term, target: u32) Error!Block {
        const found = try t.reader.shallow(target);
        try t.run.entered(t.reader.entered - t.counted);
        t.counted = t.reader.entered;
        if (!found) return .{ .bound = 0, .last = done - 1 };
        return .{ .bound = wand.block(t.weight, t.reader.impacts()), .last = t.reader.blockLast() };
    }

    fn length(t: *const Term) u32 {
        return if (t.keyword) 1 else t.segment.length(t.place, t.doc.?);
    }

    /// The positions of the document the term stands on, into `out`.
    fn positionsOf(t: *Term, gpa: Allocator, out: *std.ArrayList(u32)) Error!void {
        const r = &t.positions.?;
        const freqs = t.reader.blockFreqs();
        const block = t.reader.block();
        if (t.chunk != block) {
            var tokens: u64 = 0;
            for (freqs) |f| tokens += f;
            try r.enter(block, tokens);
            t.chunk = block;
            t.next_place = 0;
        }
        const at = t.reader.place();
        while (t.next_place < at) : (t.next_place += 1) try r.document(freqs[t.next_place]);
        try r.document(freqs[at]);
        t.next_place = at + 1;
        out.clearRetainingCapacity();
        while (try r.next()) |token| try out.append(gpa, token.position);
    }
};

/// A phrase: its terms in a segment, met by a conjunction, each document
/// then checked through their positions.
const Phrase = struct {
    gpa: Allocator,
    phrase: Tree.Phrase,
    weight: bm25.Weight,
    terms: []Term,
    /// The terms by cost, cheapest first.
    order: []usize,
    lists: []std.ArrayList(u32),
    views: [][]const u32,
    cursors: []usize,
    freq: f32 = 0,

    fn leadCost(p: *const Phrase) u64 {
        return p.terms[p.order[0]].reader.docFreq();
    }

    fn seek(p: *Phrase, target: u32) Error!u32 {
        var doc = target;
        while (true) {
            doc = try p.meet(doc);
            if (doc == done) return done;
            for (p.terms, p.lists, p.views) |*t, *list, *view| {
                try t.positionsOf(p.gpa, list);
                view.* = list.items;
            }
            p.freq = phrase.frequency(p.views, p.phrase.positions, p.phrase.slop, p.cursors);
            if (p.freq > 0) return doc;
            doc += 1;
        }
    }

    /// The first document at or past `target` holding every term.
    fn meet(p: *Phrase, target: u32) Error!u32 {
        const lead = &p.terms[p.order[0]];
        var doc = try lead.seek(target);
        again: while (doc != done) {
            for (p.order[1..]) |i| {
                const d = try p.terms[i].seek(doc);
                if (d != doc) {
                    doc = try lead.seek(d);
                    continue :again;
                }
            }
            return doc;
        }
        return done;
    }

    fn score(p: *const Phrase) f32 {
        return p.weight.score(p.freq, p.terms[0].length());
    }
};

/// A prefix's documents in a segment.
const Set = struct {
    words: []u64,
    count: u64,

    fn seek(s: *const Set, target: u32) u32 {
        var word = target / 64;
        if (word >= s.words.len) return done;
        var bits = s.words[word] & (~@as(u64, 0) << @intCast(target % 64));
        while (bits == 0) {
            word += 1;
            if (word == s.words.len) return done;
            bits = s.words[word];
        }
        return @intCast(word * 64 + @ctz(bits));
    }
};

/// A range over a segment's column.
const Range = struct {
    segment: *const segment.read.Segment,
    range: Tree.Range,
    cursor: columns.Cursor,

    fn seek(r: *Range, target: u32) Error!u32 {
        var doc = target;
        while (doc < r.segment.docs) {
            const block = doc / block_len;
            const b = r.cursor.column.bounds(block);
            if (b.max < r.range.min or b.min > r.range.max) {
                doc = (block + 1) * block_len;
                continue;
            }
            const v = try r.cursor.get(doc);
            if (v >= r.range.min and v <= r.range.max) return doc;
            doc += 1;
        }
        return done;
    }
};

const And = struct {
    /// The children that match, in the query's order, and the order they
    /// are met in, cheapest first.
    positive: []Iter,
    order: []usize,
    negative: []Iter,
    /// With no child that matches, every document of the segment leads.
    lead_all: u32,

    fn seek(a: *And, target: u32) Error!u32 {
        var doc = target;
        again: while (true) {
            if (a.positive.len == 0) {
                if (doc >= a.lead_all) return done;
            } else {
                doc = try a.positive[a.order[0]].seek(doc);
                if (doc == done) return done;
                for (a.order[1..]) |i| {
                    const d = try a.positive[i].seek(doc);
                    if (d != doc) {
                        doc = d;
                        continue :again;
                    }
                }
            }
            for (a.negative) |*n| {
                if (try n.seek(doc) == doc) {
                    doc += 1;
                    continue :again;
                }
            }
            return doc;
        }
    }

    fn score(a: *const And) Error!f32 {
        if (a.positive.len == 0) return 1;
        var sum: f32 = 0;
        for (a.positive) |*c| sum += try c.score();
        return sum;
    }
};

/// Every document of a segment its child does not match.
const Not = struct {
    child: Iter,
    docs: u32,

    fn seek(n: *Not, target: u32) Error!u32 {
        var doc = target;
        while (doc < n.docs) : (doc += 1) {
            if (try n.child.seek(doc) != doc) return doc;
        }
        return done;
    }
};

const Boost = struct {
    child: Iter,
    by: f32,
};

fn compileNode(r: *Run, seg: *const segment.read.Segment, plan: *const Plan) Error!Iter {
    const arena = r.segment_arena.allocator();
    return switch (plan.*) {
        .term => |t| {
            const term = try termOf(r, seg, t.term.field, t.term.bytes, t.weight, false) orelse return .{ .kind = .none };
            return .{ .kind = .{ .term = term } };
        },
        .phrase => |p| {
            const terms = try arena.alloc(Term, p.phrase.terms.len);
            for (p.phrase.terms, terms) |bytes, *t| {
                const one = try termOf(r, seg, p.phrase.field, bytes, p.weight, true) orelse return .{ .kind = .none };
                t.* = one.*;
            }
            const order = try arena.alloc(usize, terms.len);
            for (order, 0..) |*o, i| o.* = i;
            std.mem.sort(usize, order, terms, struct {
                fn lessThan(ts: []Term, a: usize, b: usize) bool {
                    return ts[a].reader.docFreq() < ts[b].reader.docFreq();
                }
            }.lessThan);
            const lists = try arena.alloc(std.ArrayList(u32), terms.len);
            @memset(lists, .empty);
            const ph = try arena.create(Phrase);
            ph.* = .{
                .gpa = arena,
                .phrase = p.phrase,
                .weight = p.weight,
                .terms = terms,
                .order = order,
                .lists = lists,
                .views = try arena.alloc([]const u32, terms.len),
                .cursors = try arena.alloc(usize, terms.len),
            };
            return .{ .kind = .{ .phrase = ph } };
        },
        .prefix => |t| try prefixOf(r, seg, t),
        .range => |range| {
            const it = try arena.create(Range);
            it.* = .{ .segment = seg, .range = range, .cursor = .init(seg.column(range.field)) };
            return .{ .kind = .{ .range = it } };
        },
        .all => .{ .kind = .{ .all = seg.docs } },
        .none => .{ .kind = .none },
        .@"and" => |children| {
            var negatives: usize = 0;
            for (children) |c| negatives += @intFromBool(c == .not);
            const a = try arena.create(And);
            a.* = .{
                .positive = try arena.alloc(Iter, children.len - negatives),
                .order = try arena.alloc(usize, children.len - negatives),
                .negative = try arena.alloc(Iter, negatives),
                .lead_all = seg.docs,
            };
            var p: usize = 0;
            var n: usize = 0;
            for (children) |*c| switch (c.*) {
                .not => |child| {
                    a.negative[n] = try compileNode(r, seg, child);
                    n += 1;
                },
                else => {
                    a.positive[p] = try compileNode(r, seg, c);
                    a.order[p] = p;
                    p += 1;
                },
            };
            std.mem.sort(usize, a.order, a.positive, struct {
                fn lessThan(its: []Iter, x: usize, y: usize) bool {
                    return its[x].cost() < its[y].cost();
                }
            }.lessThan);
            return .{ .kind = .{ .@"and" = a } };
        },
        .@"or" => |children| {
            const its = try arena.alloc(Iter, children.len);
            for (children, its) |*c, *it| it.* = try compileNode(r, seg, c);
            return .{ .kind = .{ .@"or" = its } };
        },
        .not => |child| {
            const n = try arena.create(Not);
            n.* = .{ .child = try compileNode(r, seg, child), .docs = seg.docs };
            return .{ .kind = .{ .not = n } };
        },
        .boost => |b| {
            const it = try arena.create(Boost);
            it.* = .{ .child = try compileNode(r, seg, b.plan), .by = b.by };
            return .{ .kind = .{ .boost = it } };
        },
    };
}

/// The term `bytes` of the field at `place` in `seg`, with its positions
/// when `positioned`, or null when the segment holds no such term there.
fn termOf(r: *Run, seg: *const segment.read.Segment, place: u32, bytes: []const u8, weight: bm25.Weight, positioned: bool) Error!?*Term {
    const reader = try seg.term(r.io, place, bytes) orelse return null;
    const t = try r.segment_arena.allocator().create(Term);
    t.* = .{
        .run = r,
        .segment = seg,
        .place = place,
        .keyword = r.schema[place].kind == .keyword,
        .weight = weight,
        .reader = reader.postings,
        .positions = if (positioned) reader.positions else null,
    };
    return t;
}

/// The documents of every term of the field at `t.field` in `seg` that
/// starts with `t.bytes`: at most `Limits.expansions` terms.
fn prefixOf(r: *Run, seg: *const segment.read.Segment, t: Tree.Term) Error!Iter {
    const arena = r.segment_arena.allocator();
    const field = try seg.dictionary.field(t.field) orelse return .{ .kind = .none };
    const key = try arena.alloc(u8, r.term_bytes);
    const frames = try arena.alloc(fst.Fst.Frame, key.len + 1);
    // Counted first, so a prefix past the limit reads no postings.
    var addresses: std.ArrayList(segment.terms.Address) = .empty;
    var walk = try field.keys.walk(t.bytes, key, frames);
    while (walk.next() catch return error.Corrupt) |entry| {
        if (addresses.items.len == r.limits.expansions) return error.TooManyTerms;
        try addresses.append(arena, try field.address(entry.value));
    }
    if (addresses.items.len == 0) return .{ .kind = .none };
    const set = try arena.create(Set);
    set.* = .{ .words = try arena.alloc(u64, (@as(usize, seg.docs) + 63) / 64), .count = 0 };
    @memset(set.words, 0);
    for (addresses.items) |address| {
        var p = try postings.Reader.init(seg.postings, r.io, address.postings, seg.docs);
        while (try p.next()) |posting| {
            const bit = @as(u64, 1) << @intCast(posting.doc % 64);
            const word = &set.words[posting.doc / 64];
            if (word.* & bit == 0) set.count += 1;
            word.* |= bit;
        }
        try r.entered(p.entered);
    }
    return .{ .kind = .{ .set = set } };
}
