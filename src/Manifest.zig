//! An index's manifest: the commit's generation, the schema it was written
//! with, and its live segments, each with its documents and its deletion
//! generation. JSON through strand, a few lines a person can read.
//!
//! Each commit writes a manifest of its own, named by its generation
//! (`manifest.` and the generation in 16 hex digits), published whole by a
//! rename (airlock), so a reader that finds a name finds all of it. The
//! newest generation is the index; older ones stay for the readers of
//! other processes until the writer's retention lets them go.
//!
//! What is read is checked: a format this build reads (`VersionTooNew`
//! otherwise), the generation the name says, the schema and term length
//! the index is opened with (`SchemaMismatch` otherwise), segment numbers
//! rising and below the next one to be given, each segment holding a
//! document, and deletions each counting at least one document and fewer
//! than the segment's, of a generation no later than the manifest's. Bytes
//! that break a rule are `error.Corrupt`. A segment's files carry their own
//! checksums; the manifest's checks are its structure's.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const strand = @import("strand");
const Schema = @import("Schema.zig");

const Allocator = std.mem.Allocator;
const Manifest = @This();

/// The format this build writes, and the newest it reads.
pub const current_format: u16 = 1;

format: u16 = current_format,
/// The commit's generation: each commit's is one past the one before.
generation: u64,
/// The number the next segment written will take.
next_segment: u64,
/// The longest term the index holds, in bytes (`Limits.term_bytes`).
term_bytes: u16,
fields: []const Field,
segments: []const Segment,

/// A field as a manifest records it: what the index's files depend on. A
/// field's scoring parameters are read when a query is scored and are not
/// recorded, so an index opens with any.
pub const Field = struct {
    name: []const u8,
    kind: Schema.Kind,
    positions: bool = false,
    offsets: bool = false,
    analysis: Schema.Analysis = .words,
    stored: bool = false,

    pub fn of(f: Schema.Field) Field {
        return .{ .name = f.name, .kind = f.kind, .positions = f.positions, .offsets = f.offsets, .analysis = f.analysis, .stored = f.stored };
    }
};

/// The fields of `schema` as a manifest records them, on `arena`.
pub fn fieldsOf(arena: Allocator, schema: []const Schema.Field) Allocator.Error![]const Field {
    const out = try arena.alloc(Field, schema.len);
    for (schema, out) |f, *o| o.* = .of(f);
    return out;
}

/// A live segment.
pub const Segment = struct {
    /// Its number, which names its files.
    number: u64,
    /// Its documents, deleted ones included.
    docs: u32,
    /// Its deletion bitmap, if any of its documents is deleted.
    deletions: ?Deletions = null,
};

/// A segment's current deletion bitmap.
pub const Deletions = struct {
    /// The generation that names its file.
    generation: u64,
    /// The documents it deletes.
    count: u32,
};

pub const prefix = "manifest.";

/// The length of every manifest's name.
pub const name_bytes = prefix.len + 16;

/// The name of the manifest of `generation`.
pub fn name(buffer: *[name_bytes]u8, generation: u64) []const u8 {
    return std.mem.print(buffer, prefix ++ "{x:0>16}", .{generation}) catch aegis.assert.never("a name fits name_bytes");
}

/// The generation `entry` names, if it is a manifest's name exactly as
/// `name` writes it.
pub fn generationOf(entry: []const u8) ?u64 {
    if (entry.len != name_bytes or !std.mem.startsWith(u8, entry, prefix)) return null;
    var generation: u64 = 0;
    for (entry[prefix.len..]) |c| {
        const digit: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            else => return null,
        };
        generation = (generation << 4) | digit;
    }
    return generation;
}

pub const WriteError = std.Io.Writer.Error;

/// Writes `m` as its manifest file's bytes.
pub fn write(m: Manifest, out: *std.Io.Writer) WriteError!void {
    strand.json.write(out, m, .{ .whitespace = .indent_2 }) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        else => aegis.assert.never("a manifest's every value has a JSON spelling"),
    };
    try out.writeByte('\n');
}

