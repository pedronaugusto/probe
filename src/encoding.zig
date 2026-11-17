//! The encoding layer: how integers, terms and sets lie in a segment's
//! files. Each part is its own file under `encoding/`.
//!
//! This file is internal. `probe.zig` is the package.

/// Integers in blocks of 128 packed to the fewest bits (SIMD-BP128's
/// layout), and doc ids as gaps.
pub const bitpack = @import("encoding/bitpack.zig");

/// A finite state transducer from byte strings to `u64`s.
pub const fst = @import("encoding/fst.zig");

/// A set of a segment's doc ids, one bit each.
pub const bitmap = @import("encoding/bitmap.zig");
