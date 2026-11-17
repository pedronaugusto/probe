//! The segment layer: one segment's files, written once and read back
//! checked. Each part is its own file under `segment/`.
//!
//! This file is internal. `probe.zig` is the package.

/// A segment's file names, and the header and footer each file carries.
pub const files = @import("segment/files.zig");
