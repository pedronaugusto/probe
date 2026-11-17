//! What an index's directory holds as committed: its newest manifest, a
//! manifest by its generation, and a segment's deletions as a manifest
//! names them.
//!
//! A file that is not there is `error.NotFound`: a writer removed it after
//! the manifest that named it was read, or the manifest after it was
//! listed. Every other refusal is the file's own (`Corrupt`,
//! `VersionTooNew`, `SchemaMismatch`) or the read's (`ReadFailed`,
//! `Canceled`).
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const Schema = @import("Schema.zig");
const Manifest = @import("Manifest.zig");
const bitmap = @import("encoding.zig").bitmap;
const segment = @import("segment.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const files = segment.files;

pub const Error = error{ NotFound, Corrupt, VersionTooNew, SchemaMismatch, ReadFailed, Canceled, OutOfMemory };

/// What a manifest is read against: the schema and term length the reader
/// asks for, and where what differs is told.
pub const Asked = struct {
    fields: []const Schema.Field,
    term_bytes: u16,
    mismatch: ?*Manifest.Mismatch = null,
};

/// The newest generation a manifest in `dir` has, or null in a directory
/// that has none.
pub fn newestGeneration(io: Io, dir: Io.Dir) Error!?u64 {
    var highest: ?u64 = null;
    var it = dir.iterate();
    while (it.next(io) catch |err| return listed(err)) |entry| {
        const generation = Manifest.generationOf(entry.name) orelse continue;
        if (highest == null or generation > highest.?) highest = generation;
    }
    return highest;
}

/// The newest manifest in `dir` read on `arena`, or null in a directory
/// that has none.
pub fn newest(arena: Allocator, io: Io, dir: Io.Dir, asked: Asked) Error!?Manifest {
    const generation = try newestGeneration(io, dir) orelse return null;
    return try manifest(arena, io, dir, generation, asked);
}

/// The manifest of `generation` in `dir`, read on `arena`.
pub fn manifest(arena: Allocator, io: Io, dir: Io.Dir, generation: u64, asked: Asked) Error!Manifest {
    var name_buffer: [Manifest.name_bytes]u8 = undefined;
    const file = dir.openFile(io, Manifest.name(&name_buffer, generation), .{}) catch |err| return opened(err);
    defer file.close(io);
    const bytes = try segment.source.readWhole(io, file, arena);
    return Manifest.parse(arena, .init(bytes), .{
        .generation = generation,
        .fields = asked.fields,
        .term_bytes = asked.term_bytes,
        .mismatch = asked.mismatch,
    });
}

/// The deletions `entry` names, read from their file and checked against
/// the count it records, or null when it names none.
pub fn deletions(gpa: Allocator, io: Io, dir: Io.Dir, entry: Manifest.Segment) Error!?bitmap.Bitmap {
    const d = entry.deletions orelse return null;
    var name_buffer: [files.max_name_bytes]u8 = undefined;
    const file = dir.openFile(io, files.name(&name_buffer, entry.number, .deletions, d.generation), .{}) catch |err| return opened(err);
    defer file.close(io);
    const bytes = try segment.source.readWhole(io, file, gpa);
    defer gpa.free(bytes);
    const e: files.Expected = .{ .kind = .deletions, .segment = entry.number };
    const view = bitmap.View.parse((try e.check(.init(bytes))).bytes, entry.docs) catch return error.Corrupt;
    if (view.count() != d.count) return error.Corrupt;
    return try .fromView(gpa, view);
}

fn opened(err: Io.File.OpenError) Error {
    return switch (err) {
        error.FileNotFound => error.NotFound,
        error.Canceled => error.Canceled,
        else => error.ReadFailed,
    };
}

fn listed(err: Io.Dir.Iterator.Error) Error {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.SystemResources => error.OutOfMemory,
        else => error.ReadFailed,
    };
}
