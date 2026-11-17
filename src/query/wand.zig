//! Upper bounds on scores, for block-max WAND: what a clause may score in a
//! block of postings, or anywhere, never below the `f32` score the search
//! computes for any document there.
//!
//! A block's bound comes from its impacts with the snapshot's statistics:
//! BM25 rises with a term's frequency and falls with the document's length,
//! so its maximum over the block's competitive (frequency, length) pairs
//! bounds every document of the block (`postings.zig` keeps them, or past
//! eight one pair of the highest frequency and the shortest length, a
//! looser bound). A clause's bound anywhere is its idf: `f / (f + norm)` is
//! at most 1. A constant scorer's is 1.
//!
//! The bounds are computed in `f64` from the same `f32` idf, parameters and
//! average the score uses, then raised past the rounding the score's `f32`
//! arithmetic can add: each basic operation rounds by at most `u = 2^-24`
//! of its result, so a leaf's nine roundings (the length's conversion past
//! `2^24` among them) stay within `16u` of the true value, a sum of `n`
//! within `(n + 1)u` of the true sum, and a boost's product within `2u`. Raising each level by its own factor keeps the
//! bound above the computed score however deep the tree, so a document the
//! bounds rule out could not have entered the top hits: WAND is an
//! optimization, never an approximation.
//!
//! This file is internal. `probe.zig` is the package.
const bm25 = @import("../bm25.zig");

/// The rounding unit of `f32`.
const unit: f64 = 0x1p-24;

/// A leaf's bound raised past its `f32` rounding.
pub fn leaf(value: f64) f64 {
    return value * (1 + 16 * unit);
}

/// A sum of `n` bounds raised past the rounding of an `f32` sum of `n`.
pub fn sum(value: f64, n: usize) f64 {
    return value * (1 + @as(f64, @floatFromInt(n + 1)) * unit);
}

/// A boost's bound: its child's times `by`, raised past one rounding.
pub fn boost(child: f64, by: f32) f64 {
    return child * by * (1 + 2 * unit);
}

/// The most `w` scores a document holding the term `freq` times, `length`
/// terms long, as a true value from its `f32` inputs (not yet raised).
pub fn score(w: bm25.Weight, freq: u32, length: u32) f64 {
    const f: f64 = @floatFromInt(freq);
    const l: f64 = @floatFromInt(length);
    const k1: f64 = w.params.k1;
    const b: f64 = w.params.b;
    const average: f64 = w.average;
    const idf: f64 = w.idf;
    return idf * (f / (f + k1 * ((1 - b) + b * (l / average))));
}

/// The bound of a block whose impacts are `impacts`, raised.
pub fn block(w: bm25.Weight, impacts: anytype) f64 {
    var most: f64 = 0;
    for (impacts) |i| most = @max(most, score(w, i.freq, i.length));
    return leaf(most);
}

/// The bound of a clause scored by `w` anywhere, raised: its idf.
pub fn anywhere(w: bm25.Weight) f64 {
    return leaf(w.idf);
}
