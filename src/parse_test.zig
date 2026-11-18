//! The query language: what each form reads as, where and why a query does
//! not read, any bytes read without harm (a tree of the schema within the
//! limits, or an error at a byte inside the text), any tree printed in the
//! language read back as itself, and a query's words meeting the indexed
//! text through the same analysis.
const std = @import("std");
const shakedown = @import("shakedown");
const query = @import("query.zig");
const Schema = @import("Schema.zig");
const Limits = @import("Limits.zig");
const Writer = @import("Writer.zig");
const Reader = @import("Reader.zig");
const segment = @import("segment.zig");

const testing = std.testing;
const gen = shakedown.gen;
const io = testing.io;
const Tree = query.Tree;
const parse = query.parse;
const Node = Tree.Node;

const schema = [_]Schema.Field{
    .{ .name = "body", .kind = .text, .positions = true, .analysis = .words_and_identifiers },
    .{ .name = "title", .kind = .text },
    .{ .name = "level", .kind = .keyword },
    .{ .name = "n", .kind = .numeric },
    .{ .name = "at", .kind = .numeric, .signed = true },
    .{ .name = "path", .kind = .keyword },
};
const body = 0;
const title = 1;
const level = 2;
const n_field = 3;
const at_field = 4;
const path = 5;

fn read(text: []const u8, options: parse.Options) parse.Error!Tree {
    return parse.parse(testing.allocator, &schema, .init(text), options);
}

fn equal(a: *const Node, b: *const Node) bool {
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
    return switch (a.*) {
        .term => |t| t.field == b.term.field and std.mem.eql(u8, t.bytes, b.term.bytes),
        .prefix => |t| t.field == b.prefix.field and std.mem.eql(u8, t.bytes, b.prefix.bytes),
        .regex => |x| x.field == b.regex.field and x.fold == b.regex.fold and std.mem.eql(u8, x.pattern, b.regex.pattern),
        .phrase => |p| p.field == b.phrase.field and p.slop == b.phrase.slop and std.mem.eql(u32, p.positions, b.phrase.positions) and p.terms.len == b.phrase.terms.len and for (p.terms, b.phrase.terms) |x, y| {
            if (!std.mem.eql(u8, x, y)) break false;
        } else true,
        .range => |r| std.meta.eql(r, b.range),
        .all, .none => true,
        .@"and", .@"or" => |children| {
            const other = if (a.* == .@"and") b.@"and" else b.@"or";
            if (children.len != other.len) return false;
            for (children, other) |*x, *y| if (!equal(x, y)) return false;
            return true;
        },
        .not => |child| equal(child, b.not),
        .boost => |x| x.by == b.boost.by and equal(x.node, b.boost.node),
    };
}

fn expectReads(text: []const u8, want: Node) !void {
    var t = try read(text, .{});
    defer t.deinit();
    if (!equal(&t.root, &want)) {
        std.debug.print("{s}: read as {any}\n", .{ text, t.root });
        return error.TestUnexpectedResult;
    }
}

fn term(field: u32, bytes: []const u8) Node {
    return .{ .term = .{ .field = field, .bytes = bytes } };
}

/// A word in the default fields, the text ones.
fn anyText(bytes: []const u8) Node {
    return .{ .@"or" = &.{ term(body, bytes), term(title, bytes) } };
}

