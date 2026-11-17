//! A segment the writer and its readers hold at once, counted
//! (`aegis.Shared`): read from its file once committed, or from the bytes
//! of a segment closed since the last commit. The last handle released
//! closes its file and frees what it holds, so a snapshot keeps every
//! segment it names for as long as it is open, whatever the writer does
//! meanwhile.
//!
//! `aegis.Shared` cleans up without an `Io`, so a held segment keeps the
//! `Io` it was opened on, to close its file with. The move to aegis 0.3.0
//! takes `aegis.SharedIo`, whose last `release(io)` closes it through the
//! releaser's `Io`, and drops the `io` field in the same commit.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const Opened = @import("Opened.zig");
const segment = @import("segment.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Held = @This();

/// One owner of a held segment.
pub const Handle = aegis.Shared(Held, release);

/// A segment closed since the last commit: its file's bytes, and the
/// segment read over them.
pub const Memory = struct {
    file: std.ArrayList(u8),
    segment: segment.read.Segment,
};

gpa: Allocator,
io: Io,
number: u64,
docs: u32,
from: union(enum) {
    file: Opened,
    memory: Memory,
},

pub fn read(h: *const Held) *const segment.read.Segment {
    return switch (h.from) {
        .file => |*o| &o.segment,
        .memory => |*m| &m.segment,
    };
}

fn release(h: *Held) void {
    switch (h.from) {
        .file => |*o| o.deinit(h.gpa, h.io),
        .memory => |*m| {
            m.segment.deinit(h.gpa);
            m.file.deinit(h.gpa);
        },
    }
}
