//! Every crash of a writer's commits and merges, inside a shakedown `Sim`:
//! airlock's syncs and renames routed onto its simulated disk, a power loss
//! at every step of a run of three commits, or of two commits and a merge,
//! and every state the disk could come back in. After each, a writer opens
//! the index as a program restarting would,
//! removing what the crash left, and the index is checked for what a
//! commit promises: it holds exactly the documents of one commit, no older
//! than the last that returned and no newer than the one under way, every
//! file it names verifies by its checksums, and no temporary file is left.
//! Then every single fault at every call of a commit and a merge, each run
//! on a fresh `Sim` of one seed (shakedown's `everyFault`: an error from any
//! call, a short write, a cancel), each checked the same way once a writer
//! reopens it.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const shakedown = @import("shakedown");
const seam = @import("airlock.testing");
const airlock = @import("airlock");
const Seam = seam.Seam;
const Writer = @import("Writer.zig");
const Reader = @import("Reader.zig");
const snapshots = @import("reader_test.zig");
const Schema = @import("Schema.zig");
const segment = @import("segment.zig");

const os = builtin.target.os.tag;

/// The simulated disk's names, as this platform's file systems compare them.
const names: @FieldType(shakedown.Sim.Fs.Options, "names") = if (os.isDarwin()) .darwin else if (os == .windows) .windows else .posix;

const schema = [_]Schema.Field{
    .{ .name = "body", .kind = .text, .positions = true },
    .{ .name = "serial", .kind = .keyword, .stored = true },
};

const Doc = snapshots.Doc;

/// What the index holds after each commit, sorted: none before the first.
const commits = [_][]const Doc{
    &.{},
    &.{ .{ .id = 1, .serial = 0 }, .{ .id = 2, .serial = 1 }, .{ .id = 3, .serial = 2 } },
    &.{ .{ .id = 1, .serial = 0 }, .{ .id = 3, .serial = 2 }, .{ .id = 4, .serial = 3 } },
    &.{ .{ .id = 1, .serial = 4 }, .{ .id = 3, .serial = 2 }, .{ .id = 4, .serial = 3 }, .{ .id = 5, .serial = 5 } },
};

/// What the index holds after each commit when the third is the merge's:
/// the second's documents, in one segment.
const merged = [_][]const Doc{ commits[0], commits[1], commits[2], commits[2] };

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
    /// Whether the third step is a merge of the first two commits'
    /// segments, not a commit.
    merge: bool = false,

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
        var w: Writer = try .open(s.arena.allocator(), io, dir, &schema, .{ .merge = .{ .segments_per_tier = 2, .max_merge_at_once = 2 } });
        defer w.deinit(io);
        for ([_]u64{ 1, 2, 3 }, 0..) |id, serial| try add(&w, io, id, @intCast(serial), false);
        _ = try w.commit(io);
        s.acknowledged = 1;
        try add(&w, io, 4, 3, false);
        try w.delete(2);
        _ = try w.commit(io);
        s.acknowledged = 2;
        if (s.merge) {
            if (try w.mergeStep(io, null) == null) return error.NoMerge;
        } else {
            try add(&w, io, 1, 4, true);
            try add(&w, io, 5, 5, false);
            _ = try w.commit(io);
        }
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
        // A snapshot of the newest commit, as a reader opens it.
        var r = Reader.open(testing.allocator, hooked, dir, &schema, .{}) catch |err| switch (err) {
            error.NotFound => {
                if (s.acknowledged > 0) return error.NotACommit;
                return;
            },
            else => return err,
        };
        defer r.deinit();
        // Every file the commit names holds every byte its checksums say.
        var buffer: [4096]u8 = undefined;
        for (r.segments) |*seg| {
            try verifyFile(hooked, dir, .{ .kind = .segment, .segment = seg.number() }, 0, &buffer);
            switch (seg.deletions) {
                .committed => |generation| try verifyFile(hooked, dir, .{ .kind = .deletions, .segment = seg.number() }, generation, &buffer),
                .none => {},
                .unsaved => return error.NotACommit,
            }
        }
        var held: std.ArrayList(Doc) = .empty;
        defer held.deinit(testing.allocator);
        try snapshots.holds(&r, hooked, testing.allocator, &held);
        // The last commit that returned, or the one under way.
        const last: usize = @min(s.acknowledged + 1, commits.len - 1);
        const held_by = if (s.merge) &merged else &commits;
        for (held_by[s.acknowledged .. last + 1]) |want| {
            if (want.len == held.items.len and for (want, held.items) |a, b| {
                if (!std.meta.eql(a, b)) break false;
            } else true) return;
        }
        std.debug.print("acknowledged {d}, held {any}\n", .{ s.acknowledged, held.items });
        return error.NotACommit;
    }
};

fn verifyFile(io: Io, dir: Io.Dir, e: segment.files.Expected, generation: u64, buffer: []u8) !void {
    var name_buffer: [segment.files.max_name_bytes]u8 = undefined;
    const file = try dir.openFile(io, segment.files.name(&name_buffer, e.segment, e.kind, generation), .{});
    defer file.close(io);
    try e.verify(io, file, buffer);
}