test "each form of the language reads as its tree" {
    try expectReads("", .none);
    try expectReads("   ", .none);
    try expectReads("Alpha", anyText("alpha"));
    try expectReads("body:alpha", term(body, "alpha"));
    try expectReads("level:ERR", term(level, "ERR"));
    try expectReads("body:alpha body:beta", .{ .@"and" = &.{ term(body, "alpha"), term(body, "beta") } });
    try expectReads("body:alpha AND body:beta", .{ .@"and" = &.{ term(body, "alpha"), term(body, "beta") } });
    try expectReads("body:alpha OR body:beta level:x", .{ .@"or" = &.{ term(body, "alpha"), .{ .@"and" = &.{ term(body, "beta"), term(level, "x") } } } });
    try expectReads("-body:alpha", .{ .not = &term(body, "alpha") });
    try expectReads("NOT body:alpha", .{ .not = &term(body, "alpha") });
    try expectReads("body:(alpha OR beta)", .{ .@"or" = &.{ term(body, "alpha"), term(body, "beta") } });
    try expectReads("body:alpha^2.5", .{ .boost = .{ .node = &term(body, "alpha"), .by = 2.5 } });
    try expectReads("body:\"Segment merge\"~2", .{ .phrase = .{ .field = body, .terms = &.{ "segment", "merge" }, .positions = &.{ 0, 1 }, .slop = 2 } });
    // An identifier is the phrase of its parts, which find it whole.
    try expectReads("body:parseSpan", .{ .phrase = .{ .field = body, .terms = &.{ "parse", "span" }, .positions = &.{ 0, 1 } } });
    // Without positions, all of the parts.
    try expectReads("title:max-bytes", .{ .@"and" = &.{ term(title, "max"), term(title, "bytes") } });
    try expectReads("body:Pars*", .{ .prefix = .{ .field = body, .bytes = "pars" } });
    try expectReads("level:src/*", .{ .prefix = .{ .field = level, .bytes = "src/" } });
    try expectReads("level:\"two words\"", term(level, "two words"));
    try expectReads("n:[10 TO *]", .{ .range = .{ .field = n_field, .min = 10, .max = std.math.maxInt(u64) } });
    try expectReads("n:7", .{ .range = .{ .field = n_field, .min = 7, .max = 7 } });
    try expectReads("at:[-5 TO 5]", .{ .range = .{ .field = at_field, .min = Schema.columnValue(@as(i64, -5)), .max = Schema.columnValue(@as(i64, 5)) } });
    try expectReads("*", .all);
    try expectReads("*:*", .all);
    try expectReads("level:a\\:b\\*", term(level, "a:b*"));
    // The design's example: a phrase in the default fields that keep
    // positions, a level, a path prefix, a word excluded.
    try expectReads("\"segment merge\" level:err path:src/* -test", .{ .@"and" = &.{
        .{ .phrase = .{ .field = body, .terms = &.{ "segment", "merge" }, .positions = &.{ 0, 1 } } },
        term(level, "err"),
        .{ .prefix = .{ .field = path, .bytes = "src/" } },
        .{ .not = &anyText("test") },
    } });
    // Words that analyze to nothing leave no clause.
    try expectReads("body:!!! body:alpha", term(body, "alpha"));
}

fn expectFails(text: []const u8, err: parse.Error, offset: usize, problem: parse.Problem) !void {
    var d: parse.Diagnostic = .{};
    try testing.expectError(err, read(text, .{ .diagnostic = &d, .limits = .{ .clauses = 8, .depth = 4 } }));
    try testing.expectEqual(offset, d.offset);
    try testing.expectEqual(problem, d.problem);
}

test "a query that does not read says where and why" {
    try expectFails("body:\"open", error.Invalid, 5, .unclosed_quote);
    try expectFails("(alpha", error.Invalid, 0, .unclosed_group);
    try expectFails("alpha)", error.Invalid, 5, .unexpected);
    try expectFails("nope:alpha", error.Invalid, 0, .unknown_field);
    try expectFails("title:\"a b\"", error.Invalid, 6, .wrong_kind);
    try expectFails("level:[1 TO 2]", error.Invalid, 6, .wrong_kind);
    try expectFails("n:abc", error.Invalid, 2, .bad_number);
    try expectFails("n:-1", error.Invalid, 2, .bad_number);
    try expectFails("n:[1 TO 2", error.Invalid, 2, .unclosed_range);
    try expectFails("body:alpha^x", error.Invalid, 11, .bad_number);
    try expectFails("OR alpha", error.Invalid, 0, .unexpected);
    try expectFails("alpha OR", error.Invalid, 8, .unexpected);
    try expectFails("((((((alpha))))))", error.TooDeep, 4, .too_deep);
    const many = "level:a level:b level:c level:d level:e level:f level:g level:h level:i";
    try expectFails(many, error.TooManyClauses, many.len, .too_many_clauses);
}

