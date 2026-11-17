//! BM25, as Lucene computes it (without the constant `k1 + 1` factor,
//! which orders nothing), from the statistics of a whole snapshot:
//!
//!     idf    = ln(1 + (N - df + 0.5) / (df + 0.5))
//!     score  = idf * freq / (freq + k1 * (1 - b + b * length / average))
//!
//! N is the snapshot's documents and df a term's documents in it, both
//! counting a deleted document until a merge drops it (Lucene's), so both
//! are read from the segments' dictionaries and lengths, exactly, without
//! a pass over the deletions; `average` is the field's total length over N.
//! A keyword field's every document is one term long.
//!
//! A score is an `f32` computed in a fixed order, so the same query on the
//! same snapshot gives the same bits on every target: `idf` and `average`
//! are computed once per query in `f64` from IEEE basic operations alone
//! (`ln` below, not the platform's `log`, whose last bit differs between C
//! libraries) and rounded to `f32`; each document's score is then the
//! expression above in `f32`, in the order written.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const Schema = @import("Schema.zig");

/// A field's BM25 parameters, as its declaration sets them.
pub const Params = Schema.Bm25;

/// ln 2 in two parts: the high one's last 21 bits zero, so its product
/// with any exponent here is exact (fdlibm's split).
const ln2_hi: f64 = 6.93147180369123816490e-01;
const ln2_lo: f64 = 1.90821492927058770002e-10;

/// The natural logarithm of `x`, positive and finite, from additions,
/// multiplications and divisions alone, so its bits are the same on every
/// target. `x` is `(1 + f) * 2^e` with `1 + f` in [sqrt(1/2), sqrt(2)), `f`
/// exact; `ln(1 + f) = 2 atanh(s)` for `s = f / (2 + f)`, `|s| < 0.172`,
/// whose series is `2s + 2sT` with `T = s^2/3 + s^4/5 + ... + s^22/23`
/// (a next term is below `2^-56` of the sum). Since `2s = f - s f`, it is
/// `f - s (f - 2T)`: `f` exact and the rounding only in a correction a
/// fraction of it, so the result is within two units in the last place of
/// the true logarithm (`bm25_test.zig`).
pub fn ln(x: f64) f64 {
    aegis.assert.invariant(x > 0 and std.math.isFinite(x), "a logarithm of a positive finite number");
    const parts = std.math.frexp(x);
    var m = parts.significand;
    var e: f64 = @floatFromInt(parts.exponent);
    if (m < std.math.sqrt1_2) {
        m *= 2;
        e -= 1;
    }
    const f = m - 1;
    const s = f / (2 + f);
    const s2 = s * s;
    // Horner from the highest term: s2 (1/3 + s2 (1/5 + ... + s2/23)).
    var t: f64 = 1.0 / 23.0;
    var k: f64 = 21;
    while (k >= 3) : (k -= 2) t = 1 / k + s2 * t;
    t *= s2;
    return e * ln2_hi + (f + (e * ln2_lo - s * (f - 2 * t)));
}

/// A term's idf in a snapshot of `docs` documents, `df` of which hold it.
pub fn idf(docs: u64, df: u64) f32 {
    aegis.assert.invariant(df <= docs, "a term's documents are the snapshot's");
    const n: f64 = @floatFromInt(docs);
    const d: f64 = @floatFromInt(df);
    return @floatCast(ln(1 + (n - d + 0.5) / (d + 0.5)));
}

/// A field's average length in a snapshot of `docs` documents whose
/// lengths there sum to `total`; 1 for an empty snapshot.
pub fn average(docs: u64, total: u64) f32 {
    if (docs == 0) return 1;
    const t: f64 = @floatFromInt(total);
    const n: f64 = @floatFromInt(docs);
    return @floatCast(t / n);
}

/// What scores a term, or a phrase, in each document: its idf, its field's
/// parameters and average length, all of the snapshot.
pub const Weight = struct {
    idf: f32,
    params: Params,
    average: f32,

    /// The score of a document holding the term `freq` times, `length`
    /// terms long in the field.
    pub fn score(w: Weight, freq: f32, length: u32) f32 {
        const l: f32 = @floatFromInt(length);
        const norm = w.params.k1 * ((1 - w.params.b) + w.params.b * (l / w.average));
        return w.idf * (freq / (freq + norm));
    }
};
