//! A segment's files: their names, and the frame each carries. A segment is
//! one file, written once in one pass, its sections in a fixed order and a
//! table of them at its end (Lucene's compound file, its entries table
//! inside it); a deletion generation is a file of its own, since it changes
//! while the segment does not.
//!
//! Every file begins with a header:
//!
//!     0   magic "probeidx"
//!     8   format, u16
//!     10  kind, u8
//!     11  zero, 5 bytes
//!     16  segment, u64
//!
//! A segment file then holds its sections, each `Section` in order, one
//! after another from the header to the table; the table, per section its
//! offset in the file and its length, u64 each, and its CRC-32C, u32; and a
//! footer, the CRC-32C of the table, u32. A deletions file holds its body
//! after the header, and a footer, the CRC-32C of every byte before it.
//! Integers are little endian.
//!
//! A segment is read back through `checkSegment`, which checks every
//! section's CRC-32C, or through `openSegment`, which checks its header and
//! its table, and leaves each section's checksum to the reader that reads
//! it whole and to `verify`; a deletions file through `check`. Each refuses
//! a file whose bytes break any of this: a file of another kind or another
//! segment under this name, sections that do not lie end to end from the
//! header to the table, or a newer format.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const warp = @import("warp");
const source_mod = @import("source.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Source = source_mod.Source;

/// What a file holds.
pub const Kind = enum(u8) {
    /// A segment: its sections and their table.
    segment = 1,
    /// A generation's deletions.
    deletions = 2,

    /// The file name's extension.
    pub fn extension(k: Kind) []const u8 {
        return switch (k) {
            .segment => "seg",
            .deletions => "del",
        };
    }
};

/// A segment's sections, in the order its file holds them.
pub const Section = enum(u8) {
    /// Each field's term dictionary.
    terms,
    /// Doc ids in packed blocks, with skip entries.
    postings,
    /// Positions and offsets.
    positions,
    /// Each document's length per text field.
    lengths,
    /// Numeric columns.
    columns,
    /// External ids to doc ids.
    ids,
    /// Stored fields.
    store,
};

pub const section_count = std.enums.values(Section).len;

/// A segment's sections' bytes, by section.
pub const Sections = [section_count][]const u8;

/// The format this build writes and the newest it reads.
pub const format: u16 = 1;

const magic = "probeidx";

pub const header_bytes = 24;
pub const footer_bytes = 4;
const entry_bytes = 8 + 8 + 4;
pub const table_bytes = section_count * entry_bytes;

/// The longest file name `name` gives.
pub const max_name_bytes = 16 + 1 + 3 + 1 + 16;

/// A file's name in the index directory: the segment in sixteen hex
/// digits and the kind's extension, and for deletions their generation
/// (`000000000000002a.seg`, `000000000000002a.del.0000000000000003`).
pub fn name(buffer: *[max_name_bytes]u8, segment: u64, kind: Kind, generation: u64) []const u8 {
    return switch (kind) {
        .deletions => std.mem.print(buffer, "{x:0>16}.del.{x:0>16}", .{ segment, generation }),
        .segment => std.mem.print(buffer, "{x:0>16}.seg", .{segment}),
    } catch aegis.assert.never("a name fits max_name_bytes");
}

/// What a file's name says.
pub const Named = struct {
    segment: u64,
    kind: Kind,
    /// A deletions file's generation; 0 for a segment.
    generation: u64 = 0,
};

/// What `entry` names, if it is a file's name exactly as `name` writes it.
pub fn parseName(entry: []const u8) ?Named {
    if (entry.len < 18 or entry[16] != '.') return null;
    const segment = hex(entry[0..16]) orelse return null;
    const rest = entry[17..];
    if (std.mem.eql(u8, rest, "seg")) return .{ .segment = segment, .kind = .segment };
    if (rest.len != 4 + 16 or !std.mem.startsWith(u8, rest, "del.")) return null;
    return .{ .segment = segment, .kind = .deletions, .generation = hex(rest[4..][0..16]) orelse return null };
}

/// Sixteen lowercase hex digits' value.
fn hex(digits: *const [16]u8) ?u64 {
    var value: u64 = 0;
    for (digits) |c| {
        const digit: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            else => return null,
        };
        value = (value << 4) | digit;
    }
    return value;
}

/// The header of a file of `kind` for `segment`.
pub fn header(kind: Kind, segment: u64) [header_bytes]u8 {
    var h: [header_bytes]u8 = @splat(0);
    h[0..8].* = magic.*;
    std.mem.writeInt(u16, h[8..10], format, .little);
    h[10] = @backingInt(kind);
    std.mem.writeInt(u64, h[16..24], segment, .little);
    return h;
}