/// Any bytes read as a tree of the schema within the limits, or as an
/// error whose diagnostic lies inside the text.
fn readsAnyBytes(_: void, case: *shakedown.Case) anyerror!void {
    var buffer: [96]u8 = undefined;
    // Bytes of the language's alphabet often, any bytes at times.
    const alphabet = "abAB:\"()*^~-\\[]TO ORANDNOT 0129.,bodytitlelevelnat";
    const len = gen.intRange(case.source, usize, 0, buffer.len);
    for (buffer[0..len]) |*b| b.* = if (gen.intRange(case.source, u8, 0, 7) == 0) gen.int(case.source, u8) else alphabet[gen.intRange(case.source, usize, 0, alphabet.len - 1)];
    const limits: Limits = .{ .clauses = 12, .depth = 5 };
    var d: parse.Diagnostic = .{ .offset = std.math.maxInt(usize) };
    if (read(buffer[0..len], .{ .limits = limits, .diagnostic = &d })) |t| {
        var tree = t;
        defer tree.deinit();
        try Tree.check(&tree.root, &schema, limits);
    } else |err| switch (err) {
        error.OutOfMemory => return err,
        else => try testing.expect(d.offset <= len),
    }
}

test "any bytes read as a tree of the schema within the limits, or fail at a byte inside them" {
    try shakedown.check(testing.allocator, {}, readsAnyBytes, .{ .seed = 0x7061_7273, .cases = 20_000 });
}

const vocabulary = [_][]const u8{ "alpha", "beta", "gamma", "x" };

/// A tree the language prints: terms, phrases, prefixes and ranges in
/// their fields, joined by `and`, `or`, `not` and boosts, no join of one.
fn treeOf(arena: std.mem.Allocator, s: *shakedown.Source, depth: u8) !Node {
    if (depth == 0 or gen.intRange(s, u8, 0, 2) == 0) return switch (gen.intRange(s, u8, 0, 5)) {
        0 => term(([_]u32{ body, title })[gen.intRange(s, usize, 0, 1)], vocabulary[gen.intRange(s, usize, 0, vocabulary.len - 1)]),
        1 => term(level, ([_][]const u8{ "ERR", "a:b", "x y", "q*" })[gen.intRange(s, usize, 0, 3)]),
        2 => p: {
            const len = gen.intRange(s, usize, 2, 3);
            const ts = try arena.alloc([]const u8, len);
            const ps = try arena.alloc(u32, len);
            for (ts, ps, 0..) |*t, *p, i| {
                t.* = vocabulary[gen.intRange(s, usize, 0, vocabulary.len - 1)];
                p.* = @intCast(i);
            }
            break :p .{ .phrase = .{ .field = body, .terms = ts, .positions = ps, .slop = gen.intRange(s, u32, 0, 3) } };
        },
        3 => .{ .prefix = .{ .field = ([_]u32{ body, level })[gen.intRange(s, usize, 0, 1)], .bytes = vocabulary[gen.intRange(s, usize, 0, vocabulary.len - 1)] } },
        4 => .{ .range = .{ .field = n_field, .min = gen.intRange(s, u64, 0, 9), .max = gen.intRange(s, u64, 10, 99) } },
        else => .all,
    };
    return switch (gen.intRange(s, u8, 0, 3)) {
        0, 1 => |kind| j: {
            const children = try arena.alloc(Node, gen.intRange(s, usize, 2, 3));
            for (children) |*c| c.* = try treeOf(arena, s, depth - 1);
            break :j if (kind == 0) .{ .@"and" = children } else .{ .@"or" = children };
        },
        2 => n: {
            const child = try arena.create(Node);
            child.* = try treeOf(arena, s, depth - 1);
            break :n .{ .not = child };
        },
        else => b: {
            const child = try arena.create(Node);
            child.* = try treeOf(arena, s, depth - 1);
            break :b .{ .boost = .{ .node = child, .by = ([_]f32{ 0.5, 1.5, 2 })[gen.intRange(s, usize, 0, 2)] } };
        },
    };
}

