//! Snapshots beside a writer that commits and merges, inside a shakedown
//! `Sim` with airlock's calls routed onto its disk: `explore` runs each
//! scenario once for every schedule within its preemptions. The writer
//! keeps one commit, so the files of the one before are removed as the next
//! lands, while a reader opens the newest. The reader opens without error
//! (a manifest whose files went is read again), holds exactly its commit's
//! documents, and holds them still once the writer is done; a snapshot
//! opened before the writer began holds its own through every removal.
//! A snapshot searched beside the writer, which removes the files the
//! search reads, gives the hits and count it gave before the writer began,
//! bit for bit, and gives them still once the writer is done.
//!
//! The writer commits at durability `.none`: what is proved here is what a
//! reader sees beside it, and the crash sweeps prove the syncs. Its calls
//! are what the search interleaves the reader's with, so fewer of them is a
//! search that ends.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const shakedown = @import("shakedown");
const seam = @import("airlock.testing");
const airlock = @import("airlock");
const Writer = @import("Writer.zig");
const Reader = @import("Reader.zig");
const Schema = @import("Schema.zig");
const segment = @import("segment.zig");
const snapshots = @import("reader_test.zig");
const query = @import("query.zig");
const exec = query.exec;

const os = builtin.target.os.tag;
/// The simulated disk's names, as this platform's file systems compare them.
const names: @FieldType(shakedown.Sim.Fs.Options, "names") = if (os.isDarwin()) .darwin else if (os == .windows) .windows else .posix;

const schema = [_]Schema.Field{
    .{ .name = "body", .kind = .text, .positions = true },
    .{ .name = "serial", .kind = .keyword, .stored = true },
};

const Doc = snapshots.Doc;

/// What the writer does while the reader opens.
const Scenario = enum {
    /// A commit that deletes every document of the first, which leaves the
    /// manifest with its segment, so its file is removed.
    commit,
    /// A merge that writes the segment of the first commit again without
    /// the document the second deleted, which removes its files.
    merge,
};

/// What each commit of `scenario` holds, by generation.
fn wanted(scenario: Scenario, generation: u64) ?[]const Doc {
    const first: []const Doc = &.{ .{ .id = 1, .serial = 0 }, .{ .id = 2, .serial = 1 } };
    return switch (scenario) {
        .commit => switch (generation) {
            1 => first,
            2 => &.{.{ .id = 3, .serial = 2 }},
            else => null,
        },
        .merge => switch (generation) {
            1 => first,
            2, 3 => &.{.{ .id = 2, .serial = 1 }},
            else => null,
        },
    };
}

const options: Writer.Options = .{ .keep_commits = 1, .durability = .none, .merge = .{ .segments_per_tier = 2, .max_merge_at_once = 2 } };

/// Each document's body, by serial: scores that differ, and a phrase in one.
const bodies = [_][]const u8{ "alpha beta", "alpha gamma alpha", "beta" };

fn add(w: *Writer, io: Io, id: u64, serial: u32) !void {
    var serial_text: [10]u8 = undefined;
    const values = [_]segment.write.Value{ .{ .text = bodies[serial] }, .{ .keyword = try std.mem.print(&serial_text, "{d}", .{serial}) } };
    try w.add(io, .{ .id = id, .values = &values });
}

/// `r` holds exactly the documents of its commit.
fn expectCommit(r: *const Reader, io: Io, scenario: Scenario) !void {
    const want = wanted(scenario, r.generation) orelse return error.NoSuchCommit;
    var held: std.ArrayList(Doc) = .empty;
    defer held.deinit(testing.allocator);
    try snapshots.holds(r, io, testing.allocator, &held);
    if (want.len != held.items.len) return error.NotItsCommit;
    for (want, held.items) |a, b| if (!std.meta.eql(a, b)) return error.NotItsCommit;
}

fn open(io: Io, dir: Io.Dir, scenario: Scenario) !Reader {
    var r = try Reader.open(testing.allocator, io, dir, &schema, .{});
    errdefer r.deinit();
    try expectCommit(&r, io, scenario);
    return r;
}

/// The most times a reader of any run read the manifest again.
var most_retried: std.atomic.Value(u8) = .init(0);