/// A footer: `crc`, a CRC-32C, as four bytes.
pub fn footer(crc: u32) [footer_bytes]u8 {
    var f: [footer_bytes]u8 = undefined;
    std.mem.writeInt(u32, &f, crc, .little);
    return f;
}

/// The CRC-32C of `bytes`, continued from `crc` (0 starts one).
pub fn crc32c(crc: u32, bytes: []const u8) u32 {
    return warp.crc32c(crc, bytes);
}

/// Appends to `out` the file of `segment` holding `sections`: its header,
/// each section in order, their table and its footer.
pub fn appendSegment(gpa: Allocator, out: *std.ArrayList(u8), segment: u64, sections: *const Sections) Allocator.Error!void {
    var total: usize = header_bytes + table_bytes + footer_bytes;
    for (sections) |s| total += s.len;
    try out.ensureUnusedCapacity(gpa, total);
    const start = out.items.len;
    out.appendSliceAssumeCapacity(&header(.segment, segment));
    var table: [table_bytes]u8 = undefined;
    for (sections, 0..) |bytes, i| {
        const e = table[i * entry_bytes ..][0..entry_bytes];
        std.mem.writeInt(u64, e[0..8], out.items.len - start, .little);
        std.mem.writeInt(u64, e[8..16], bytes.len, .little);
        std.mem.writeInt(u32, e[16..20], crc32c(0, bytes), .little);
        out.appendSliceAssumeCapacity(bytes);
    }
    out.appendSliceAssumeCapacity(&table);
    out.appendSliceAssumeCapacity(&footer(crc32c(0, &table)));
}

/// A deletions file's body: the bytes between its header and its footer.
pub const Body = struct {
    bytes: []const u8,
};

pub const CheckError = error{
    /// Too short for its frame, a magic, kind, segment or zero byte that is
    /// not this file's, sections that do not lie end to end, or a CRC-32C
    /// that does not match.
    Corrupt,
    /// A format newer than this build reads.
    VersionTooNew,
};

pub const OpenError = CheckError || source_mod.Error;

/// A section's place in its segment's file, and its CRC-32C.
pub const Entry = struct {
    offset: u64,
    len: u64,
    crc: u32,
};

/// A segment's table, checked: its sections lie end to end from the header
/// to the table.
pub const Table = struct {
    entries: [section_count]Entry,

    pub fn of(t: Table, section: Section) Entry {
        return t.entries[@backingInt(section)];
    }

    /// `bytes`, read whole from `section`'s place, refused unless they are
    /// what its CRC-32C says.
    pub fn checkSection(t: Table, section: Section, bytes: []const u8) error{Corrupt}!void {
        if (crc32c(0, bytes) != t.of(section).crc) return error.Corrupt;
    }

    /// The table and footer at the end of a file of `len` bytes, read back.
    fn parse(table: *const [table_bytes]u8, stored: *const [footer_bytes]u8, len: u64) CheckError!Table {
        if (crc32c(0, table) != std.mem.readInt(u32, stored, .little)) return error.Corrupt;
        var t: Table = undefined;
        var expected: u64 = header_bytes;
        for (&t.entries, 0..) |*entry, i| {
            const e = table[i * entry_bytes ..][0..entry_bytes];
            entry.* = .{
                .offset = std.mem.readInt(u64, e[0..8], .little),
                .len = std.mem.readInt(u64, e[8..16], .little),
                .crc = std.mem.readInt(u32, e[16..20], .little),
            };
            if (entry.offset != expected or entry.len > len - expected) return error.Corrupt;
            expected += entry.len;
        }
        if (expected != len - table_bytes - footer_bytes) return error.Corrupt;
        return t;
    }
};

