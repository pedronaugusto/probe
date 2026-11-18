//! Queries against the exact reference (`testing/reference.zig`): over
//! snapshots of several segments with skewed statistics (a segment of long
//! documents beside one of short ones, a term common in one segment and
//! rare in the rest, documents deleted, updated and merged away, segments
//! added and merged between queries on a snapshot reopened), every
//! query's best hits equal the reference's bit for bit in score and order,
//! its count equals the reference's, and every score is within 1e-5 of
//! BM25 computed apart in `f64`. A phrase's frequency equals the one found
//! by trying every chain of positions. Over a segment whose sections are
//! damaged, every query answers within the segment or is `Corrupt`.
const std = @import("std");
const shakedown = @import("shakedown");
const Writer = @import("Writer.zig");
const Reader = @import("Reader.zig");
const Schema = @import("Schema.zig");
const Limits = @import("Limits.zig");
const query = @import("query.zig");
const Tree = query.Tree;
const exec = query.exec;
const phrase = query.phrase;
const Pipeline = @import("analysis/Pipeline.zig");
const segment = @import("segment.zig");
const Held = @import("Held.zig");
const reference = @import("testing/reference.zig");

const testing = std.testing;
const gen = shakedown.gen;
const io = testing.io;
const Node = Tree.Node;

const schema = [_]Schema.Field{
    .{ .name = "body", .kind = .text, .positions = true, .analysis = .words_and_identifiers, .bm25 = .{ .k1 = 0.9, .b = 0.4 } },
    .{ .name = "title", .kind = .text },
    .{ .name = "tag", .kind = .keyword },
    .{ .name = "n", .kind = .numeric },
    .{ .name = "serial", .kind = .keyword, .stored = true },
};
const body = 0;
const title = 1;
const tag = 2;
const n_field = 3;

const words = [_][]const u8{ "alpha", "beta", "gamma", "delta", "parseSpan", "x", "HTTPServer", "e2e", "omega" };
/// Terms a query asks for: words as folded, identifier parts, and one no
/// document holds.
const terms = [_][]const u8{ "alpha", "beta", "gamma", "delta", "parsespan", "parse", "span", "x", "httpserver", "http", "server", "e2e", "omega", "absent" };
const tags = [_][]const u8{ "a", "ab", "b", "abc" };
/// Regex term patterns, folded already (lowercase ASCII folds to itself), of
/// body's terms and of tag's: some match many terms, some one, some none.
const body_patterns = [_][]const u8{ "al.*", "(parse|span)", ".*ta", "x|e2e", "h.*r", "[a-d].*", "omegas?", ".*", "zz.*", "p.r.*" };
const tag_patterns = [_][]const u8{ "a.*", "ab?", "b|abc", "c", ".*" };

/// A version of a document as added.
const Version = struct {
    id: u64,
    body: []const u8,
    title: []const u8,
    tag: []const u8,
    n: u64,
};

fn text(arena: std.mem.Allocator, s: *shakedown.Source, len: usize, common: ?[]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..len) |_| {
        const w = if (common != null and gen.intRange(s, u8, 0, 2) == 0) common.? else words[gen.intRange(s, usize, 0, words.len - 1)];
        try out.appendSlice(arena, w);
        try out.append(arena, ' ');
    }
    return out.items;
}

fn add(w: *Writer, v: Version, serial: usize, update: bool) !void {
    var serial_buffer: [20]u8 = undefined;
    const serial_text = try std.mem.print(&serial_buffer, "{d}", .{serial});
    const values = [_]segment.write.Value{ .{ .text = v.body }, .{ .text = v.title }, .{ .keyword = v.tag }, .{ .numeric = v.n }, .{ .keyword = serial_text } };
    const doc: segment.write.Document = .{ .id = v.id, .values = &values };
    if (update) try w.update(io, doc) else try w.add(io, doc);
}

fn tokensOf(arena: std.mem.Allocator, comptime analysis: Schema.Analysis, t: []const u8) ![]const reference.Token {
    var buffer: [255]u8 = undefined;
    var p: Pipeline.Of(analysis) = .init(t, &buffer);
    var out: std.ArrayList(reference.Token) = .empty;
    while (p.next()) |tk| try out.append(arena, .{ .term = try arena.dupe(u8, tk.term), .position = tk.position });
    return out.items;
}

