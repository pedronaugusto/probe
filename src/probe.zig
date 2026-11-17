//! probe: full-text search. An inverted index of immutable segments with
//! BM25 ranking, built in layers; this is the package's root, and it names
//! what is public.
//!
//! In development: the encoding layer is here, the index above it is not.

/// Integers in blocks of 128 packed to the fewest bits (SIMD-BP128's
/// layout), and doc ids as gaps.
pub const bitpack = @import("encoding/bitpack.zig");
