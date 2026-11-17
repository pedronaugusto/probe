//! The analysis layer: how a text field becomes terms. Each stage is its
//! own file under `analysis/`.
//!
//! This file is internal. `probe.zig` is the package.

/// A text's words by UAX #29, and a term's NFKC_Casefold.
pub const words = @import("analysis/words.zig");

/// An identifier's parts.
pub const identifier = @import("analysis/identifier.zig");

/// A field's stages, composed at compile time by its `Analysis`.
pub const Pipeline = @import("analysis/Pipeline.zig");