/// The snapshot `r` holds as the reference holds it.
fn referenceOf(arena: std.mem.Allocator, r: *const Reader, versions: []const Version) !reference.Snapshot {
    var docs: std.ArrayList(reference.Doc) = .empty;
    var buffer: std.ArrayList(u8) = .empty;
    for (r.segments, 0..) |*s, place| {
        for (0..s.docs()) |d| {
            const doc: u32 = @intCast(d);
            var stored: [1]segment.store.Value = undefined;
            try s.read().storedOf(io, arena, doc, &buffer, &stored);
            const v = versions[try std.fmt.parseInt(usize, stored[0].bytes, 10)];
            const values = try arena.alloc(reference.Value, schema.len);
            values[body] = .{ .text = try tokensOf(arena, .words_and_identifiers, v.body) };
            values[title] = .{ .text = try tokensOf(arena, .words, v.title) };
            values[tag] = .{ .keyword = v.tag };
            values[n_field] = .{ .numeric = v.n };
            values[4] = .{ .keyword = try arena.dupe(u8, stored[0].bytes) };
            try docs.append(arena, .{ .segment = @intCast(place), .doc = doc, .deleted = s.isDeleted(doc), .values = values });
        }
    }
    return .init(arena, &schema, docs.items);
}

fn termOf(s: *shakedown.Source) []const u8 {
    return terms[gen.intRange(s, usize, 0, terms.len - 1)];
}

fn queryOf(arena: std.mem.Allocator, s: *shakedown.Source, depth: u8) !Node {
    const leaf = depth == 0 or gen.intRange(s, u8, 0, 2) != 0;
    if (leaf) return switch (gen.intRange(s, u8, 0, 9)) {
        0, 1 => .{ .term = .{ .field = body, .bytes = termOf(s) } },
        2 => .{ .term = .{ .field = title, .bytes = termOf(s) } },
        3 => .{ .term = .{ .field = tag, .bytes = tags[gen.intRange(s, usize, 0, tags.len - 1)] } },
        4, 5 => p: {
            const len = gen.intRange(s, usize, 1, 3);
            const ts = try arena.alloc([]const u8, len);
            const ps = try arena.alloc(u32, len);
            var at: u32 = gen.intRange(s, u32, 0, 3);
            for (ts, ps) |*t, *p| {
                t.* = termOf(s);
                p.* = at;
                at += gen.intRange(s, u32, 1, 2);
            }
            break :p .{ .phrase = .{ .field = body, .terms = ts, .positions = ps, .slop = gen.intRange(s, u32, 0, 3) } };
        },
        6 => switch (gen.intRange(s, u8, 0, 3)) {
            0 => p: {
                const t = termOf(s);
                break :p .{ .prefix = .{ .field = body, .bytes = t[0..gen.intRange(s, usize, 0, @min(t.len, 2))] } };
            },
            1 => .{ .prefix = .{ .field = tag, .bytes = "ab"[0..gen.intRange(s, usize, 0, 2)] } },
            // A regex term: the walk prunes by the automaton, the reference searches every term.
            2 => .{ .regex = .{ .field = body, .pattern = body_patterns[gen.intRange(s, usize, 0, body_patterns.len - 1)], .fold = true } },
            else => .{ .regex = .{ .field = tag, .pattern = tag_patterns[gen.intRange(s, usize, 0, tag_patterns.len - 1)], .fold = false } },
        },
        7 => r: {
            const a = gen.intRange(s, u64, 0, 1000);
            break :r .{ .range = .{ .field = n_field, .min = a, .max = a + gen.intRange(s, u64, 0, 400) } };
        },
        8 => .all,
        else => .none,
    };
    return switch (gen.intRange(s, u8, 0, 3)) {
        0, 1 => |kind| b: {
            const children = try arena.alloc(Node, gen.intRange(s, usize, 1, 4));
            for (children) |*c| c.* = try queryOf(arena, s, depth - 1);
            break :b if (kind == 0) .{ .@"and" = children } else .{ .@"or" = children };
        },
        2 => b: {
            const child = try arena.create(Node);
            child.* = try queryOf(arena, s, depth - 1);
            break :b .{ .not = child };
        },
        else => b: {
            const child = try arena.create(Node);
            child.* = try queryOf(arena, s, depth - 1);
            break :b .{ .boost = .{ .node = child, .by = ([_]f32{ 0, 0.5, 1.5, 2 })[gen.intRange(s, usize, 0, 3)] } };
        },
    };
}

