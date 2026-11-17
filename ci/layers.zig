//! Source layers, lowest first. Every production source has one place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "vocabulary", .patterns = &.{ "src/ids.zig", "src/Limits.zig", "src/Schema.zig" } },
    .{ .name = "encoding", .patterns = &.{ "src/encoding/bitpack.zig", "src/encoding/fst.zig", "src/encoding/bitmap.zig" } },
    .{ .name = "encoding entry", .patterns = &.{"src/encoding.zig"} },
    .{ .name = "public", .patterns = &.{"src/probe.zig"} },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{};

const package_references = [_]gantry.rules.ReferenceRule{
    .{
        .name = "named dependencies",
        .unresolved_only = true,
        .except_targets = &.{ "std", "aegis", "shakedown", "builtin" },
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
    "src/encoding/bitpack.zig",
    "src/encoding/fst.zig",
    "src/encoding/bitmap.zig",
    "src/encoding.zig",
    "src/probe.zig",
};
