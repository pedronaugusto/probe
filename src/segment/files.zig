//! A segment's files: their names, and the header and footer every one of
//! them carries. A file is its header, its body and a CRC-32C of both:
//!
//!     0   magic "probeidx"
//!     8   format, u16
//!     10  kind, u8
//!     11  zero, 5 bytes
//!     16  segment, u64
//!     24  body
//!     end CRC-32C of every byte before it, u32
//!
//! Integers are little endian. A file is read back only through `check`,
//! which refuses one whose bytes break any of this: a file of another kind
//! or another segment under this name, or of a newer format.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const warp = @import("warp");

/// What a file holds.
pub const Kind = enum(u8) {
    /// Each field's term dictionary.
    terms = 1,
    /// Doc ids in packed blocks, with skip entries.
    postings = 2,
    /// Positions and offsets.
    positions = 3,
    /// Each document's length per text field.
    lengths = 4,
    /// Numeric columns.
    columns = 5,
    /// External ids to doc ids.
    ids = 6,
    /// Stored fields.
    store = 7,
    /// A generation's deletions.
    deletions = 8,

    /// The file name's extension.
    pub fn extension(k: Kind) []const u8 {
        return switch (k) {
            .terms => "terms",
            .postings => "post",
            .positions => "pos",
            .lengths => "len",
            .columns => "cols",
            .ids => "ids",
            .store => "store",
            .deletions => "del",
        };
    }
};

/// The format this build writes and the newest it reads.
pub const format: u16 = 1;

const magic = "probeidx";

pub const header_bytes = 24;
pub const footer_bytes = 4;

/// The longest file name `name` gives.
pub const max_name_bytes = 16 + 1 + 5 + 1 + 16;

/// A file's name in the index directory: the segment in sixteen hex
/// digits and the kind's extension, and for deletions their generation
/// (`000000000000002a.del.0000000000000003`).
pub fn name(buffer: *[max_name_bytes]u8, segment: u64, kind: Kind, generation: u64) []const u8 {
    return switch (kind) {
        .deletions => std.mem.print(buffer, "{x:0>16}.del.{x:0>16}", .{ segment, generation }),
        else => std.mem.print(buffer, "{x:0>16}.{s}", .{ segment, kind.extension() }),
    } catch aegis.assert.never("a name fits max_name_bytes");
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

/// The footer that ends a file: `crc`, the CRC-32C a writer kept over
/// every byte before it.
pub fn footer(crc: u32) [footer_bytes]u8 {
    var f: [footer_bytes]u8 = undefined;
    std.mem.writeInt(u32, &f, crc, .little);
    return f;
}

/// The CRC-32C of `bytes`, continued from `crc` (0 starts one).
pub fn crc32c(crc: u32, bytes: []const u8) u32 {
    return warp.crc32c(crc, bytes);
}

/// A checked file's body: the bytes between its header and its footer.
pub const Body = struct {
    bytes: []const u8,
};

pub const CheckError = error{
    /// Too short for a header and a footer, a magic, kind, segment or zero
    /// byte that is not this file's, or a CRC-32C that does not match.
    Corrupt,
    /// A format newer than this build reads.
    VersionTooNew,
};

/// What a file must be: its kind and its segment.
pub const Expected = struct {
    kind: Kind,
    segment: u64,

    /// `file` read back: its body, once its header says it is this file
    /// in a format this build reads and its CRC-32C matches.
    pub fn check(e: Expected, file: aegis.input.Untrusted([]const u8)) CheckError!Body {
        return file.parse(e, read);
    }

    fn read(e: Expected, bytes: []const u8) CheckError!Body {
        if (bytes.len < header_bytes + footer_bytes) return error.Corrupt;
        if (!std.mem.eql(u8, bytes[0..8], magic)) return error.Corrupt;
        const version = std.mem.readInt(u16, bytes[8..10], .little);
        if (version == 0) return error.Corrupt;
        if (version > format) return error.VersionTooNew;
        if (bytes[10] != @backingInt(e.kind)) return error.Corrupt;
        for (bytes[11..16]) |b| if (b != 0) return error.Corrupt;
        if (std.mem.readInt(u64, bytes[16..24], .little) != e.segment) return error.Corrupt;
        const end = bytes.len - footer_bytes;
        const stored = std.mem.readInt(u32, bytes[end..][0..4], .little);
        if (crc32c(0, bytes[0..end]) != stored) return error.Corrupt;
        return .{ .bytes = bytes[header_bytes..end] };
    }
};