/// Fills `w` with up to `segments` commits of up to `docs` documents each,
/// each segment of its own lengths and its own common word, with updates,
/// deletes and merges among them; every version added is in `versions`.
fn fill(w: *Writer, arena: std.mem.Allocator, s: *shakedown.Source, versions: *std.ArrayList(Version), segments: usize, docs: usize) !void {
    for (0..gen.intRange(s, usize, 1, segments)) |i| {
        // The first segment short, the second long: their average lengths
        // differ tenfold at least.
        const long = switch (i) {
            0 => gen.intRange(s, usize, 1, 3),
            1 => gen.intRange(s, usize, 30, 40),
            else => gen.intRange(s, usize, 1, 40),
        };
        const common: ?[]const u8 = if (gen.boolean(s)) words[gen.intRange(s, usize, 0, words.len - 1)] else null;
        for (0..gen.intRange(s, usize, 1, docs)) |_| {
            const update = versions.items.len > 0 and gen.intRange(s, u8, 0, 5) == 0;
            const v: Version = .{
                .id = if (update) versions.items[gen.intRange(s, usize, 0, versions.items.len - 1)].id else versions.items.len + 1000,
                .body = try text(arena, s, gen.intRange(s, usize, 0, long), common),
                .title = try text(arena, s, gen.intRange(s, usize, 0, 3), null),
                .tag = tags[gen.intRange(s, usize, 0, tags.len - 1)],
                .n = gen.intRange(s, u64, 0, 1500),
            };
            try add(w, v, versions.items.len, update);
            try versions.append(arena, v);
        }
        if (gen.intRange(s, u8, 0, 2) == 0) try w.delete(versions.items[gen.intRange(s, usize, 0, versions.items.len - 1)].id);
        _ = try w.commit(io);
        if (gen.intRange(s, u8, 0, 3) == 0) _ = try w.mergeStep(io, null);
    }
}

const merging: Writer.Options = .{ .durability = .none, .merge = .{ .segments_per_tier = 2, .max_merge_at_once = 2, .floor_bytes = 1 } };

/// The search's best `top` hits of `root` equal the reference's bit for
/// bit, each within 1e-5 of BM25 in `f64`; what the search did.
fn expectHits(r: *const Reader, ref: reference.Snapshot, root: *const Node, top: u32, wand: bool) !exec.Report {
    const gpa = testing.allocator;
    var report: exec.Report = .{};
    const got = try exec.search(gpa, io, r, root, .{ .top = top, .wand = wand, .report = &report });
    defer gpa.free(got);
    const want = try ref.search(gpa, root, top);
    defer gpa.free(want);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |a, b| {
        try testing.expectEqual(a.segment, b.segment);
        try testing.expectEqual(a.doc, b.doc);
        try testing.expectEqual(@as(u32, @bitCast(a.score)), @as(u32, @bitCast(b.score)));
        const exact = (try ref.score64(gpa, root, ref.find(b.segment, b.doc))).?;
        try testing.expect(@abs(@as(f64, b.score) - exact) <= 1e-5 * @abs(exact));
    }
    return report;
}

/// The page after the reference's hit `k` is the reference's hits from
/// `k + 1` on.
fn expectPage(r: *const Reader, ref: reference.Snapshot, root: *const Node, top: u32, wand: bool, k: u32) !void {
    const gpa = testing.allocator;
    const want = try ref.search(gpa, root, k + 1 + top);
    defer gpa.free(want);
    if (want.len <= k) return;
    const got = try exec.search(gpa, io, r, root, .{ .top = top, .wand = wand, .after = want[k] });
    defer gpa.free(got);
    const rest = want[k + 1 ..];
    try testing.expectEqual(rest.len, got.len);
    for (rest, got) |a, b| {
        try testing.expectEqual(a.segment, b.segment);
        try testing.expectEqual(a.doc, b.doc);
        try testing.expectEqual(@as(u32, @bitCast(a.score)), @as(u32, @bitCast(b.score)));
    }
}

