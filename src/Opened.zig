//! A segment opened from its index's directory, as a manifest names it:
//! its file held open, the sections read whole held in memory, each checked
//! by its CRC-32C (the term dictionary, the lengths, the ids, the columns),
//! the sections read as they are asked for read from the file (the
//! postings, the positions, the store), its deletions file read whole, and
//! the segment parsed over them.
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

/// The sections read whole, and those read as they are asked for.
const whole_sections = [_]files.Section{ .terms, .lengths, .ids, .columns };

entry: Manifest.Segment,
file: File,
/// Each whole section's bytes.
whole: [whole_sections.len][]u8,
/// The deletions file's bytes, when the segment has one, and its view.
deletion_bytes: ?[]u8,
deletions: ?bitmap.View,
segment: layer.read.Segment,

/// Opens the segment `entry` names in `dir`, of documents of `schema`, its
/// stored blocks decoding to at most `max_block` bytes each.
pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, schema: []const Schema.Field, entry: Manifest.Segment, max_block: u32) OpenError!Opened {
    var o: Opened = undefined;
    o.entry = entry;
    // Read through the handle itself: its owner binds where it is first
    // used, and the segment is used where it is moved to.
    const file = try openFile(io, dir, entry.number, .segment, 0);
    o.file = .init(file);
    errdefer o.file.deinit(io);
    const expected: files.Expected = .{ .kind = .segment, .segment = entry.number };
    const table = try expected.openSegment(io, file);
    const len = file.length(io) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        else => error.ReadFailed,
    };
    const whole_file: source.Source = .{ .file = .{ .file = .of(file), .start = 0, .len = len } };
    var read_whole: usize = 0;
    errdefer for (o.whole[0..read_whole]) |bytes| gpa.free(bytes);
    var bodies: layer.read.Bodies = undefined;
    inline for (whole_sections, 0..) |section, i| {
        const e = table.of(section);
        o.whole[i] = try whole_file.alloc(io, gpa, e.offset, e.len);
        read_whole += 1;
        try table.checkSection(section, o.whole[i]);
        @field(bodies, @tagName(section)) = o.whole[i];
    }
    inline for (.{ .postings, .positions, .store }) |section| {
        const e = table.of(section);
        @field(bodies, @tagName(section)) = .{ .file = .{ .file = .of(file), .start = e.offset, .len = e.len } };
    }
    o.deletion_bytes = null;
    o.deletions = null;
    errdefer if (o.deletion_bytes) |bytes| gpa.free(bytes);
    if (entry.deletions) |d| {
        const del = try openFile(io, dir, entry.number, .deletions, d.generation);
        defer del.close(io);
        const bytes = try source.readWhole(io, del, gpa);
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
    o.file.deinit(io);
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
