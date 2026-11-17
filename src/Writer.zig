//! An index's one writer: documents added, deleted and updated, gathered
//! into segments and committed.
//!
//! The writer holds the directory's lock, std's advisory lock on its
//! `.lock` file, for as long as it is open: a second writer is
//! `error.Locked` at once, and the kernel lets the lock go when the process
//! ends, so a crashed writer never leaves an index locked. Once it holds the
//! lock nobody else writes there, so the temporary files a dead writer left
//! are removed at open, however new.
//!
//! The directory is the caller's, made durably before the writer opens it
//! (`airlock.makePath`): a writer makes what it puts in the directory
//! durable, never the directory's own name in its parent.
//!
//! Documents are gathered in a segment being built until `refresh`, or
//! until their bytes pass `Options.buffer_bytes`, closes it in memory. A
//! delete marks every document of its id in the segments there are and,
//! for the segment being built, every document added before it. `commit`
//! writes each new segment's file and each changed deletion bitmap as
//! airlock pendings, then after a fence the new manifest, and commits them
//! in one batch at `Options.durability`: the files reach the disk before
//! the manifest that names them, so a crash leaves the commit before or
//! this one, whole. It then removes the manifests past the last
//! `Options.keep_commits` and every file none of those names, then syncs
//! the directory once; a removal that fails is left to the next commit or
//! the next writer's open.
//!
//! A segment whose every document is deleted leaves the next manifest. What
//! is not committed when the writer closes is dropped.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const airlock = @import("airlock");
const Schema = @import("Schema.zig");
const Manifest = @import("Manifest.zig");
const Opened = @import("Opened.zig");
const bitmap = @import("encoding.zig").bitmap;
const segment = @import("segment.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const files = segment.files;
const write = segment.write;
const read = segment.read;

const Writer = @This();

pub const lock_name = ".lock";

/// The prefix of the temporary files the writer's pendings write.
pub const temp_prefix = ".probe-";

pub const Options = struct {
    /// The longest term the index holds, in bytes.
    term_bytes: u16 = 255,
    /// How far a commit's files reach before it returns.
    durability: airlock.Level = .data,
    /// A segment being built is closed once its documents' bytes pass this.
    buffer_bytes: usize = 64 * 1024 * 1024,
    /// The commits whose files stay for other processes' readers.
    keep_commits: u8 = 2,
    /// The most a stored block decodes to.
    max_block: u32 = 16 * 1024 * 1024 + segment.store.block_bytes,
    /// Told what differs when the index is `SchemaMismatch`.
    mismatch: ?*Manifest.Mismatch = null,
};

pub const OpenError = error{ Locked, NotFound, Corrupt, VersionTooNew, SchemaMismatch, ReadFailed, WriteFailed, Canceled, OutOfMemory };
pub const AddError = error{ Corrupt, ReadFailed, Canceled, OutOfMemory };
pub const CommitError = AddError || airlock.Batch.Error || error{WriteFailed};

/// A segment of the index: committed, held open from its files, or new
/// since the last commit, held in memory.
const Live = struct {
    number: u64,
    docs: u32,
    held: union(enum) {
        opened: Opened,
        fresh: Fresh,
    },
    /// Its deleted documents, once any is; their count; the generation of
    /// the deletions file that holds them, if committed; and whether they
    /// changed since.
    deleted: ?bitmap.Bitmap = null,
    deleted_count: u32 = 0,
    /// Whether its files are committed.
    committed: bool,
    deletions_generation: ?u64 = null,
    changed: bool = false,

    fn segmentOf(l: *const Live) *const read.Segment {
        return switch (l.held) {
            .opened => |*o| &o.segment,
            .fresh => |*f| &f.segment,
        };
    }

    fn deinit(l: *Live, gpa: Allocator, io: Io) void {
        switch (l.held) {
            .opened => |*o| o.deinit(gpa, io),
            .fresh => |*f| f.deinit(gpa),
        }
        if (l.deleted) |*d| d.deinit(gpa);
    }

    fn delete(l: *Live, gpa: Allocator, doc: u32) Allocator.Error!void {
        if (l.deleted == null) l.deleted = try .init(gpa, l.docs);
        if (l.deleted.?.has(doc)) return;
        l.deleted.?.add(doc);
        l.deleted_count += 1;
        l.changed = true;
    }
};

/// A segment built since the last commit: its file's bytes, and the
/// segment read over them.
const Fresh = struct {
    file: std.ArrayList(u8),
    segment: read.Segment,

    fn deinit(f: *Fresh, gpa: Allocator) void {
        f.segment.deinit(gpa);
        f.file.deinit(gpa);
    }
};

/// A delete of the segment being built: `id`'s documents below `upto`.
const BufferedDelete = struct { id: u64, upto: u32 };

const File = aegis.own.OwnedIo(Io.File, closeFile);

fn closeFile(f: *Io.File, io: Io) void {
    f.close(io);
}

gpa: Allocator,
dir: aegis.own.Unowned(Io.Dir),
schema: []const Schema.Field,
options: Options,
lock: File,
/// The last commit's generation, 0 before the first, and the next
/// segment's number.
generation: u64,
next_segment: u64,
live: std.ArrayList(Live) = .empty,
building: ?write.Builder = null,
building_bytes: usize = 0,
buffered: std.ArrayList(BufferedDelete) = .empty,
/// Commits after which the removal of old files failed, left to a later one.
prunes_failed: u32 = 0,
/// New segments a commit could not reopen from their files, held in memory.
reopens_failed: u32 = 0,

/// The writer of the index in `dir`, which the caller keeps open, for
/// documents of `schema`: its lock taken, a dead writer's temporary files
/// removed, and the newest manifest's segments opened.
pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, schema: []const Schema.Field, options: Options) OpenError!Writer {
    aegis.assert.invariant(options.keep_commits >= 1, "a writer keeps its last commit at least");
    var lock: File = .init(dir.createFile(io, lock_name, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
        error.WouldBlock => return error.Locked,
        error.Canceled => return error.Canceled,
        error.SystemResources => return error.OutOfMemory,
        else => return error.WriteFailed,
    });
    errdefer lock.deinit(io);
    _ = airlock.pruneTemps(io, dir, temp_prefix, .{ .older_than = aegis.units.Duration(.nanosecond, i96).fromRaw(0).toIoDuration() }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.WriteFailed,
    };
    var w: Writer = .{
        .gpa = gpa,
        .dir = .of(dir),
        .schema = schema,
        .options = options,
        .lock = undefined,
        .generation = 0,
        .next_segment = 0,
    };
    errdefer w.dropSegments(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    if (try newestManifest(arena.allocator(), io, dir, schema, options.term_bytes, options.mismatch)) |m| {
        w.generation = m.generation;
        w.next_segment = m.next_segment;
        try w.live.ensureTotalCapacity(gpa, m.segments.len);
        for (m.segments) |entry| {
            var opened = try Opened.open(gpa, io, dir, schema, entry, options.max_block);
            errdefer opened.deinit(gpa, io);
            var live: Live = .{ .number = entry.number, .docs = entry.docs, .held = .{ .opened = opened }, .committed = true };
            if (opened.deletions) |view| {
                live.deleted = try .fromView(gpa, view);
                live.deleted_count = view.count();
                live.deletions_generation = entry.deletions.?.generation;
            }
            w.live.appendAssumeCapacity(live);
        }
    }
    w.lock = lock.move();
    return w;
}

/// Closes the writer and lets its lock go; what is not committed is
/// dropped.
pub fn deinit(w: *Writer, io: Io) void {
    w.dropSegments(io);
    w.lock.deinit(io);
    w.* = undefined;
}

fn dropSegments(w: *Writer, io: Io) void {
    for (w.live.items) |*l| l.deinit(w.gpa, io);
    w.live.deinit(w.gpa);
    if (w.building) |*b| b.deinit();
    w.buffered.deinit(w.gpa);
}

/// The newest manifest in `dir` read on `arena`, or null in a directory
/// that has none.
pub fn newestManifest(arena: Allocator, io: Io, dir: Io.Dir, schema: []const Schema.Field, term_bytes: u16, mismatch: ?*Manifest.Mismatch) OpenError!?Manifest {
    var newest: ?u64 = null;
    var it = dir.iterate();
    while (it.next(io) catch |err| return listed(err)) |entry| {
        const generation = Manifest.generationOf(entry.name) orelse continue;
        if (newest == null or generation > newest.?) newest = generation;
    }
    const generation = newest orelse return null;
    return try readManifest(arena, io, dir, generation, schema, term_bytes, mismatch);
}

fn readManifest(arena: Allocator, io: Io, dir: Io.Dir, generation: u64, schema: []const Schema.Field, term_bytes: u16, mismatch: ?*Manifest.Mismatch) OpenError!Manifest {
    var name_buffer: [Manifest.name_bytes]u8 = undefined;
    const file = dir.openFile(io, Manifest.name(&name_buffer, generation), .{}) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        error.Canceled => return error.Canceled,
        else => return error.ReadFailed,
    };
    defer file.close(io);
    const bytes = try segment.source.readWhole(io, file, arena);
    return Manifest.parse(arena, .init(bytes), .{ .generation = generation, .fields = schema, .term_bytes = term_bytes, .mismatch = mismatch });
}