/// `node` in the language, each join in parentheses.
fn print(out: *std.Io.Writer, node: *const Node) !void {
    switch (node.*) {
        .term => |t| {
            try out.print("{s}:", .{schema[t.field].name});
            for (t.bytes) |c| {
                if (c == ':' or c == '*' or c == ' ') try out.writeByte('\\');
                try out.writeByte(c);
            }
        },
        .prefix => |t| try out.print("{s}:{s}*", .{ schema[t.field].name, t.bytes }),
        .regex => |x| {
            try out.print("{s}:/", .{schema[x.field].name});
            for (x.pattern) |c| {
                if (c == '/') try out.writeByte('\\');
                try out.writeByte(c);
            }
            try out.writeByte('/');
        },
        .phrase => |p| {
            try out.print("{s}:\"", .{schema[p.field].name});
            for (p.terms, 0..) |t, i| try out.print("{s}{s}", .{ if (i > 0) " " else "", t });
            try out.print("\"~{d}", .{p.slop});
        },
        .range => |r| try out.print("n:[{d} TO {d}]", .{ r.min, r.max }),
        .all => try out.writeAll("*"),
        .none => unreachable,
        .@"and", .@"or" => |children| {
            try out.writeByte('(');
            for (children, 0..) |*c, i| {
                if (i > 0) try out.writeAll(if (node.* == .@"and") " AND " else " OR ");
                try print(out, c);
            }
            try out.writeByte(')');
        },
        .not => |child| {
            try out.writeAll("-");
            try print(out, child);
        },
        .boost => |b| {
            try out.writeByte('(');
            try print(out, b.node);
            try out.print(")^{d}", .{b.by});
        },
    }
}

fn readsBack(_: void, case: *shakedown.Case) anyerror!void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const want = try treeOf(arena_state.allocator(), case.source, 3);
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try print(&text.writer, &want);
    var got = try read(text.written(), .{});
    defer got.deinit();
    // A boost of a join reads as the join boosted; one of a leaf likewise.
    if (!equal(&got.root, &want)) {
        std.debug.print("{s}\n", .{text.written()});
        return error.TestUnexpectedResult;
    }
}

test "any tree printed in the language reads back as itself" {
    try shakedown.check(testing.allocator, {}, readsBack, .{ .seed = 0x6261_636b, .cases = 3000 });
}

test "a query's words meet the indexed text through the same analysis" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = try .open(gpa, io, tmp.dir, &schema, .{ .durability = .none });
    defer w.deinit(io);
    const texts = [_][]const u8{ "we call parseSpan here", "parse the span", "a parse span" };
    for (texts, 0..) |t, id| {
        const values = [_]segment.write.Value{ .{ .text = t }, .{ .text = "" }, .{ .keyword = "INFO" }, .{ .numeric = @intCast(id) }, .{ .numeric = 0 }, .{ .keyword = "src/a.zig" } };
        try w.add(io, .{ .id = @intCast(id), .values = &values });
    }
    _ = try w.commit(io);
    var r = try Reader.open(gpa, io, tmp.dir, &schema, .{});
    defer r.deinit();
    const cases = [_]struct { text: []const u8, count: u64 }{
        // The identifier and the two words side by side, not apart.
        .{ .text = "parseSpan", .count = 2 },
        .{ .text = "\"parse span\"", .count = 2 },
        .{ .text = "\"parse span\"~1", .count = 3 },
        .{ .text = "parse span", .count = 3 },
        .{ .text = "pars* -level:INFO", .count = 0 },
        .{ .text = "n:[1 TO 2]", .count = 2 },
    };
    for (cases) |c| {
        var t = try read(c.text, .{});
        defer t.deinit();
        try testing.expectEqual(c.count, try query.exec.count(gpa, io, &r, &t.root, .{}));
    }
}