/// What a file must be: its kind and its segment.
pub const Expected = struct {
    kind: Kind,
    segment: u64,

    /// A deletions file `file` read back: its body, once its header says it
    /// is this file in a format this build reads and its CRC-32C matches.
    pub fn check(e: Expected, file: aegis.input.Untrusted([]const u8)) CheckError!Body {
        return file.parse(e, readWhole);
    }

    fn readWhole(e: Expected, bytes: []const u8) CheckError!Body {
        if (bytes.len < header_bytes + footer_bytes) return error.Corrupt;
        try e.checkHeader(bytes[0..header_bytes]);
        const end = bytes.len - footer_bytes;
        if (crc32c(0, bytes[0..end]) != std.mem.readInt(u32, bytes[end..][0..4], .little)) return error.Corrupt;
        return .{ .bytes = bytes[header_bytes..end] };
    }

    /// A segment file `file` read back from memory: each section, once its
    /// header, its table and every section's CRC-32C are as they must be.
    pub fn checkSegment(e: Expected, file: aegis.input.Untrusted([]const u8)) CheckError!Sections {
        return file.parse(e, readSegment);
    }

    fn readSegment(e: Expected, bytes: []const u8) CheckError!Sections {
        if (bytes.len < header_bytes + table_bytes + footer_bytes) return error.Corrupt;
        try e.checkHeader(bytes[0..header_bytes]);
        const end = bytes.len - footer_bytes;
        const t = try Table.parse(bytes[end - table_bytes ..][0..table_bytes], bytes[end..][0..footer_bytes], bytes.len);
        var sections: Sections = undefined;
        for (&sections, std.enums.values(Section)) |*s, section| {
            const entry = t.of(section);
            s.* = bytes[@intCast(entry.offset)..][0..@intCast(entry.len)];
            try t.checkSection(section, s.*);
        }
        return sections;
    }

    fn checkHeader(e: Expected, h: *const [header_bytes]u8) CheckError!void {
        if (!std.mem.eql(u8, h[0..8], magic)) return error.Corrupt;
        const version = std.mem.readInt(u16, h[8..10], .little);
        if (version == 0) return error.Corrupt;
        if (version > format) return error.VersionTooNew;
        if (h[10] != @backingInt(e.kind)) return error.Corrupt;
        for (h[11..16]) |b| if (b != 0) return error.Corrupt;
        if (std.mem.readInt(u64, h[16..24], .little) != e.segment) return error.Corrupt;
    }

    /// The table of the segment file `file`, read on `io`, once its header
    /// says it is this segment in a format this build reads and the table
    /// is whole. Its sections' checksums are not read here.
    pub fn openSegment(e: Expected, io: Io, file: Io.File) OpenError!Table {
        aegis.assert.invariant(e.kind == .segment, "a segment's table is a segment file's");
        const len = file.length(io) catch |err| return failed(err);
        if (len < header_bytes + table_bytes + footer_bytes) return error.Corrupt;
        const whole: Source = .{ .file = .{ .file = .of(file), .start = 0, .len = len } };
        var h: [header_bytes]u8 = undefined;
        try whole.read(io, 0, &h);
        try e.checkHeader(&h);
        var tail: [table_bytes + footer_bytes]u8 = undefined;
        try whole.read(io, len - tail.len, &tail);
        return Table.parse(tail[0..table_bytes], tail[table_bytes..], len);
    }

    /// Whether `file` holds every byte its checksums say, read whole on
    /// `io` through `buffer`: a segment's every section and its table, a
    /// deletions file's every byte.
    pub fn verify(e: Expected, io: Io, file: Io.File, buffer: []u8) OpenError!void {
        aegis.assert.invariant(buffer.len > 0, "a buffer to read through");
        const len = file.length(io) catch |err| return failed(err);
        const whole: Source = .{ .file = .{ .file = .of(file), .start = 0, .len = len } };
        switch (e.kind) {
            .segment => {
                const t = try e.openSegment(io, file);
                for (std.enums.values(Section)) |section| {
                    const entry = t.of(section);
                    if (try crcOf(io, whole, entry.offset, entry.len, buffer) != entry.crc) return error.Corrupt;
                }
            },
            .deletions => {
                if (len < header_bytes + footer_bytes) return error.Corrupt;
                var h: [header_bytes]u8 = undefined;
                try whole.read(io, 0, &h);
                try e.checkHeader(&h);
                var f: [footer_bytes]u8 = undefined;
                try whole.read(io, len - footer_bytes, &f);
                if (try crcOf(io, whole, 0, len - footer_bytes, buffer) != std.mem.readInt(u32, &f, .little)) return error.Corrupt;
            },
        }
    }
};

/// The CRC-32C of `len` bytes of `whole` from `offset`, read through
/// `buffer`.
fn crcOf(io: Io, whole: Source, offset: u64, len: u64, buffer: []u8) OpenError!u32 {
    var crc: u32 = 0;
    var at: u64 = 0;
    while (at < len) {
        const n: usize = @intCast(@min(buffer.len, len - at));
        try whole.read(io, offset + at, buffer[0..n]);
        crc = crc32c(crc, buffer[0..n]);
        at += n;
    }
    return crc;
}

fn failed(err: Io.File.LengthError) OpenError {
    return switch (err) {
        error.Canceled => error.Canceled,
        else => error.ReadFailed,
    };
}