fn matchesReference(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = try .open(gpa, io, tmp.dir, &schema, merging);
    defer w.deinit(io);
    var versions: std.ArrayList(Version) = .empty;
    try fill(&w, arena, s, &versions, 4, 60);
    var r = try Reader.open(gpa, io, tmp.dir, &schema, .{});
    defer r.deinit();
    const before = try referenceOf(arena, &r, versions.items);
    try expectQueries(arena, s, &r, before);
    // Segments added and merged between queries: the snapshot reopened
    // answers by its own statistics, none older, and the one before by
    // its own still.
    try fill(&w, arena, s, &versions, 3, 60);
    var reopened = try r.reopen(io);
    defer reopened.deinit();
    try expectQueries(arena, s, &reopened, try referenceOf(arena, &reopened, versions.items));
    try expectQueries(arena, s, &r, before);
}

/// Queries of every shape over `r`, each equal to the reference's: its
/// best hits, top 1000 among them, a page after one of them, its count.
fn expectQueries(arena: std.mem.Allocator, s: *shakedown.Source, r: *const Reader, ref: reference.Snapshot) !void {
    const gpa = testing.allocator;
    for (0..8) |_| {
        const root = try queryOf(arena, s, 3);
        try Tree.check(&root, &schema, .{});
        const top = if (gen.intRange(s, u8, 0, 3) == 0) 1000 else gen.intRange(s, u32, 1, 50);
        const wand = gen.boolean(s);
        _ = try expectHits(r, ref, &root, top, wand);
        try expectPage(r, ref, &root, top, wand, gen.intRange(s, u32, 0, 20));
        try testing.expectEqual(try ref.count(gpa, &root), try exec.count(gpa, io, r, &root, .{}));
    }
}

test "every query's best hits equal the exact reference's bit for bit, over snapshots of skewed segments" {
    try shakedown.check(testing.allocator, {}, matchesReference, .{ .seed = 0x7175_6572, .cases = 150 });
}

/// What every block-max WAND run of the property passed unscored, and
/// scored.
var wand_skipped: u64 = 0;
var wand_scored: u64 = 0;
var exhaustive_scored: u64 = 0;

/// A disjunction of clauses WAND bounds: terms of each field, boosted at
/// times, a phrase, a prefix.
fn disjunctionOf(arena: std.mem.Allocator, s: *shakedown.Source) !Node {
    const children = try arena.alloc(Node, gen.intRange(s, usize, 2, 5));
    for (children) |*c| {
        c.* = switch (gen.intRange(s, u8, 0, 5)) {
            0, 1 => .{ .term = .{ .field = body, .bytes = termOf(s) } },
            2 => .{ .term = .{ .field = title, .bytes = termOf(s) } },
            3 => b: {
                const child = try arena.create(Node);
                child.* = .{ .term = .{ .field = body, .bytes = termOf(s) } };
                break :b .{ .boost = .{ .node = child, .by = ([_]f32{ 0.5, 1.5, 3 })[gen.intRange(s, usize, 0, 2)] } };
            },
            4 => .{ .term = .{ .field = tag, .bytes = tags[gen.intRange(s, usize, 0, tags.len - 1)] } },
            else => try queryOf(arena, s, 0),
        };
    }
    return .{ .@"or" = children };
}

fn wandMatches(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = try .open(gpa, io, tmp.dir, &schema, merging);
    defer w.deinit(io);
    var versions: std.ArrayList(Version) = .empty;
    // Segments long enough that a term's postings pass several blocks.
    try fill(&w, arena, s, &versions, 3, 500);
    var r = try Reader.open(gpa, io, tmp.dir, &schema, .{});
    defer r.deinit();
    const ref = try referenceOf(arena, &r, versions.items);
    for (0..6) |_| {
        const root = try disjunctionOf(arena, s);
        try Tree.check(&root, &schema, .{});
        const top = gen.intRange(s, u32, 1, 10);
        const pruned = try expectHits(&r, ref, &root, top, true);
        const every = try expectHits(&r, ref, &root, top, false);
        wand_skipped += pruned.skipped;
        wand_scored += pruned.scored;
        exhaustive_scored += every.scored;
    }
}

