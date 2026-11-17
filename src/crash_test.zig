//! Every crash of a writer's commits, inside a shakedown `Sim`: airlock's
//! syncs and renames routed onto its simulated disk, a power loss at every
//! step of a run of three commits, and every state the disk could come back
//! in. After each, a writer opens the index as a program restarting would,
//! removing what the crash left, and the index is checked for what a
//! commit promises: it holds exactly the documents of one commit, no older
//! than the last that returned and no newer than the one under way, and no
//! temporary file is left.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const shakedown = @import("shakedown");
const seam = @import("airlock.testing");
const airlock = @import("airlock");
const Seam = seam.Seam;
const Writer = @import("Writer.zig");
const Schema = @import("Schema.zig");
const segment = @import("segment.zig");

const os = builtin.target.os.tag;

/// The simulated disk's names, as this platform's file systems compare them.
const names: @FieldType(shakedown.Sim.Fs.Options, "names") = if (os.isDarwin()) .darwin else if (os == .windows) .windows else .posix;

const schema = [_]Schema.Field{
    .{ .name = "body", .kind = .text, .positions = true },
    .{ .name = "serial", .kind = .keyword, .stored = true },
};

/// A document: its id and the serial that tells it apart.
const Doc = struct { id: u64, serial: u8 };

/// What the index holds after each commit, sorted: none before the first.
const commits = [_][]const Doc{
    &.{},
    &.{ .{ .id = 1, .serial = 0 }, .{ .id = 2, .serial = 1 }, .{ .id = 3, .serial = 2 } },
    &.{ .{ .id = 1, .serial = 0 }, .{ .id = 3, .serial = 2 }, .{ .id = 4, .serial = 3 } },
    &.{ .{ .id = 1, .serial = 4 }, .{ .id = 3, .serial = 2 }, .{ .id = 4, .serial = 3 }, .{ .id = 5, .serial = 5 } },
};

/// The index's directory, made durably: its name synced into its parent, as
/// a program gives the writer a directory a crash cannot lose.
fn makeDir(io: Io) !Io.Dir {
    _ = try airlock.makePath(io, Io.Dir.cwd(), "index", .{});
    return Io.Dir.cwd().openDir(io, "index", .{ .iterate = true });
}