fn listed(err: Io.Dir.Iterator.Error) OpenError {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.SystemResources => error.OutOfMemory,
        else => error.ReadFailed,
    };
}

/// Adds `doc`, a value for each field of the schema.
pub fn add(w: *Writer, io: Io, doc: write.Document) AddError!void {
    if (w.building == null) w.building = try .init(w.gpa, w.schema, w.options.term_bytes);
    _ = try w.building.?.add(doc);
    for (doc.values) |v| w.building_bytes += switch (v) {
        .text, .keyword => |bytes| bytes.len,
        .numeric => 8,
    };
    if (w.building_bytes >= w.options.buffer_bytes) try w.refresh(io);
}

/// Deletes every document of `id` added before it.
pub fn delete(w: *Writer, id: u64) AddError!void {
    for (w.live.items) |*l| {
        var docs = try l.segmentOf().docsOf(id);
        while (docs.next()) |doc| try l.delete(w.gpa, doc);
    }
    if (w.building) |b| if (b.docs > 0) try w.buffered.append(w.gpa, .{ .id = id, .upto = b.docs });
}

/// Deletes every document of `doc`'s id, then adds `doc`.
pub fn update(w: *Writer, io: Io, doc: write.Document) AddError!void {
    try w.delete(doc.id);
    try w.add(io, doc);
}