test "block-max WAND gives the hits of every document scored, bit for bit, and passes blocks unscored" {
    wand_skipped = 0;
    wand_scored = 0;
    exhaustive_scored = 0;
    try shakedown.check(testing.allocator, {}, wandMatches, .{ .seed = 0x7761_6e64, .cases = 30 });
    // The bounds pruned: stretches were passed, and fewer documents scored.
    // Measured: 4,789 stretches passed, 13,098 documents scored of 38,894
    // (14 s in Debug on macOS).
    try testing.expect(wand_skipped > 0);
    try testing.expect(wand_scored < exhaustive_scored);
}

fn phraseMatchesReference(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const vocabulary = [_][]const u8{ "a", "b", "c" };
    var tokens: std.ArrayList(reference.Token) = .empty;
    var position: u32 = 0;
    for (0..gen.intRange(s, usize, 0, 30)) |_| {
        // At times two tokens share a position, as an identifier's whole
        // word and its first part do.
        if (gen.intRange(s, u8, 0, 4) != 0) position += 1;
        try tokens.append(arena, .{ .term = vocabulary[gen.intRange(s, usize, 0, 2)], .position = position });
    }
    const len = gen.intRange(s, usize, 1, 4);
    const ts = try arena.alloc([]const u8, len);
    const ps = try arena.alloc(u32, len);
    var at: u32 = 0;
    for (ts, ps) |*t, *p| {
        t.* = vocabulary[gen.intRange(s, usize, 0, 2)];
        p.* = at;
        at += gen.intRange(s, u32, 1, 3);
    }
    const p: Tree.Phrase = .{ .field = 0, .terms = ts, .positions = ps, .slop = gen.intRange(s, u32, 0, 6) };
    const lists = try arena.alloc([]const u32, len);
    for (ts, lists) |t, *list| {
        var l: std.ArrayList(u32) = .empty;
        for (tokens.items) |tk| if (std.mem.eql(u8, tk.term, t)) try l.append(arena, tk.position);
        list.* = l.items;
    }
    const cursors = try arena.alloc(usize, len);
    const got = phrase.frequency(lists, ps, p.slop, cursors);
    const want = try reference.phraseFrequency(gpa, tokens.items, p);
    try testing.expectEqual(@as(u32, @bitCast(want)), @as(u32, @bitCast(got)));
}

test "a phrase's frequency takes each start's shortest match, as trying every chain finds it" {
    try shakedown.check(testing.allocator, {}, phraseMatchesReference, .{ .seed = 0x7068_7261, .cases = 2000 });
}

test "a phrase counts each exact occurrence once and a looser one by its extra length" {
    const lists = [_][]const u32{ &.{ 0, 4, 9 }, &.{ 1, 6, 10 } };
    var cursors: [2]usize = undefined;
    // "a b" at 0 and at 9 exactly, at 4 two positions longer.
    try testing.expectEqual(@as(f32, 2), phrase.frequency(&lists, &.{ 0, 1 }, 0, &cursors));
    try testing.expectEqual(@as(f32, 2 + 1.0 / 2.0), phrase.frequency(&lists, &.{ 0, 1 }, 1, &cursors));
}

test "a prefix past the expansions is TooManyTerms before any postings are read" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = try .open(gpa, io, tmp.dir, &schema, .{ .durability = .none });
    defer w.deinit(io);
    try add(&w, .{ .id = 1, .body = "pa pb pc pd", .title = "", .tag = "a", .n = 0 }, 0, false);
    _ = try w.commit(io);
    var r = try Reader.open(gpa, io, tmp.dir, &schema, .{});
    defer r.deinit();
    const root: Node = .{ .prefix = .{ .field = body, .bytes = "p" } };
    try testing.expectError(error.TooManyTerms, exec.count(gpa, io, &r, &root, .{ .expansions = 3 }));
    try testing.expectEqual(@as(u64, 1), try exec.count(gpa, io, &r, &root, .{ .expansions = 4 }));
}

