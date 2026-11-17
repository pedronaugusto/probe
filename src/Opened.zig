//! A segment opened from its index's directory, as a manifest names it:
//! the files read whole held as their checked bodies (the term dictionary,
//! the lengths, the ids, the columns, and its deletions), the files read as
//! they are asked for held open (the postings, the positions, the store),
//! and the segment parsed over them.
//!
//! A file the manifest names that is not there is `error.NotFound`: a
//! reader that read a manifest older than the writer's retention opens the
//! newest one instead. Every other refusal is the file's own (`Corrupt`,
//! `VersionTooNew`) or the read's (`ReadFailed`, `Canceled`).
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const Schema = @import("Schema.zig");
const Manifest = @import("Manifest.zig");
const bitmap = @import("encoding.zig").bitmap;
const layer = @import("segment.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const files = layer.files;
const source = layer.source;

const Opened = @This();

pub const OpenError = error{ NotFound, Corrupt, VersionTooNew, ReadFailed, Canceled, OutOfMemory };

const File = aegis.own.OwnedIo(Io.File, closeFile);

fn closeFile(f: *Io.File, io: Io) void {
    f.close(io);
}

/// The kinds read whole, and those read as they are asked for.
const whole_kinds = [_]files.Kind{ .terms, .lengths, .ids, .columns };
const positional_kinds = [_]files.Kind{ .postings, .positions, .store };

entry: Manifest.Segment,
/// Each whole file's bytes, its header and footer included.
whole: [whole_kinds.len][]u8,
held: [positional_kinds.len]File,
/// The deletions file's bytes, when the segment has one, and its view.
deletion_bytes: ?[]u8,
deletions: ?bitmap.View,
segment: layer.read.Segment,

/// Opens the segment `entry` names in `dir`, of documents of `schema`, its
/// stored blocks decoding to at most `max_block` bytes each.
pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, schema: []const Schema.Field, entry: Manifest.Segment, max_block: u32) OpenError!Opened {
    var o: Opened = undefined;
    o.entry = entry;
    var read_whole: usize = 0;
    errdefer for (o.whole[0..read_whole]) |bytes| gpa.free(bytes);
    var bodies: layer.read.Bodies = undefined;
    inline for (whole_kinds, 0..) |kind, i| {
        o.whole[i] = try readWhole(gpa, io, dir, entry.number, kind, 0);
        read_whole += 1;
        const e: files.Expected = .{ .kind = kind, .segment = entry.number };
        @field(bodies, @tagName(kind)) = (try e.check(.init(o.whole[i]))).bytes;
    }
    var opened: usize = 0;
    errdefer for (o.held[0..opened]) |*f| f.deinit(io);
    inline for (positional_kinds, 0..) |kind, i| {
        // Read through the handle itself: its owner binds where it is first
        // used, and the segment is used where it is moved to.
        const file = try openFile(io, dir, entry.number, kind, 0);
        o.held[i] = .init(file);
        opened += 1;
        const e: files.Expected = .{ .kind = kind, .segment = entry.number };
        @field(bodies, @tagName(kind)) = try e.open(io, file);
    }
    o.deletion_bytes = null;
    o.deletions = null;
    errdefer if (o.deletion_bytes) |bytes| gpa.free(bytes);
    if (entry.deletions) |d| {
        const bytes = try readWhole(gpa, io, dir, entry.number, .deletions, d.generation);
        o.deletion_bytes = bytes;
        const e: files.Expected = .{ .kind = .deletions, .segment = entry.number };
        const view = bitmap.View.parse((try e.check(.init(bytes))).bytes, entry.docs) catch return error.Corrupt;
        if (view.count() != d.count) return error.Corrupt;
        o.deletions = view;
    }
    o.segment = layer.read.Segment.parse(gpa, io, bodies, schema, max_block) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Corrupt => error.Corrupt,
        error.ReadFailed => error.ReadFailed,
        error.Canceled => error.Canceled,
    };
    if (o.segment.docs != entry.docs) {
        o.segment.deinit(gpa);
        return error.Corrupt;
    }
    return o;
}

pub fn deinit(o: *Opened, gpa: Allocator, io: Io) void {
    o.segment.deinit(gpa);
    for (o.whole) |bytes| gpa.free(bytes);
    for (&o.held) |*f| f.deinit(io);
    if (o.deletion_bytes) |bytes| gpa.free(bytes);
    o.* = undefined;
}

/// Whether `doc` is deleted in this segment's generation.
pub fn deleted(o: *const Opened, doc: u32) bool {
    return if (o.deletions) |d| d.has(doc) else false;
}

fn openFile(io: Io, dir: Io.Dir, number: u64, kind: files.Kind, generation: u64) OpenError!Io.File {
    var name_buffer: [files.max_name_bytes]u8 = undefined;
    const name = files.name(&name_buffer, number, kind, generation);
    return dir.openFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => error.NotFound,
        error.Canceled => error.Canceled,
        else => error.ReadFailed,
    };
}

fn readWhole(gpa: Allocator, io: Io, dir: Io.Dir, number: u64, kind: files.Kind, generation: u64) OpenError![]u8 {
    const file = try openFile(io, dir, number, kind, generation);
    defer file.close(io);
    return source.readWhole(io, file, gpa);
}
