//! probe: full-text search. An inverted index of immutable segments with
//! BM25 ranking, built in layers; this is the package's root, and it names
//! what is public.
//!
//! In development: the encoding layer is here, the index above it is not.
const encoding = @import("encoding.zig");

/// Integers in blocks of 128 packed to the fewest bits (SIMD-BP128's
/// layout), and doc ids as gaps.
pub const bitpack = encoding.bitpack;

/// A finite state transducer from byte strings to `u64`s, minimal and
/// built from keys in rising order: the term dictionary's and the external
/// ids' map.
pub const fst = encoding.fst;