/// Closes the segment being built, in memory, with its documents deleted
/// since they were added.
pub fn refresh(w: *Writer, io: Io) AddError!void {
    var b = w.building orelse return;
    w.building = null;
    defer b.deinit();
    defer w.buffered.clearRetainingCapacity();
    w.building_bytes = 0;
    if (b.docs == 0) return;
    const number = w.next_segment;
    var out = try b.finish(number);
    errdefer out.deinit(w.gpa);
    // The bytes were written here a moment ago: a refusal is a bug.
    const e: files.Expected = .{ .kind = .segment, .segment = number };
    const sections = e.checkSegment(.init(out.items)) catch aegis.assert.never("a segment just built reads back");
    var seg = read.Segment.parse(w.gpa, io, read.inMemory(sections), w.schema, w.options.max_block) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => aegis.assert.never("a segment just built reads back"),
    };
    errdefer seg.deinit(w.gpa);
    var live: Live = .{ .number = number, .docs = b.docs, .held = .{ .fresh = .{ .file = out, .segment = seg } }, .committed = false };
    errdefer if (live.deleted) |*d| d.deinit(w.gpa);
    for (w.buffered.items) |d| {
        var docs = try seg.docsOf(d.id);
        while (docs.next()) |doc| if (doc < d.upto) try live.delete(w.gpa, doc);
    }
    try w.live.append(w.gpa, live);
    w.next_segment += 1;
}