fn run(io: Io, scenario: Scenario) !void {
    const h = try seam.Seam.create(testing.allocator, io, .{ .trace = .off });
    defer h.destroy();
    const hooked = h.io();
    _ = try airlock.makePath(hooked, Io.Dir.cwd(), "index", .{});
    const dir = try Io.Dir.cwd().openDir(hooked, "index", .{ .iterate = true });
    defer dir.close(hooked);
    var w: Writer = try .open(testing.allocator, hooked, dir, &schema, options);
    defer w.deinit(hooked);
    for ([_]u64{ 1, 2 }, 0..) |id, serial| try add(&w, hooked, id, @intCast(serial));
    _ = try w.commit(hooked);
    var before = try open(hooked, dir, scenario);
    defer before.deinit();
    if (scenario == .merge) {
        try w.delete(1);
        _ = try w.commit(hooked);
    }
    const last: u64 = if (scenario == .merge) 3 else 2;
    {
        var reader = try hooked.concurrent(open, .{ hooked, dir, scenario });
        var awaited = false;
        defer if (!awaited) {
            if (reader.cancel(hooked)) |r| {
                var opened = r;
                opened.deinit();
            } else |err| std.log.debug("task cleanup: {t}", .{err});
        };
        switch (scenario) {
            .commit => {
                for ([_]u64{ 1, 2 }) |id| try w.delete(id);
                try add(&w, hooked, 3, 2);
                _ = try w.commit(hooked);
            },
            .merge => if (try w.mergeStep(hooked, null) == null) return error.NoMerge,
        }
        awaited = true;
        var r = try reader.await(hooked);
        defer r.deinit();
        _ = most_retried.fetchMax(r.retried, .monotonic);
        // Its commit's files may be gone from the directory now: the
        // snapshot holds them still.
        try expectCommit(&r, hooked, scenario);
        var newest = try r.reopen(hooked);
        defer newest.deinit();
        try testing.expectEqual(last, newest.generation);
        try expectCommit(&newest, hooked, scenario);
    }
    try testing.expectEqual(@as(u64, 1), before.generation);
    try expectCommit(&before, hooked, scenario);
}

/// A query whose search reads postings and positions from the segment
/// files as it goes.
const searched_for: query.Tree.Node = .{ .@"or" = &.{
    .{ .term = .{ .field = 0, .bytes = "alpha" } },
    .{ .phrase = .{ .field = 0, .terms = &.{ "alpha", "beta" }, .positions = &.{ 0, 1 }, .slop = 0 } },
} };

/// What a snapshot answers: its best hits and its count.
const Answer = struct { hits: []exec.Hit, count: u64 };

fn answer(io: Io, r: *const Reader) !Answer {
    const hits = try exec.search(testing.allocator, io, r, &searched_for, .{});
    errdefer testing.allocator.free(hits);
    return .{ .hits = hits, .count = try exec.count(testing.allocator, io, r, &searched_for, .{}) };
}

/// `got` is `want`, every hit bit for bit.
fn expectSame(want: Answer, got: Answer) !void {
    if (want.count != got.count or want.hits.len != got.hits.len) return error.AnswerChanged;
    for (want.hits, got.hits) |a, b| {
        if (a.segment != b.segment or a.doc != b.doc or @as(u32, @bitCast(a.score)) != @as(u32, @bitCast(b.score))) return error.AnswerChanged;
    }
}

/// Whether the run's search has answered; and how many runs its search
/// was still going when the writer had removed the files it reads.
var search_done: std.atomic.Value(bool) = .init(false);
var searches_outlived: std.atomic.Value(u32) = .init(0);

fn searchBeside(io: Io, r: *const Reader, want: *const Answer) !void {
    defer search_done.store(true, .release);
    const got = try answer(io, r);
    defer testing.allocator.free(got.hits);
    try expectSame(want.*, got);
}

