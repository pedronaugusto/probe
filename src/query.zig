//! The query layer: a query's tree and its run over a snapshot. Each part
//! is its own file under `query/`.
//!
//! This file is internal. `probe.zig` is the package.

/// A query as a tree of nodes, and what each matches and scores.
pub const Tree = @import("query/Tree.zig");

/// A phrase's frequency in a document, from its terms' positions.
pub const phrase = @import("query/phrase.zig");

/// Upper bounds on scores, for block-max WAND.
pub const wand = @import("query/wand.zig");

/// A query run over a snapshot: its best hits, or its count.
pub const exec = @import("query/exec.zig");