test "a query outside its schema or limits is refused" {
    const limits: Limits = .{ .clauses = 3, .depth = 2 };
    const ok: Node = .{ .term = .{ .field = body, .bytes = "a" } };
    try Tree.check(&ok, &schema, limits);
    try testing.expectError(error.Invalid, Tree.check(&.{ .term = .{ .field = n_field, .bytes = "a" } }, &schema, limits));
    try testing.expectError(error.Invalid, Tree.check(&.{ .term = .{ .field = 9, .bytes = "a" } }, &schema, limits));
    try testing.expectError(error.Invalid, Tree.check(&.{ .phrase = .{ .field = title, .terms = &.{"a"}, .positions = &.{0} } }, &schema, limits));
    try testing.expectError(error.Invalid, Tree.check(&.{ .phrase = .{ .field = body, .terms = &.{ "a", "b" }, .positions = &.{ 1, 1 } } }, &schema, limits));
    try testing.expectError(error.Invalid, Tree.check(&.{ .range = .{ .field = tag, .min = 0, .max = 1 } }, &schema, limits));
    try testing.expectError(error.Invalid, Tree.check(&.{ .boost = .{ .node = &ok, .by = std.math.nan(f32) } }, &schema, limits));
    try testing.expectError(error.TooManyClauses, Tree.check(&.{ .@"or" = &.{ ok, ok, ok } }, &schema, limits));
    const inner: Node = .{ .not = &ok };
    try testing.expectError(error.TooDeep, Tree.check(&.{ .not = &inner }, &schema, limits));
}

test "block-max WAND passes a block that cannot beat the best held, and scores the first document past it" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = try .open(gpa, io, tmp.dir, &schema, .{ .durability = .none });
    defer w.deinit(io);
    // "alpha" once in each document, three times in doc 5 of the first
    // block, four times in doc 256, the first of the third: the second
    // block's bound is below doc 5's score, and the block ends at 255.
    for (0..400) |d| {
        const body_text = switch (d) {
            5 => "alpha alpha alpha",
            256 => "alpha alpha alpha alpha",
            else => "alpha",
        };
        try add(&w, .{ .id = d, .body = body_text, .title = "", .tag = "a", .n = 0 }, d, false);
    }
    _ = try w.commit(io);
    var r = try Reader.open(gpa, io, tmp.dir, &schema, .{});
    defer r.deinit();
    const root: Node = .{ .@"or" = &.{ .{ .term = .{ .field = body, .bytes = "alpha" } }, .{ .term = .{ .field = body, .bytes = "absent" } } } };
    var report: exec.Report = .{};
    const hits = try exec.search(gpa, io, &r, &root, .{ .top = 1, .report = &report });
    defer gpa.free(hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqual(@as(u32, 256), hits[0].doc);
    try testing.expect(report.skipped > 0);
    try testing.expect(report.scored < 400);
}

/// What every block-max conjunction run of the property passed unscored,
/// and scored.
var conjunction_skipped: u64 = 0;
var conjunction_scored: u64 = 0;
var conjunction_exhaustive: u64 = 0;

/// A conjunction of required clauses, terms of each field boosted at
/// times, with an excluded one at times.
fn conjunctionOf(arena: std.mem.Allocator, s: *shakedown.Source) !Node {
    const children = try arena.alloc(Node, gen.intRange(s, usize, 2, 4));
    for (children) |*c| {
        c.* = switch (gen.intRange(s, u8, 0, 5)) {
            0, 1, 2 => .{ .term = .{ .field = body, .bytes = termOf(s) } },
            3 => b: {
                const child = try arena.create(Node);
                child.* = .{ .term = .{ .field = body, .bytes = termOf(s) } };
                break :b .{ .boost = .{ .node = child, .by = ([_]f32{ 0.5, 1.5, 3 })[gen.intRange(s, usize, 0, 2)] } };
            },
            4 => .{ .term = .{ .field = title, .bytes = termOf(s) } },
            else => n: {
                const child = try arena.create(Node);
                child.* = .{ .term = .{ .field = tag, .bytes = tags[gen.intRange(s, usize, 0, tags.len - 1)] } };
                break :n .{ .not = child };
            },
        };
    }
    return .{ .@"and" = children };
}

fn conjunctionMatches(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = try .open(gpa, io, tmp.dir, &schema, merging);
    defer w.deinit(io);
    var versions: std.ArrayList(Version) = .empty;
    try fill(&w, arena, s, &versions, 3, 500);
    var r = try Reader.open(gpa, io, tmp.dir, &schema, .{});
    defer r.deinit();
    const ref = try referenceOf(arena, &r, versions.items);
    for (0..6) |_| {
        const root = try conjunctionOf(arena, s);
        try Tree.check(&root, &schema, .{});
        const top = gen.intRange(s, u32, 1, 10);
        const pruned = try expectHits(&r, ref, &root, top, true);
        const every = try expectHits(&r, ref, &root, top, false);
        try expectPage(&r, ref, &root, top, true, gen.intRange(s, u32, 0, 5));
        conjunction_skipped += pruned.skipped;
        conjunction_scored += pruned.scored;
        conjunction_exhaustive += every.scored;
    }
}

