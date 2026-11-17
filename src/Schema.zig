//! A document type's fields as probe indexes them, read at compile time
//! from the type's `pub const probe` declaration:
//!
//!     pub const probe = .{
//!         .id = .seq,
//!         .fields = .{
//!             .at = .{ .numeric = .{} },
//!             .level = .{ .keyword = .{ .stored = true } },
//!             .message = .{ .text = .{ .positions = true, .offsets = true, .analysis = .words_and_identifiers } },
//!         },
//!     };
//!
//! `id` names the field holding the document's id, a `u64` or an aegis id
//! of `u64`. Each field is a field of the type: `text` and `keyword` of
//! `[]const u8`, `numeric` of `u64`, `i64` or an aegis scalar of either
//! (an instant, a count, an id). A declaration that cannot work does not
//! compile, and says why.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");

/// How a field is indexed.
pub const Kind = enum {
    /// Analyzed into terms, each with its frequency and, when asked, its
    /// positions and byte offsets.
    text,
    /// One exact term, the field's bytes as they are.
    keyword,
    /// A column value, for ranges and sorting.
    numeric,
};

/// How a text field is cut into terms.
pub const Analysis = enum {
    /// Unicode words (UAX #29), case-folded.
    words,
    /// Words, and each identifier's parts as well: `parseSpan` is also
    /// `parse` and `span`.
    words_and_identifiers,
};

/// One field as declared.
pub const Field = struct {
    name: []const u8,
    kind: Kind,
    positions: bool = false,
    offsets: bool = false,
    analysis: Analysis = .words,
    stored: bool = false,
};

/// The schema `Doc` declares.
pub fn Of(comptime Doc: type) type {
    if (!@hasDecl(Doc, "probe")) @compileError("probe: " ++ @typeName(Doc) ++ " declares no `pub const probe = .{ .id = ..., .fields = .{ ... } }`");
    const declared = Doc.probe;
    if (!@hasField(@TypeOf(declared), "id") or !@hasField(@TypeOf(declared), "fields")) @compileError("probe: " ++ @typeName(Doc) ++ ".probe names an `id` and its `fields`");
    const id_name = @tagName(declared.id);
    if (!@hasField(Doc, id_name)) @compileError("probe: the id `" ++ id_name ++ "` is not a field of " ++ @typeName(Doc));
    if (ColumnRepr(@FieldType(Doc, id_name)) != u64) @compileError("probe: the id `" ++ id_name ++ "` is a u64 or an aegis id of u64");
    const entries = @typeInfo(@TypeOf(declared.fields)).@"struct".field_names;
    if (entries.len == 0) @compileError("probe: " ++ @typeName(Doc) ++ " declares no field to index");
    comptime var list: [entries.len]Field = undefined;
    inline for (entries, 0..) |entry, i| list[i] = fieldOf(Doc, entry, @field(declared.fields, entry));
    const fields = list;
    return struct {
        pub const id_field = id_name;
        pub const all: []const Field = &fields;

        /// The place of field `name` in `all`.
        pub fn indexOf(comptime name: []const u8) usize {
            inline for (fields, 0..) |f, i| if (comptime std.mem.eql(u8, f.name, name)) return i;
            @compileError("probe: no field \"" ++ name ++ "\" is declared on " ++ @typeName(Doc));
        }
    };
}

fn fieldOf(comptime Doc: type, comptime name: []const u8, comptime spec: anytype) Field {
    if (!@hasField(Doc, name)) @compileError("probe: the field `" ++ name ++ "` is not a field of " ++ @typeName(Doc));
    const kinds = @typeInfo(@TypeOf(spec)).@"struct".field_names;
    if (kinds.len != 1) @compileError("probe: the field `" ++ name ++ "` is one of .text, .keyword or .numeric");
    const kind = std.meta.stringToEnum(Kind, kinds[0]) orelse @compileError("probe: the field `" ++ name ++ "` is one of .text, .keyword or .numeric, not ." ++ kinds[0]);
    const options = @field(spec, kinds[0]);
    const T = @FieldType(Doc, name);
    switch (kind) {
        .text, .keyword => if (T != []const u8) @compileError("probe: the " ++ @tagName(kind) ++ " field `" ++ name ++ "` is a []const u8"),
        .numeric => if (ColumnRepr(T) == void) @compileError("probe: the numeric field `" ++ name ++ "` is a u64, an i64 or an aegis scalar of either"),
    }
    var field: Field = .{ .name = name, .kind = kind };
    inline for (@typeInfo(@TypeOf(options)).@"struct".field_names) |option| {
        const value = @field(options, option);
        if (comptime std.mem.eql(u8, option, "stored")) {
            field.stored = value;
        } else if (kind != .text) {
            @compileError("probe: ." ++ option ++ " is a text field's option, and `" ++ name ++ "` is " ++ @tagName(kind));
        } else if (comptime std.mem.eql(u8, option, "positions")) {
            field.positions = value;
        } else if (comptime std.mem.eql(u8, option, "offsets")) {
            field.offsets = value;
        } else if (comptime std.mem.eql(u8, option, "analysis")) {
            field.analysis = value;
        } else @compileError("probe: the field `" ++ name ++ "` has no option ." ++ option);
    }
    if (field.offsets and !field.positions) @compileError("probe: the field `" ++ name ++ "` keeps offsets only with its positions");
    return field;
}

/// The integer a column holds a value of `T` as: `u64` or `i64`, or void
/// when `T` is neither nor an aegis scalar of either.
pub fn ColumnRepr(comptime T: type) type {
    if (T == u64 or T == i64) return T;
    const container = switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union" => true,
        else => false,
    };
    if (container and @hasDecl(T, "aegis_scalar")) {
        const R = T.aegis_scalar.representation;
        if (R == u64 or R == i64) return R;
    }
    return void;
}

/// A numeric value as its column's `u64`, keeping its order: an unsigned
/// value as it is, a signed one with its sign bit flipped.
pub fn columnValue(value: anytype) u64 {
    const T = @TypeOf(value);
    const raw = if (comptime T == u64 or T == i64) value else value.raw();
    return switch (@TypeOf(raw)) {
        u64 => raw,
        i64 => @as(u64, @bitCast(raw)) ^ (@as(u64, 1) << 63),
        else => comptime unreachable,
    };
}