/// A snapshot searched while the writer removes the files it reads gives
/// the answer it gave before the writer began, and gives it still once the
/// writer is done.
fn runSearch(io: Io, scenario: Scenario) !void {
    const h = try seam.Seam.create(testing.allocator, io, .{ .trace = .off });
    defer h.destroy();
    const hooked = h.io();
    _ = try airlock.makePath(hooked, Io.Dir.cwd(), "index", .{});
    const dir = try Io.Dir.cwd().openDir(hooked, "index", .{ .iterate = true });
    defer dir.close(hooked);
    var w: Writer = try .open(testing.allocator, hooked, dir, &schema, options);
    defer w.deinit(hooked);
    for ([_]u64{ 1, 2 }, 0..) |id, serial| try add(&w, hooked, id, @intCast(serial));
    _ = try w.commit(hooked);
    var before = try open(hooked, dir, scenario);
    defer before.deinit();
    const want = try answer(hooked, &before);
    defer testing.allocator.free(want.hits);
    // Both documents, the one holding the phrase first.
    if (want.count != 2 or want.hits.len != 2 or want.hits[0].doc != 0) return error.NotTheAnswer;
    if (scenario == .merge) {
        try w.delete(1);
        _ = try w.commit(hooked);
    }
    {
        search_done.store(false, .release);
        var search = try hooked.concurrent(searchBeside, .{ hooked, &before, &want });
        var awaited = false;
        defer if (!awaited) search.cancel(hooked) catch |err| std.log.debug("task cleanup: {t}", .{err});
        switch (scenario) {
            .commit => {
                for ([_]u64{ 1, 2 }) |id| try w.delete(id);
                try add(&w, hooked, 3, 2);
                _ = try w.commit(hooked);
            },
            .merge => if (try w.mergeStep(hooked, null) == null) return error.NoMerge,
        }
        if (!search_done.load(.acquire)) _ = searches_outlived.fetchAdd(1, .monotonic);
        awaited = true;
        try search.await(hooked);
    }
    const after = try answer(hooked, &before);
    defer testing.allocator.free(after.hits);
    try expectSame(want, after);
    // The newest commit answers for itself: document 1 is gone, and in the
    // commit scenario document 2 with it.
    var newest = try before.reopen(hooked);
    defer newest.deinit();
    try testing.expectEqual(@as(u64, if (scenario == .merge) 1 else 0), try exec.count(testing.allocator, hooked, &newest, &searched_for, .{}));
}

/// A proof: what the writer does, and whether a reader opens or a snapshot
/// searches beside it.
const Proof = struct { scenario: Scenario, search: bool };

fn body(proof: Proof, c: *shakedown.Case) anyerror!void {
    const sim = try c.sim(.{ .fs = .{ .names = names }, .executor = .threads });
    const outcome = if (proof.search) sim.run(runSearch, .{ sim.io(), proof.scenario }) else sim.run(run, .{ sim.io(), proof.scenario });
    switch (outcome) {
        .finished => {},
        .failed => |err| return err,
        else => return error.Unfinished,
    }
}

fn explore(proof: Proof, preemptions: u8) !void {
    most_retried.store(0, .monotonic);
    searches_outlived.store(0, .monotonic);
    const searched = try shakedown.explore(testing.allocator, proof, body, .{ .preemptions = preemptions, .max_runs = 100_000 });
    try testing.expect(searched.complete);
    try testing.expect(searched.runs > 1);
    // Some order removed a file the reader's manifest named before it
    // opened it: the reader read the newest manifest again.
    if (!proof.search) try testing.expect(most_retried.load(.monotonic) > 0);
    // Some order had the search still reading once the writer had removed
    // the files it reads.
    if (proof.search) try testing.expect(searches_outlived.load(.monotonic) > 0);
}

// Measured on macOS: the commit's search is 1,305 runs, the merge's 1,670,
// each a few tens of seconds in Debug, inside the watchdog with room. With
// a search beside them, 2,342 runs and 2,792, about a minute each; in all
// but a few dozen the search was still reading when the writer had removed
// the files it reads.
test "a reader opening beside a commit that removes the segment its manifest named holds one commit whole, in every order within two preemptions" {
    try explore(.{ .scenario = .commit, .search = false }, 2);
}

test "a reader opening beside a merge that removes its sources holds one commit whole, in every order within two preemptions" {
    try explore(.{ .scenario = .merge, .search = false }, 2);
}

test "a snapshot searched beside a commit that removes the segment it reads answers as before, in every order within two preemptions" {
    try explore(.{ .scenario = .commit, .search = true }, 2);
}

test "a snapshot searched beside a merge that removes its sources answers as before, in every order within two preemptions" {
    try explore(.{ .scenario = .merge, .search = true }, 2);
}