test "the block-max conjunction gives the hits of every match scored, bit for bit, and passes blocks unscored" {
    conjunction_skipped = 0;
    conjunction_scored = 0;
    conjunction_exhaustive = 0;
    try shakedown.check(testing.allocator, {}, conjunctionMatches, .{ .seed = 0x636f_6e6a, .cases = 30 });
    // Measured: 230 windows passed, 9,781 matches scored of 10,273 (8 s in
    // Debug on macOS): random terms rarely leave a block below the bar.
    try testing.expect(conjunction_skipped > 0);
    try testing.expect(conjunction_scored < conjunction_exhaustive);
}

test "the block-max conjunction passes a window that cannot beat the best held, and scores the first document past it" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = try .open(gpa, io, tmp.dir, &schema, .{ .durability = .none });
    defer w.deinit(io);
    // "alpha beta" in every document, more of each in doc 5 and still more
    // in doc 256, the first of the third block: the second block's bound
    // is below doc 5's score, and the window ends at 255.
    for (0..400) |d| {
        const body_text = switch (d) {
            5 => "alpha alpha alpha beta",
            256 => "alpha alpha alpha beta beta",
            else => "alpha beta",
        };
        try add(&w, .{ .id = d, .body = body_text, .title = "", .tag = "a", .n = 0 }, d, false);
    }
    _ = try w.commit(io);
    var r = try Reader.open(gpa, io, tmp.dir, &schema, .{});
    defer r.deinit();
    const root: Node = .{ .@"and" = &.{ .{ .term = .{ .field = body, .bytes = "alpha" } }, .{ .term = .{ .field = body, .bytes = "beta" } } } };
    var report: exec.Report = .{};
    const hits = try exec.search(gpa, io, &r, &root, .{ .top = 1, .report = &report });
    defer gpa.free(hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqual(@as(u32, 256), hits[0].doc);
    const every = try exec.search(gpa, io, &r, &root, .{ .top = 1, .wand = false });
    defer gpa.free(every);
    try testing.expectEqual(every[0].doc, hits[0].doc);
    try testing.expect(report.skipped > 0);
    try testing.expect(report.scored < 400);
}

/// What the damaged segment fuzz saw: segments refused when read, and
/// queries answered or refused over the ones that read.
var damaged_refused: u64 = 0;
var damaged_answered: u64 = 0;
var damaged_corrupt: u64 = 0;

/// A segment's sections with 1 to 4 bytes changed, most often in the
/// postings, which a reader reads as they are asked for and checks only
/// as it reads them.
fn damage(s: *shakedown.Source, file: []u8, sections: segment.files.Sections) void {
    const section: segment.files.Section = switch (gen.intRange(s, u8, 0, 9)) {
        0...5 => .postings,
        6 => .terms,
        7 => .lengths,
        8 => .columns,
        else => .store,
    };
    const body_bytes = sections[@backingInt(section)];
    if (body_bytes.len == 0) return;
    const start = @intFromPtr(body_bytes.ptr) - @intFromPtr(file.ptr);
    for (0..gen.intRange(s, usize, 1, 4)) |_| {
        const at = start + gen.intRange(s, usize, 0, body_bytes.len - 1);
        file[at] ^= gen.intRange(s, u8, 1, 255);
    }
}

/// A phrase of two to four terms of the body, which reads their
/// positions.
fn phraseOf(arena: std.mem.Allocator, s: *shakedown.Source) !Node {
    const len = gen.intRange(s, usize, 2, 4);
    const ts = try arena.alloc([]const u8, len);
    const ps = try arena.alloc(u32, len);
    for (ts, ps, 0..) |*t, *p, i| {
        t.* = termOf(s);
        p.* = @intCast(i);
    }
    return .{ .phrase = .{ .field = body, .terms = ts, .positions = ps, .slop = gen.intRange(s, u32, 0, 12) } };
}

