//! A snapshot of an index: the segments one commit's manifest names, each
//! held open with its deletions as of that commit, or a writer's segments
//! as they stood when it was asked for one. A snapshot never changes. Its
//! segments are counted (`Held`), so a later commit, the writer's close or
//! another snapshot's leave them open until this one closes; a segment file
//! the writer removes stays readable through the handle the snapshot holds.
//!
//! A reader opens every file of its manifest before it answers anything.
//! One that finds a file gone read a manifest that commits since have moved
//! past the writer's retention: it reads the newest manifest again, up to
//! `Options.retries` times, and is `error.Busy` past them. A directory with
//! no manifest is `error.NotFound`.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const Schema = @import("Schema.zig");
const Manifest = @import("Manifest.zig");
const Opened = @import("Opened.zig");
const Held = @import("Held.zig");
const committed = @import("committed.zig");
const bitmap = @import("encoding.zig").bitmap;
const segment = @import("segment.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Reader = @This();

pub const Options = struct {
    /// The longest term the index holds, in bytes.
    term_bytes: u16 = 255,
    /// The most a stored block decodes to.
    max_block: u32 = 16 * 1024 * 1024 + segment.store.block_bytes,
    /// How many times a manifest whose files are gone is read again.
    retries: u8 = 8,
    /// Told what differs when the index is `SchemaMismatch`.
    mismatch: ?*Manifest.Mismatch = null,
};

pub const OpenError = error{ NotFound, Busy, Corrupt, VersionTooNew, SchemaMismatch, ReadFailed, Canceled, OutOfMemory };

/// Where a segment's deletions in a snapshot come from.
pub const Deletions = union(enum) {
    none,
    /// The deletions file of this generation.
    committed: u64,
    /// The writer's, not yet committed.
    unsaved,
};

/// A segment of the snapshot, and its deleted documents in it.
pub const Segment = struct {
    held: Held.Handle,
    deleted: ?bitmap.Bitmap,
    deleted_count: u32,
    deletions: Deletions,

    pub fn read(s: *const Segment) *const segment.read.Segment {
        return s.held.get().read();
    }

    pub fn number(s: *const Segment) u64 {
        return s.held.get().number;
    }

    pub fn docs(s: *const Segment) u32 {
        return s.held.get().docs;
    }

    pub fn isDeleted(s: *const Segment, doc: u32) bool {
        return if (s.deleted) |d| d.has(doc) else false;
    }

    pub fn deinit(s: *Segment, gpa: Allocator) void {
        s.held.release();
        if (s.deleted) |*d| d.deinit(gpa);
        s.* = undefined;
    }
};

gpa: Allocator,
dir: aegis.own.Unowned(Io.Dir),
schema: []const Schema.Field,
options: Options,
/// The commit the snapshot is of, 0 before the first. A writer's snapshot
/// holds what it closed since that commit too.
generation: u64,
segments: []Segment,

/// A snapshot of the newest commit of the index in `dir`, which the caller
/// keeps open, of documents of `schema`.
pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, schema: []const Schema.Field, options: Options) OpenError!Reader {
    return openFrom(gpa, io, dir, schema, options, &.{});
}

/// A snapshot of the newest commit, holding again the segments it shares
/// with `r`, which stays as it is.
pub fn reopen(r: *const Reader, io: Io) OpenError!Reader {
    return openFrom(r.gpa, io, r.dir.get(), r.schema, r.options, r.segments);
}

pub fn deinit(r: *Reader) void {
    for (r.segments) |*s| s.deinit(r.gpa);
    r.gpa.free(r.segments);
    r.* = undefined;
}

/// A file a manifest named, or the manifest itself, was not there.
const AttemptError = error{Vanished} || error{ NotFound, Corrupt, VersionTooNew, SchemaMismatch, ReadFailed, Canceled, OutOfMemory };

fn openFrom(gpa: Allocator, io: Io, dir: Io.Dir, schema: []const Schema.Field, options: Options, previous: []const Segment) OpenError!Reader {
    var tries: u32 = 0;
    while (true) {
        if (attempt(gpa, io, dir, schema, options, previous)) |r| return r else |err| switch (err) {
            error.Vanished => {
                if (tries == options.retries) return error.Busy;
                tries += 1;
            },
            else => |e| return e,
        }
    }
}

fn attempt(gpa: Allocator, io: Io, dir: Io.Dir, schema: []const Schema.Field, options: Options, previous: []const Segment) AttemptError!Reader {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const asked: committed.Asked = .{ .fields = schema, .term_bytes = options.term_bytes, .mismatch = options.mismatch };
    const generation = try committed.newestGeneration(io, dir) orelse return error.NotFound;
    const m = committed.manifest(arena.allocator(), io, dir, generation, asked) catch |err| return found(err);
    var segments: std.ArrayList(Segment) = try .initCapacity(gpa, m.segments.len);
    errdefer {
        for (segments.items) |*s| s.deinit(gpa);
        segments.deinit(gpa);
    }
    for (m.segments) |entry| {
        segments.appendAssumeCapacity(try segmentOf(gpa, io, dir, schema, options, entry, previous));
    }
    return .{
        .gpa = gpa,
        .dir = .of(dir),
        .schema = schema,
        .options = options,
        .generation = generation,
        .segments = try segments.toOwnedSlice(gpa),
    };
}

/// The segment `entry` names with its deletions: held again from
/// `previous` when a segment there was read from the file of its number,
/// else opened. Only a committed number is never given to another segment:
/// a writer that closes drops the segments it had not committed, and the
/// next one numbers its own from the last commit's count, so a segment a
/// writer's snapshot holds in memory may share its number with another.
fn segmentOf(gpa: Allocator, io: Io, dir: Io.Dir, schema: []const Schema.Field, options: Options, entry: Manifest.Segment, previous: []const Segment) AttemptError!Segment {
    const before: ?*const Segment = for (previous) |*p| {
        if (p.number() == entry.number and p.held.get().from == .file) break p;
    } else null;
    var held: Held.Handle = if (before) |p| p.held.retain() else held: {
        var o = Opened.open(gpa, io, dir, schema, entry, options.max_block) catch |err| return found(err);
        errdefer o.deinit(gpa, io);
        break :held try .create(gpa, .{ .gpa = gpa, .io = io, .number = entry.number, .docs = entry.docs, .from = .{ .file = o } });
    };
    errdefer held.release();
    if (held.get().docs != entry.docs) return error.Corrupt;
    const deletions: Deletions = if (entry.deletions) |d| .{ .committed = d.generation } else .none;
    const deleted: ?bitmap.Bitmap = if (before != null and std.meta.eql(before.?.deletions, deletions))
        if (before.?.deleted) |d| try d.clone(gpa) else null
    else
        committed.deletions(gpa, io, dir, entry) catch |err| return found(err);
    return .{
        .held = held,
        .deleted = deleted,
        .deleted_count = if (entry.deletions) |d| d.count else 0,
        .deletions = deletions,
    };
}

fn found(err: committed.Error) AttemptError {
    return switch (err) {
        error.NotFound => error.Vanished,
        else => |e| e,
    };
}