fn everyCrashIn(shard: shakedown.EveryCrashOptions.Shard, merge: bool) !void {
    var ctx: Operation = .{ .merge = merge };
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
// steps; at its crash points the disk can come back in 240 states, each
// recovered and checked, and 14,959 more images that repeat one of them,
// none past the 512-state bound. In four ranges each stays well inside the
// runner's watchdog under emulation; a state two ranges reach is recovered
// in each.
test "every crash: three commits, points 1 of 4" {
    try everyCrashIn(.{ .index = 0, .count = 4 }, false);
}

test "every crash: three commits, points 2 of 4" {
    try everyCrashIn(.{ .index = 1, .count = 4 }, false);
}

test "every crash: three commits, points 3 of 4" {
    try everyCrashIn(.{ .index = 2, .count = 4 }, false);
}

test "every crash: three commits, points 4 of 4" {
    try everyCrashIn(.{ .index = 3, .count = 4 }, false);
}

// The merge's sweep, measured the same way: two commits, then a merge of
// their two segments, 292 steps; 200 states recovered and checked, 9,908
// images repeating one of them, none past the bound.
test "every crash: two commits and a merge, points 1 of 4" {
    try everyCrashIn(.{ .index = 0, .count = 4 }, true);
}

test "every crash: two commits and a merge, points 2 of 4" {
    try everyCrashIn(.{ .index = 1, .count = 4 }, true);
}

test "every crash: two commits and a merge, points 3 of 4" {
    try everyCrashIn(.{ .index = 2, .count = 4 }, true);
}

test "every crash: two commits and a merge, points 4 of 4" {
    try everyCrashIn(.{ .index = 3, .count = 4 }, true);
}

const merge_options: Writer.Options = .{ .merge = .{ .segments_per_tier = 2, .max_merge_at_once = 2 } };

/// The failures tried at each of airlock's calls, those the call can
/// return: an I/O error, a full disk, an interruption, a refusal, a cancel.
fn faultClasses(call: seam.Call) []const shakedown.IoFault {
    const F = shakedown.IoFault;
    if (os == .windows) {
        const common = [_]F{ .{ .fail = error.IO_DEVICE_ERROR }, .{ .fail = error.DISK_FULL }, .{ .fail = error.Canceled } };
        return switch (call) {
            .win_rename_ex, .rename, .open_dir => &(common ++ [_]F{ .{ .fail = error.SHARING_VIOLATION }, .{ .fail = error.DELETE_PENDING } }),
            .create_temp => &(common ++ [_]F{.{ .fail = error.DELETE_PENDING }}),
            .close, .volume_name, .stat_id => &.{},
            else => &common,
        };
    }
    const common = [_]F{ .{ .fail = error.IO }, .{ .fail = error.NOSPC }, .{ .fail = error.INTR }, .{ .fail = error.Canceled } };
    return switch (call) {
        .create_temp => &.{ .{ .fail = error.ACCES }, .{ .fail = error.NOSPC }, .{ .fail = error.INTR }, .{ .fail = error.Canceled } },
        .open_dir, .open_file, .unlink => &.{ .{ .fail = error.ACCES }, .{ .fail = error.INTR }, .{ .fail = error.Canceled } },
        .stat_id, .getfl => &.{ .{ .fail = error.ACCES }, .{ .fail = error.INTR } },
        .close => &.{ .{ .fail = error.IO }, .{ .fail = error.INTR } },
        else => &common,
    };
}

/// Every single fault at every step of a second commit and a merge, on a
/// simulated disk holding a first commit: an error from any call, a short
/// write, a cancel. Every run is a fresh `Sim` of the same seed, so airlock's
/// concurrent syncs run in one order every run. Whatever failed, a writer opens
/// the index afterwards as a program restarting would, and the index holds
/// exactly the documents of one commit, no older than the last that
/// returned and no newer than the one under way, every file it names
/// verifies, and no temporary file is left.
pub const Faulted = struct {
    /// The disk holding the first commit, which each run starts from.
    first: shakedown.Sim.Fs.Snapshot,
    h: *Seam = undefined,
    acknowledged: usize = 0,

    /// A simulation that makes the first commit, and the disk it leaves.
    const First = struct {
        sim: *shakedown.Sim,
        disk: shakedown.Sim.Fs.Snapshot,

        fn make() !First {
            const sim = try shakedown.Sim.init(testing.allocator, sim_options);
            errdefer sim.deinit();
            const Commit = struct {
                fn run(io: Io) !void {
                    const h = try Seam.create(testing.allocator, io, .{ .trace = .off });
                    defer h.destroy();
                    const dir = try makeDir(h.io());
                    defer dir.close(h.io());
                    var w: Writer = try .open(testing.allocator, h.io(), dir, &schema, merge_options);
                    defer w.deinit(h.io());
                    for ([_]u64{ 1, 2, 3 }, 0..) |id, serial| try add(&w, h.io(), id, @intCast(serial), false);
                    _ = try w.commit(h.io());
                }
            };
            switch (sim.run(Commit.run, .{sim.io()})) {
                .finished => {},
                .failed => |err| return err,
                else => return error.FirstCommit,
            }
            return .{ .sim = sim, .disk = try sim.fs().snapshot() };
        }

        fn deinit(f: First) void {
            f.disk.deinit();
            f.sim.deinit();
        }
    };

    pub fn setUp(s: *Faulted, fio: *shakedown.FaultIo) !void {
        shakedown.Sim.fsOf(fio.io()).?.restore(s.first);
        s.h = try Seam.over(testing.allocator, fio, .{});
        s.acknowledged = 1;
    }

    pub fn tearDown(s: *Faulted) void {
        s.h.destroy();
    }

    pub fn run(s: *Faulted, base: Io) !void {
        _ = base;
        const io = s.h.io();
        const dir = try Io.Dir.cwd().openDir(io, "index", .{ .iterate = true });
        defer dir.close(io);
        var w: Writer = try .open(testing.allocator, io, dir, &schema, merge_options);
        defer w.deinit(io);
        try add(&w, io, 4, 3, false);
        try w.delete(2);
        _ = try w.commit(io);
        s.acknowledged = 2;
        if (try w.mergeStep(io, null) == null) return error.NoMerge;
        s.acknowledged = 3;
    }

    pub fn faultsFor(s: *Faulted, record: shakedown.IoTrace.Record) []const shakedown.IoFault {
        _ = s;
        const f = record.event.foreign orelse return &.{};
        return faultClasses(@fromBackingInt(@as(u8, @intCast(f.call))));
    }

    /// Judged on the simulation's `Io` past the faults, through a seam of
    /// its own, as a program restarting would open the index.
    pub fn check(s: *Faulted, judged: Io, result: anyerror!void, injected: ?shakedown.Injected) !void {
        _ = injected;
        if (result) |_| {
            if (s.acknowledged != 3) return error.NotACommit;
        } else |_| {}
        const h = try Seam.create(testing.allocator, judged, .{ .trace = .off });
        defer h.destroy();
        const io = h.io();
        const dir = try Io.Dir.cwd().openDir(io, "index", .{ .iterate = true });
        defer dir.close(io);
        {
            var w: Writer = try .open(testing.allocator, io, dir, &schema, merge_options);
            w.deinit(io);
        }
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (std.mem.startsWith(u8, entry.name, Writer.temp_prefix)) return error.TempLeft;
        }
        var r = try Reader.open(testing.allocator, io, dir, &schema, .{});
        defer r.deinit();
        var buffer: [4096]u8 = undefined;
        for (r.segments) |*seg| {
            try verifyFile(io, dir, .{ .kind = .segment, .segment = seg.number() }, 0, &buffer);
            switch (seg.deletions) {
                .committed => |generation| try verifyFile(io, dir, .{ .kind = .deletions, .segment = seg.number() }, generation, &buffer),
                .none => {},
                .unsaved => return error.NotACommit,
            }
        }
        var held: std.ArrayList(Doc) = .empty;
        defer held.deinit(testing.allocator);
        try snapshots.holds(&r, io, testing.allocator, &held);
        const last: usize = @min(s.acknowledged + 1, merged.len - 1);
        for (merged[s.acknowledged .. last + 1]) |want| {
            if (want.len == held.items.len and for (want, held.items) |a, b| {
                if (!std.meta.eql(a, b)) break false;
            } else true) return;
        }
        std.debug.print("acknowledged {d}, held {any}\n", .{ s.acknowledged, held.items });
        return error.NotACommit;
    }
};