fn damagedSegment(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var builder: segment.write.Builder = try .init(gpa, &schema, 255);
    defer builder.deinit();
    const common = words[gen.intRange(s, usize, 0, words.len - 1)];
    for (0..gen.intRange(s, usize, 1, 500)) |d| {
        var serial_buffer: [20]u8 = undefined;
        const values = [_]segment.write.Value{
            .{ .text = try text(arena, s, gen.intRange(s, usize, 0, 12), common) },
            .{ .text = try text(arena, s, gen.intRange(s, usize, 0, 3), null) },
            .{ .keyword = tags[gen.intRange(s, usize, 0, tags.len - 1)] },
            .{ .numeric = gen.intRange(s, u64, 0, 1500) },
            .{ .keyword = try std.mem.print(&serial_buffer, "{d}", .{d}) },
        };
        _ = try builder.add(.{ .id = d, .values = &values });
    }
    var clean = try builder.finish(1);
    defer clean.deinit(gpa);
    for (0..16) |_| try queryDamaged(s, arena, try clean.clone(gpa), builder.docs);
}

/// Queries over the segment `owned` holds, damaged first; `owned` is freed
/// here.
fn queryDamaged(s: *shakedown.Source, arena: std.mem.Allocator, owned: std.ArrayList(u8), docs: u32) !void {
    const gpa = testing.allocator;
    var file = owned;
    var file_owned = true;
    defer if (file_owned) file.deinit(gpa);
    const e: segment.files.Expected = .{ .kind = .segment, .segment = 1 };
    const sections = try e.checkSegment(.init(file.items));
    damage(s, file.items, sections);
    var seg = segment.read.Segment.parse(gpa, io, segment.read.inMemory(sections), &schema, 1 << 20) catch |err| switch (err) {
        error.Corrupt => {
            damaged_refused += 1;
            return;
        },
        else => |other| return other,
    };
    var seg_owned = true;
    defer if (seg_owned) seg.deinit(gpa);
    var held: Held.Handle = try .create(gpa, .{ .gpa = gpa, .io = io, .number = 1, .docs = docs, .from = .{ .memory = .{ .file = file, .segment = seg } } });
    file_owned = false;
    seg_owned = false;
    defer held.release();
    var segments = [_]Reader.Segment{.{ .held = held, .deleted = null, .deleted_count = 0, .deletions = .none }};
    const r: Reader = .{ .gpa = gpa, .dir = .of(std.Io.Dir.cwd()), .schema = &schema, .options = .{}, .generation = 1, .segments = &segments };
    for (0..4) |_| {
        const root = switch (gen.intRange(s, u8, 0, 3)) {
            0 => try queryOf(arena, s, 3),
            1 => try disjunctionOf(arena, s),
            2 => try conjunctionOf(arena, s),
            else => try phraseOf(arena, s),
        };
        const order: exec.Order = if (gen.intRange(s, u8, 0, 3) == 0) .{ .column = .{ .field = n_field, .descending = gen.boolean(s) } } else .score;
        const options: exec.Options = .{ .top = gen.intRange(s, u32, 1, 50), .order = order, .wand = gen.boolean(s) };
        if (exec.search(gpa, io, &r, &root, options)) |hits| {
            defer gpa.free(hits);
            damaged_answered += 1;
            for (hits) |h| try testing.expect(h.segment == 0 and h.doc < docs);
        } else |err| switch (err) {
            error.Corrupt => damaged_corrupt += 1,
            error.TooManyTerms => {},
            else => |other| return other,
        }
        if (exec.count(gpa, io, &r, &root, .{})) |n| {
            try testing.expect(n <= docs);
        } else |err| switch (err) {
            error.Corrupt, error.TooManyTerms => {},
            else => |other| return other,
        }
    }
}

test "fuzz: queries over a damaged segment answer within it or are Corrupt, never more" {
    damaged_refused = 0;
    damaged_answered = 0;
    damaged_corrupt = 0;
    try shakedown.check(testing.allocator, {}, damagedSegment, .{ .seed = 0x6461_6d67, .cases = 150 });
    // Every outcome was reached: a segment refused, a query refused, one answered.
    try testing.expect(damaged_refused > 0 and damaged_corrupt > 0 and damaged_answered > 0);
}