/// The index's directory after a crash, or null if the crash came before
/// it was made.
fn openDir(io: Io) !?Io.Dir {
    return Io.Dir.cwd().openDir(io, "index", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

fn add(w: *Writer, io: Io, id: u64, serial: u8, update: bool) !void {
    const serial_text = [1]u8{'0' + serial};
    const values = [_]segment.write.Value{ .{ .text = "alpha beta" }, .{ .keyword = &serial_text } };
    const doc: segment.write.Document = .{ .id = id, .values = &values };
    if (update) try w.update(io, doc) else try w.add(io, doc);
}

pub const Operation = struct {
    h: ?*Seam = null,
    /// What a run allocates: a crash abandons its tasks with their defers
    /// unrun, so what the writer held is given back here.
    arena: std.heap.ArenaAllocator = .init(testing.allocator),
    /// The commits that returned before the crash.
    acknowledged: usize = 0,

    pub fn setUp(s: *Operation, sim: *shakedown.Sim) !void {
        s.h = try Seam.create(testing.allocator, sim.io(), .{ .trace = .off });
        s.arena = .init(testing.allocator);
        s.acknowledged = 0;
    }

    pub fn tearDown(s: *Operation) void {
        if (s.h) |h| h.destroy();
        s.h = null;
        s.arena.deinit();
    }

    pub fn run(s: *Operation, base: Io) !void {
        _ = base;
        const io = s.h.?.io();
        const dir = try makeDir(io);
        defer dir.close(io);
        var w: Writer = try .open(s.arena.allocator(), io, dir, &schema, .{});
        defer w.deinit(io);
        for ([_]u64{ 1, 2, 3 }, 0..) |id, serial| try add(&w, io, id, @intCast(serial), false);
        _ = try w.commit(io);
        s.acknowledged = 1;
        try add(&w, io, 4, 3, false);
        try w.delete(2);
        _ = try w.commit(io);
        s.acknowledged = 2;
        try add(&w, io, 1, 4, true);
        try add(&w, io, 5, 5, false);
        _ = try w.commit(io);
        s.acknowledged = 3;
    }

    /// A program restarting: a writer opens the index, which removes what
    /// the crash left.
    pub fn recover(s: *Operation, io: Io) !void {
        _ = s;
        const h = try Seam.create(testing.allocator, io, .{ .trace = .off });
        defer h.destroy();
        const dir = (try openDir(h.io())) orelse return;
        defer dir.close(h.io());
        var w: Writer = try .open(testing.allocator, h.io(), dir, &schema, .{});
        w.deinit(h.io());
    }

    pub fn check(s: *Operation, io: Io) !void {
        const h = try Seam.create(testing.allocator, io, .{ .trace = .off });
        defer h.destroy();
        const hooked = h.io();
        const dir = (try openDir(hooked)) orelse {
            if (s.acknowledged > 0) return error.NotACommit;
            return;
        };
        defer dir.close(hooked);
        var it = dir.iterate();
        while (try it.next(hooked)) |entry| {
            if (std.mem.startsWith(u8, entry.name, Writer.temp_prefix)) return error.TempLeft;
        }
        var w: Writer = try .open(testing.allocator, hooked, dir, &schema, .{});
        defer w.deinit(hooked);
        var got: [8]Doc = undefined;
        const held = try heldBy(&w, hooked, &got);
        // The last commit that returned, or the one under way.
        const last: usize = @min(s.acknowledged + 1, commits.len - 1);
        for (commits[s.acknowledged .. last + 1]) |want| {
            if (want.len == held.len and for (want, held) |a, b| {
                if (!std.meta.eql(a, b)) break false;
            } else true) return;
        }
        std.debug.print("acknowledged {d}, held {any}\n", .{ s.acknowledged, held });
        return error.NotACommit;
    }
};

/// What the writer's segments hold, deleted documents left out, sorted.
fn heldBy(w: *Writer, io: Io, out: []Doc) ![]const Doc {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(testing.allocator);
    var n: usize = 0;
    for (w.live.items) |*l| {
        const seg = switch (l.held) {
            .opened => |*o| &o.segment,
            .fresh => |*f| &f.segment,
        };
        for (0..l.docs) |d| {
            const doc: u32 = @intCast(d);
            if (l.deleted) |deleted| if (deleted.has(doc)) continue;
            var values: [1]segment.store.Value = undefined;
            try seg.storedOf(io, testing.allocator, doc, &buffer, &values);
            if (n == out.len) return error.TooManyDocuments;
            out[n] = .{ .id = seg.idOf(doc), .serial = values[0].bytes[0] - '0' };
            n += 1;
        }
    }
    std.mem.sort(Doc, out[0..n], {}, struct {
        fn lessThan(_: void, a: Doc, b: Doc) bool {
            return a.id < b.id or (a.id == b.id and a.serial < b.serial);
        }
    }.lessThan);
    return out[0..n];
}

fn everyCrashIn(shard: shakedown.EveryCrashOptions.Shard) !void {
    var ctx: Operation = .{};
    var report: shakedown.EveryFaultReport = .{};
    defer report.deinit();
    const result = shakedown.everyCrash(testing.allocator, &ctx, .{
        .sim = .{ .fs = .{ .names = names }, .watchdog = null },
        .max_states = 512,
        .max_steps = 1_000_000,
        .diagnostics = &report,
        .shard = shard,
    });
    const done = result catch |err| {
        if (report.failure) |f| {
            std.debug.print("every crash: {t} at {any}\n{s}\n", .{ f.err, f.injected, f.trace });
        }
        return err;
    };
    // Every state of every point was tried.
    try testing.expectEqual(@as(u64, 0), done.bounded);
    try testing.expect(done.runs > 1);
}

// The sweep, measured on macOS (Darwin's sync model): the clean run is 300
// steps; at its crash points the disk can come back in 182 states, each
// recovered and checked, and 15,008 more images that repeat one of them,
// none past the 512-state bound. In four ranges each stays well inside the
// runner's watchdog under emulation; a state two ranges reach is recovered
// in each.
test "every crash: three commits, points 1 of 4" {
    try everyCrashIn(.{ .index = 0, .count = 4 });
}

test "every crash: three commits, points 2 of 4" {
    try everyCrashIn(.{ .index = 1, .count = 4 });
}

test "every crash: three commits, points 3 of 4" {
    try everyCrashIn(.{ .index = 2, .count = 4 });
}

test "every crash: three commits, points 4 of 4" {
    try everyCrashIn(.{ .index = 3, .count = 4 });
}
