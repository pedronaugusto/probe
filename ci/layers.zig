//! Source layers, lowest first. Every production source has one place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "vocabulary", .patterns = &.{ "src/ids.zig", "src/Limits.zig", "src/Schema.zig" } },
    .{ .name = "analysis", .patterns = &.{ "src/analysis/words.zig", "src/analysis/identifier.zig", "src/analysis/Pipeline.zig" } },
    .{ .name = "analysis entry", .patterns = &.{"src/analysis.zig"} },
    .{ .name = "encoding base", .patterns = &.{"src/encoding/varint.zig"} },
    .{ .name = "encoding", .patterns = &.{ "src/encoding/bitpack.zig", "src/encoding/fst.zig", "src/encoding/bitmap.zig" } },
    .{ .name = "encoding entry", .patterns = &.{"src/encoding.zig"} },
    .{ .name = "segment source", .patterns = &.{"src/segment/source.zig"} },
    .{ .name = "segment", .patterns = &.{ "src/segment/files.zig", "src/segment/postings.zig", "src/segment/positions.zig", "src/segment/terms.zig", "src/segment/columns.zig", "src/segment/store.zig" } },
    .{ .name = "segment whole", .patterns = &.{ "src/segment/write.zig", "src/segment/read.zig" } },
    .{ .name = "segment entry", .patterns = &.{"src/segment.zig"} },
    .{ .name = "index base", .patterns = &.{"src/Manifest.zig"} },
    .{ .name = "index segment", .patterns = &.{ "src/Opened.zig", "src/committed.zig" } },
    .{ .name = "index held", .patterns = &.{"src/Held.zig"} },
    .{ .name = "index reader", .patterns = &.{"src/Reader.zig"} },
    .{ .name = "index merge", .patterns = &.{"src/merge.zig"} },
    .{ .name = "index", .patterns = &.{"src/Writer.zig"} },
    .{ .name = "query base", .patterns = &.{ "src/bm25.zig", "src/query/Tree.zig", "src/query/phrase.zig", "src/query/wand.zig", "src/query/pattern.zig", "src/query/parse.zig" } },
    .{ .name = "query", .patterns = &.{"src/query/exec.zig"} },
    .{ .name = "query entry", .patterns = &.{"src/query.zig"} },
    .{ .name = "index api", .patterns = &.{"src/index.zig"} },
    .{ .name = "public", .patterns = &.{"src/probe.zig"} },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{};

const package_references = [_]gantry.rules.ReferenceRule{
    .{
        .name = "named dependencies",
        .unresolved_only = true,
        .except_targets = &.{ "std", "aegis", "xenoglyph", "warp", "strand", "airlock", "airlock.testing", "spectra", "shakedown", "builtin" },
    },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

/// A family package is reached through its module name, never by a path into it.
pub const references: []const gantry.rules.ReferenceRule = &package_references;

/// Every production source, so a file added without a layer is refused.
pub const required = [_][]const u8{
    "src/ids.zig",
    "src/Limits.zig",
    "src/Schema.zig",
    "src/analysis/words.zig",
    "src/analysis/identifier.zig",
    "src/analysis/Pipeline.zig",
    "src/analysis.zig",
    "src/encoding/varint.zig",
    "src/encoding/bitpack.zig",
    "src/encoding/fst.zig",
    "src/encoding/bitmap.zig",
    "src/encoding.zig",
    "src/segment/source.zig",
    "src/segment/files.zig",
    "src/segment/postings.zig",
    "src/segment/positions.zig",
    "src/segment/terms.zig",
    "src/segment/columns.zig",
    "src/segment/store.zig",
    "src/segment/write.zig",
    "src/segment/read.zig",
    "src/segment.zig",
    "src/Manifest.zig",
    "src/Opened.zig",
    "src/committed.zig",
    "src/Held.zig",
    "src/Reader.zig",
    "src/merge.zig",
    "src/Writer.zig",
    "src/bm25.zig",
    "src/query/Tree.zig",
    "src/query/phrase.zig",
    "src/query/wand.zig",
    "src/query/pattern.zig",
    "src/query/parse.zig",
    "src/query/exec.zig",
    "src/query.zig",
    "src/index.zig",
    "src/probe.zig",
};
