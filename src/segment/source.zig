//! Where a segment file's body is read from: bytes in memory, or a file the
//! reader keeps open, read positionally. Both are read the same way, a
//! range at a time, so the segment layer has one path, and its tests feed
//! it from memory through the interface a file takes.
//!
//! A `Window` is a reader's cursor over a source and a buffer the reader
//! keeps: the buffer holds one range of the body, and the next is read
//! only when a range asked for passes it, so a reader that walks forward
//! reads each byte once, in reads of the buffer's size. Over memory it
//! lends the bytes themselves and the buffer is not used. The buffer is
//! passed to each call, so a reader holding its buffer inline can be moved.
//!
//! A range past the body is `error.Corrupt`: whatever names it lies. A file
//! read that fails is `error.ReadFailed`, or `error.Canceled` when the `Io`
//! cancels it. `readWhole` reads a file held whole: every read of an
//! index's files is here.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Error = error{ Corrupt, ReadFailed, Canceled };

/// A segment file's body.
pub const Source = union(enum) {
    memory: []const u8,
    file: Positional,

    /// The body of `file`: `len` bytes from `start`. The reader that opened
    /// the file keeps it and closes it.
    pub const Positional = struct {
        file: aegis.own.Unowned(Io.File),
        start: u64,
        len: u64,
    };

    pub fn len(s: Source) u64 {
        return switch (s) {
            .memory => |bytes| bytes.len,
            .file => |f| f.len,
        };
    }

    /// Reads the body's bytes from `offset` into all of `out`.
    pub fn read(s: Source, io: Io, offset: u64, out: []u8) Error!void {
        if (offset > s.len() or out.len > s.len() - offset) return error.Corrupt;
        switch (s) {
            .memory => |bytes| @memcpy(out, bytes[@intCast(offset)..][0..out.len]),
            .file => |f| {
                const got = f.file.get().readPositionalAll(io, out, f.start + offset) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => return error.ReadFailed,
                };
                // The file is shorter than when it was opened.
                if (got != out.len) return error.Corrupt;
            },
        }
    }

    /// The body's bytes from `offset`, `n` of them, in memory of their own.
    pub fn alloc(s: Source, io: Io, gpa: Allocator, offset: u64, n: u64) (Error || Allocator.Error)![]u8 {
        if (offset > s.len() or n > s.len() - offset) return error.Corrupt;
        const out = try gpa.alloc(u8, @intCast(n));
        errdefer gpa.free(out);
        try s.read(io, offset, out);
        return out;
    }
};

/// A cursor over a source, holding one range of its body in the reader's
/// buffer.
pub const Window = struct {
    source: Source,
    io: Io,
    /// The body's offset of the buffer's first byte, and how many it holds.
    start: u64 = 0,
    held: usize = 0,

    pub fn init(source: Source, io: Io) Window {
        return .{ .source = source, .io = io };
    }

    /// The bytes from `offset`, `n` of them, no more than `buffer` holds;
    /// valid until the next call.
    pub fn bytes(w: *Window, buffer: []u8, offset: u64, n: usize) Error![]const u8 {
        aegis.assert.invariant(n <= buffer.len, "a range fits its window");
        const total = w.source.len();
        if (offset > total or n > total - offset) return error.Corrupt;
        switch (w.source) {
            .memory => |all| return all[@intCast(offset)..][0..n],
            .file => {
                if (offset >= w.start and offset - w.start <= w.held and n <= w.held - (offset - w.start)) {
                    return buffer[@intCast(offset - w.start)..][0..n];
                }
                const fill: usize = @intCast(@min(buffer.len, total - offset));
                w.held = 0;
                try w.source.read(w.io, offset, buffer[0..fill]);
                w.start = offset;
                w.held = fill;
                return buffer[0..n];
            },
        }
    }

    /// The bytes from `offset` up to `n` of them, fewer where `end` comes
    /// first: for a record whose length is learned as it is read.
    pub fn upTo(w: *Window, buffer: []u8, offset: u64, n: usize, end: u64) Error![]const u8 {
        if (offset > end) return error.Corrupt;
        return w.bytes(buffer, offset, @intCast(@min(n, end - offset)));
    }
};

pub const WholeError = error{ ReadFailed, Canceled, OutOfMemory };

/// Every byte of `file`, in memory from `gpa` the caller frees: for a file
/// held whole, its bytes checked as a whole by the caller.
pub fn readWhole(io: Io, file: Io.File, gpa: Allocator) WholeError![]u8 {
    return aegis.own.readOpened(io, file, gpa, .fromRaw(std.math.maxInt(u64))) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.ReadFailed,
    };
}
