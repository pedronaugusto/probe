//! Regex term queries, as a program writes them: on a text field the
//! pattern reads the terms as the field folds its text (NFKC_Casefold), so a
//! term indexed from `ÉCOLE` is found by `/école/` and `/ÉCOLE/` alike, a
//! Greek or Cyrillic word by either case, `ß` as the `ss` it folds to and a
//! fullwidth word as its ASCII; on a keyword field it reads the bytes as
//! they are. A pattern that does not read is `invalid_pattern`, and one
//! built in code finds what its text finds.
const std = @import("std");
const aegis = @import("aegis");
const probe = @import("probe.zig");

const testing = std.testing;
const io = testing.io;

const Note = struct {
    seq: aegis.id.Id(Note, u64),
    words: []const u8,
    code: []const u8,
    n: i64,

    pub const probe = .{
        .id = .seq,
        .fields = .{
            .words = .{ .text = .{} },
            .code = .{ .keyword = .{} },
            .n = .{ .numeric = .{} },
        },
    };
};

const Index = probe.Index(Note);

const notes = [_]Note{
    .{ .seq = .fromRaw(1), .words = "ÉCOLE normale", .code = "A-1", .n = 1 },
    .{ .seq = .fromRaw(2), .words = "Straße Berlin", .code = "a-2", .n = 2 },
    .{ .seq = .fromRaw(3), .words = "ΣΟΦΙΑ Ζεύς", .code = "B-3", .n = 3 },
    .{ .seq = .fromRaw(4), .words = "ＡＢＣ wide", .code = "x/y", .n = 4 },
    .{ .seq = .fromRaw(5), .words = "ЖУРНАЛ печать", .code = "b-5", .n = 5 },
};

fn opened(dir: std.Io.Dir) !*Index.Reader {
    const w = try Index.openWriter(testing.allocator, io, dir, .{ .durability = .none });
    defer w.deinit(io);
    for (notes) |note| try w.add(io, note);
    var result = try w.commit(io);
    var generation: u64 = undefined;
    result.take(&generation);
    return Index.openReader(testing.allocator, io, dir, .{});
}

/// The notes `q` finds, by seq, ascending.
fn found(r: *Index.Reader, q: *Index.Query, out: []u64) ![]u64 {
    var hits = try r.search(io, q, .{});
    defer hits.deinit();
    for (hits.hits, out[0..hits.hits.len]) |h, *o| o.* = h.id.raw();
    const seqs = out[0..hits.hits.len];
    std.mem.sort(u64, seqs, {}, std.sort.asc(u64));
    return seqs;
}

fn expectFinds(r: *Index.Reader, text: []const u8, want: []const u64) !void {
    var q = try Index.Query.parse(testing.allocator, .init(text), .{});
    defer q.deinit();
    var buffer: [notes.len]u64 = undefined;
    testing.expectEqualSlices(u64, want, try found(r, &q, &buffer)) catch |err| {
        std.debug.print("query {s}\n", .{text});
        return err;
    };
}

test "a text field's pattern folds as its terms do: either case, ß as ss, fullwidth as ASCII" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try opened(tmp.dir);
    defer r.deinit();
    try expectFinds(r, "/école/", &.{1});
    try expectFinds(r, "/ÉCOLE/", &.{1});
    try expectFinds(r, "words:/éc.*/", &.{1});
    try expectFinds(r, "/[ÉE]cole/", &.{1});
    // Greek: Σ, σ and ς fold alike.
    try expectFinds(r, "/σοφια/", &.{3});
    try expectFinds(r, "/ΣΟΦΙΑ/", &.{3});
    try expectFinds(r, "/ζεύς/", &.{3});
    // Cyrillic, both ways.
    try expectFinds(r, "/журнал/", &.{5});
    try expectFinds(r, "/ПЕЧАТЬ/", &.{5});
    // ß folds to ss, which simple folding alone would not find.
    try expectFinds(r, "/straße/", &.{2});
    try expectFinds(r, "/strasse/", &.{2});
    try expectFinds(r, "/ＡＢＣ/", &.{4});
    try expectFinds(r, "/abc/", &.{4});
    // A pattern matches a term whole.
    try expectFinds(r, "/col/", &.{});
    try expectFinds(r, "/.*e.*/", &.{ 1, 2, 4 });
}

test "a keyword field's pattern reads its bytes as they are" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try opened(tmp.dir);
    defer r.deinit();
    try expectFinds(r, "code:/[ab]-\\d/", &.{ 2, 5 });
    try expectFinds(r, "code:/A-1/", &.{1});
    try expectFinds(r, "code:/a-1/", &.{});
    try expectFinds(r, "code:/x\\/y/", &.{4});
    try expectFinds(r, "code:/[AB]-.|x.y/ -/school/", &.{ 1, 3, 4 });
}

test "a pattern that does not read, or on a numeric field, is refused where it stands" {
    for ([_]struct { []const u8, probe.QueryProblem, usize }{
        .{ "/a(b/", .invalid_pattern, 0 },
        .{ "words:/abc", .invalid_pattern, 6 },
        .{ "code:/[z-a]/", .invalid_pattern, 5 },
        .{ "n:/1/", .wrong_kind, 2 },
    }) |case| {
        var diagnostic: probe.QueryDiagnostic = .{};
        try testing.expectError(error.Invalid, Index.Query.parse(testing.allocator, .init(case[0]), .{ .diagnostic = &diagnostic }));
        try testing.expectEqual(case[1], diagnostic.problem);
        try testing.expectEqual(case[2], diagnostic.offset);
    }
}

test "a pattern built in code finds what its text finds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try opened(tmp.dir);
    defer r.deinit();
    var b: Index.Query.Builder = .init(testing.allocator);
    defer b.deinit();
    var q = try b.build(try b.@"or"(&.{ try b.regex(.words, "ÉCOLE"), try b.regex(.code, "B-.") }));
    defer q.deinit();
    var buffer: [notes.len]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{ 1, 3 }, try found(r, &q, &buffer));
    try testing.expectError(error.Invalid, b.regex(.words, "("));
}