/// Makes what was added and deleted durable: the new segments' files and
/// changed deletions, then the manifest that names them, in one batch. The
/// commit's generation; the last one's when nothing changed since.
pub fn commit(w: *Writer, io: Io) CommitError!u64 {
    try w.refresh(io);
    var changed = w.generation == 0;
    for (w.live.items) |l| changed = changed or !l.committed or l.changed;
    if (!changed) return w.generation;
    const generation = w.generation + 1;
    const dir = w.dir.get();

    // Every file to publish, with the bytes it holds: owned by `held`.
    var arena: std.heap.ArenaAllocator = .init(w.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    var contents: std.ArrayList([]const u8) = .empty;
    var entries: std.ArrayList(Manifest.Segment) = .empty;
    for (w.live.items) |*l| {
        if (l.deleted_count == l.docs) continue;
        if (!l.committed) {
            try names.append(a, try fileName(a, l.number, .segment, 0));
            try contents.append(a, l.held.fresh.file.items);
        }
        var entry: Manifest.Segment = .{ .number = l.number, .docs = l.docs };
        if (l.deleted_count > 0) {
            if (l.changed) {
                try names.append(a, try fileName(a, l.number, .deletions, generation));
                try contents.append(a, try deletionsFile(a, l.number, l.deleted.?));
            }
            entry.deletions = .{ .generation = if (l.changed) generation else l.deletions_generation.?, .count = l.deleted_count };
        }
        try entries.append(a, entry);
    }
    const manifest: Manifest = .{
        .generation = generation,
        .next_segment = w.next_segment,
        .term_bytes = w.options.term_bytes,
        .fields = w.schema,
        .segments = entries.items,
    };
    var manifest_bytes: std.Io.Writer.Allocating = .init(a);
    manifest.write(&manifest_bytes.writer) catch return error.OutOfMemory;
    var manifest_name: [Manifest.name_bytes]u8 = undefined;
    try names.append(a, Manifest.name(&manifest_name, generation));
    try contents.append(a, manifest_bytes.written());

    try publish(a, io, dir, names.items, contents.items, w.options.durability);

    // Committed: the writer's state says so before anything can fail.
    w.generation = generation;
    var kept: usize = 0;
    for (w.live.items) |*l| {
        if (l.deleted_count == l.docs) {
            l.deinit(w.gpa, io);
            continue;
        }
        if (l.changed) l.deletions_generation = generation;
        l.changed = false;
        l.committed = true;
        w.live.items[kept] = l.*;
        kept += 1;
    }
    w.live.shrinkRetainingCapacity(kept);
    // New segments are read from their files from now on.
    for (w.live.items) |*l| {
        if (l.held != .fresh) continue;
        const entry: Manifest.Segment = .{ .number = l.number, .docs = l.docs };
        const opened = Opened.open(w.gpa, io, dir, w.schema, entry, w.options.max_block) catch {
            // One that cannot be reopened stays in memory, as committed as
            // the rest: its bytes are what its files hold.
            w.reopens_failed += 1;
            continue;
        };
        l.held.fresh.deinit(w.gpa);
        l.held = .{ .opened = opened };
    }
    w.prune(io) catch {
        // What is left goes at the next commit, or the next writer's open.
        w.prunes_failed += 1;
    };
    return generation;
}

fn fileName(a: Allocator, number: u64, kind: files.Kind, generation: u64) Allocator.Error![]const u8 {
    var buffer: [files.max_name_bytes]u8 = undefined;
    return a.dupe(u8, files.name(&buffer, number, kind, generation));
}

/// A deletions file: its frame around the bitmap.
fn deletionsFile(a: Allocator, number: u64, deleted: bitmap.Bitmap) Allocator.Error![]const u8 {
    const body_len = bitmap.bytesFor(deleted.docs);
    const bytes = try a.alloc(u8, files.header_bytes + body_len + files.footer_bytes);
    bytes[0..files.header_bytes].* = files.header(.deletions, number);
    deleted.write(bytes[files.header_bytes..][0..body_len]);
    const end = files.header_bytes + body_len;
    bytes[end..][0..files.footer_bytes].* = files.footer(files.crc32c(0, bytes[0..end]));
    return bytes;
}

/// Publishes each of `names` with its `contents` in one batch, the last
/// after a fence: every file before it reaches the disk first.
fn publish(a: Allocator, io: Io, dir: Io.Dir, names: []const []const u8, contents: []const []const u8, level: airlock.Level) CommitError!void {
    const pendings = try a.alloc(airlock.Pending, names.len);
    var made: usize = 0;
    // Discarded at the end whatever happened: before its publish a pending
    // removes its temp, after it only closes what it still holds.
    defer for (pendings[0..made]) |*p| p.discard(io);
    for (names, contents, pendings) |name, bytes, *p| {
        p.* = airlock.create(io, dir, name, .{ .temp = .{ .random = temp_prefix } }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.WriteFailed,
        };
        made += 1;
        p.file().writePositionalAll(io, bytes, 0) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.WriteFailed,
        };
    }
    const slots = try a.alloc(airlock.Batch.Slot, names.len + 1);
    var batch: airlock.Batch = .init(slots);
    for (pendings[0 .. names.len - 1]) |*p| batch.addPending(io, p, .create_new);
    batch.fence();
    batch.addPending(io, &pendings[names.len - 1], .create_new);
    _ = batch.commit(io, .{ .level = level }) catch |err| {
        batch.reset(io);
        return err;
    };
}

