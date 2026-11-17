//! Snapshots beside a writer that commits and merges, inside a shakedown
//! `Sim` with airlock's calls routed onto its disk: `explore` runs each
//! scenario once for every schedule within its preemptions. The writer
//! keeps one commit, so the files of the one before are removed as the next
//! lands, while a reader opens the newest. The reader opens without error
//! (a manifest whose files went is read again), holds exactly its commit's
//! documents, and holds them still once the writer is done; a snapshot
//! opened before the writer began holds its own through every removal.
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

fn add(w: *Writer, io: Io, id: u64, serial: u32) !void {
    var serial_text: [10]u8 = undefined;
    const values = [_]segment.write.Value{ .{ .text = "alpha" }, .{ .keyword = try std.mem.print(&serial_text, "{d}", .{serial}) } };
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

fn body(scenario: Scenario, c: *shakedown.Case) anyerror!void {
    const sim = try c.sim(.{ .fs = .{ .names = names }, .executor = .threads });
    switch (sim.run(run, .{ sim.io(), scenario })) {
        .finished => {},
        .failed => |err| return err,
        else => return error.Unfinished,
    }
}

fn explore(scenario: Scenario, preemptions: u8) !void {
    most_retried.store(0, .monotonic);
    const searched = try shakedown.explore(testing.allocator, scenario, body, .{ .preemptions = preemptions, .max_runs = 100_000 });
    try testing.expect(searched.complete);
    try testing.expect(searched.runs > 1);
    // Some order removed a file the reader's manifest named before it
    // opened it: the reader read the newest manifest again.
    try testing.expect(most_retried.load(.monotonic) > 0);
}

// Measured on macOS: the commit's search is 1,305 runs, the merge's 1,670,
// each a few tens of seconds in Debug, inside the watchdog with room.
test "a reader opening beside a commit that removes the segment its manifest named holds one commit whole, in every order within two preemptions" {
    try explore(.commit, 2);
}

test "a reader opening beside a merge that removes its sources holds one commit whole, in every order within two preemptions" {
    try explore(.merge, 2);
}