/// The simulation every run of the fault sweep is made on, and its first
/// commit's.
const sim_options: shakedown.Sim.Options = .{ .fs = .{ .names = names }, .watchdog = null };

fn everyFaultIn(shard: @FieldType(shakedown.EveryFaultOptions, "shard")) !void {
    const first: Faulted.First = try .make();
    defer first.deinit();
    var ctx: Faulted = .{ .first = first.disk };
    var report: shakedown.EveryFaultReport = .{};
    defer report.deinit();
    const result = shakedown.everyFault(testing.allocator, testing.io, &ctx, .{
        .errors = &.{ error.InputOutput, error.NoSpaceLeft },
        // Whether a remap moves the block is the allocator's, so a run that
        // refuses one is not held to the clean run's calls.
        .alloc = false,
        .diagnostics = &report,
        .shard = shard,
        .sim = sim_options,
    });
    const done = result catch |err| {
        if (report.failure) |f| std.debug.print("every fault: {t} at {any} difference {any}\n{s}\n", .{ f.err, f.injected, f.difference, f.trace });
        return err;
    };
    try testing.expect(done.runs > 1);
}

// Measured on macOS: the clean run is 243 steps and the sweep 415 runs,
// 40 of whose calls (airlock's syncs, run concurrently) were still waiting
// when their run's fault fired; well under half a minute in Debug.
test "every fault: a commit and a merge, any call failing, leave one commit whole" {
    try everyFaultIn(.{});
}