pub const PruneError = error{ Canceled, ReadFailed, WriteFailed, OutOfMemory };

/// Removes the manifests past the last `keep_commits`, and every segment
/// file none of the kept ones names.
fn prune(w: *Writer, io: Io) PruneError!void {
    const dir = w.dir.get();
    var arena: std.heap.ArenaAllocator = .init(w.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var generations: std.ArrayList(u64) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch |err| return pruneListed(err)) |entry| {
        if (Manifest.generationOf(entry.name)) |g| try generations.append(a, g);
    }
    std.mem.sort(u64, generations.items, {}, std.sort.desc(u64));
    const keep = @min(generations.items.len, w.options.keep_commits);
    // What the kept manifests name: each segment, and its deletions file.
    var named: std.AutoHashMapUnmanaged(files.Named, void) = .empty;
    for (generations.items[0..keep]) |g| {
        const m = readManifest(a, io, dir, g, w.schema, w.options.term_bytes, null) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            // A kept manifest that cannot be read keeps everything.
            else => return error.ReadFailed,
        };
        for (m.segments) |s| {
            try named.put(a, .{ .segment = s.number, .kind = .segment }, {});
            if (s.deletions) |d| try named.put(a, .{ .segment = s.number, .kind = .deletions, .generation = d.generation }, {});
        }
    }
    var name_buffer: [Manifest.name_bytes]u8 = undefined;
    for (generations.items[keep..]) |g| try removeFile(io, dir, Manifest.name(&name_buffer, g));
    var gone: std.ArrayList([]const u8) = .empty;
    it = dir.iterate();
    while (it.next(io) catch |err| return pruneListed(err)) |entry| {
        const n = files.parseName(entry.name) orelse continue;
        if (!named.contains(n)) try gone.append(a, try a.dupe(u8, entry.name));
    }
    for (gone.items) |name| try removeFile(io, dir, name);
    // The removals made durable together, at the writer's level: one sync
    // of the directory, not one per name.
    if (generations.items.len > keep or gone.items.len > 0) {
        _ = airlock.syncDir(io, dir, .{ .level = w.options.durability }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.WriteFailed,
        };
    }
}

fn pruneListed(err: Io.Dir.Iterator.Error) PruneError {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.SystemResources => error.OutOfMemory,
        else => error.ReadFailed,
    };
}

fn removeFile(io: Io, dir: Io.Dir, name: []const u8) PruneError!void {
    _ = airlock.remove(io, dir, name, .{ .sync = .{ .level = .none } }) catch |err| switch (err) {
        error.FileNotFound => {},
        error.Canceled => return error.Canceled,
        else => return error.WriteFailed,
    };
}
