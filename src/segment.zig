//! The segment layer: one segment's files, written once and read back
//! checked. Each part is its own file under `segment/`.
//!
//! This file is internal. `probe.zig` is the package.

/// A segment's file names, and the header and footer each file carries.
pub const files = @import("segment/files.zig");

/// One term's postings: documents and frequencies in blocks of 128, with
/// a skip entry and impacts per block.
pub const postings = @import("segment/postings.zig");

/// One term's positions and offsets, a chunk per postings block.
pub const positions = @import("segment/positions.zig");