pub const ParseError = error{
    /// Not a manifest, or one that breaks a rule.
    Corrupt,
    /// A format newer than this build reads.
    VersionTooNew,
    /// Written with other fields or another term length than the index is
    /// opened with.
    SchemaMismatch,
    OutOfMemory,
};

/// What a manifest read back must be.
pub const Expected = struct {
    /// The generation its name says.
    generation: u64,
    fields: []const Field,
    term_bytes: u16,
    /// Told what differs when the manifest is `SchemaMismatch`.
    mismatch: ?*Mismatch = null,
};

/// What differs in a manifest that is `SchemaMismatch`: the first field, by
/// place, recorded otherwise than asked or held by one of them alone, or
/// else the term length; each as recorded and as asked.
pub const Mismatch = struct {
    what: What = undefined,
    /// Holds the recorded field's name, cut to its length.
    name_buffer: [max_name_bytes]u8 = undefined,

    pub const max_name_bytes = 128;

    pub const What = union(enum) {
        /// A side that has no field at `place` is null.
        field: struct { place: usize, recorded: ?Field, asked: ?Field },
        term_bytes: struct { recorded: u16, asked: u16 },
    };
};

const Context = struct {
    arena: Allocator,
    expected: Expected,
};

/// The manifest `bytes` hold, on `arena`, once it passes every check.
pub fn parse(arena: Allocator, bytes: aegis.input.Untrusted([]const u8), expected: Expected) ParseError!Manifest {
    return bytes.parse(Context{ .arena = arena, .expected = expected }, read);
}

fn read(c: Context, bytes: []const u8) ParseError!Manifest {
    // The format first, so a newer manifest is told from a broken one.
    const Format = struct { format: u16 };
    const format = strand.json.parseLeaky(Format, c.arena, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    if (format.format == 0) return error.Corrupt;
    if (format.format > current_format) return error.VersionTooNew;
    const m = strand.json.parseLeaky(Manifest, c.arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    if (m.generation != c.expected.generation) return error.Corrupt;
    if (firstDifference(m.fields, c.expected.fields)) |place| {
        if (c.expected.mismatch) |out| {
            var recorded: ?Field = if (place < m.fields.len) m.fields[place] else null;
            if (recorded) |*r| {
                const len = @min(r.name.len, Mismatch.max_name_bytes);
                @memcpy(out.name_buffer[0..len], r.name[0..len]);
                r.name = out.name_buffer[0..len];
            }
            out.what = .{ .field = .{ .place = place, .recorded = recorded, .asked = if (place < c.expected.fields.len) c.expected.fields[place] else null } };
        }
        return error.SchemaMismatch;
    }
    if (m.term_bytes != c.expected.term_bytes) {
        if (c.expected.mismatch) |out| out.what = .{ .term_bytes = .{ .recorded = m.term_bytes, .asked = c.expected.term_bytes } };
        return error.SchemaMismatch;
    }
    var before: ?u64 = null;
    for (m.segments) |s| {
        if (before) |b| if (s.number <= b) return error.Corrupt;
        if (s.number >= m.next_segment or s.docs == 0) return error.Corrupt;
        if (s.deletions) |d| {
            if (d.count == 0 or d.count >= s.docs or d.generation > m.generation) return error.Corrupt;
        }
        before = s.number;
    }
    return m;
}

/// The first place where `got` and `want` differ, or one has a field the
/// other has not; null when they are the same.
fn firstDifference(got: []const Field, want: []const Field) ?usize {
    for (0..@min(got.len, want.len)) |place| {
        const g = got[place];
        const w = want[place];
        if (!std.mem.eql(u8, g.name, w.name) or g.kind != w.kind or g.positions != w.positions or
            g.offsets != w.offsets or g.analysis != w.analysis or g.stored != w.stored) return place;
    }
    return if (got.len == want.len) null else @min(got.len, want.len);
}
