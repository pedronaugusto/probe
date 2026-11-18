//! probe: full-text search. An inverted index of immutable segments with
//! BM25 ranking, built in layers; this is the package's root, and it names
//! what is public.
//!
//! `Index(Doc)` is the index of a document type: its writer, its snapshots
//! and its queries.
const encoding = @import("encoding.zig");
const ids = @import("ids.zig");
const index = @import("index.zig");
const query = @import("query.zig");

/// The index of a document type: `Index(Doc).openWriter`, `.openReader`,
/// `.Query`.
pub const Index = index.Index;

/// Why an index did not open, and on which file.
pub const OpenDiagnostic = index.OpenDiagnostic;

/// Which segment of which snapshot a hit is of.
pub const SegmentRef = index.SegmentRef;

/// How many documents a search matched: exactly, or at least.
pub const Total = index.Total;

/// A merge done.
pub const MergeReport = index.MergeReport;

/// Where and why a query does not read.
pub const QueryDiagnostic = query.parse.Diagnostic;

/// Why a query does not read.
pub const QueryProblem = query.parse.Problem;

/// Which segments a merge takes: Lucene's tiered policy.
pub const MergePolicy = @import("merge.zig").Policy;

pub const OpenError = index.OpenError;
pub const AddError = index.AddError;
pub const FlushError = index.FlushError;
pub const CommitError = index.CommitError;
pub const MergeError = index.MergeError;
pub const QueryParseError = index.QueryParseError;
pub const SearchError = index.SearchError;
pub const StoredError = index.StoredError;

/// A document's place in its segment.
pub const DocId = ids.DocId;

/// The id the program gives each document of type `Doc`.
pub const Id = ids.Id;

/// The bounds on documents, terms and queries.
pub const Limits = @import("Limits.zig");

/// A document type's fields as probe indexes them, from its `pub const
/// probe` declaration.
pub const Schema = @import("Schema.zig");

/// Integers in blocks of 128 packed to the fewest bits (SIMD-BP128's
/// layout), and doc ids as gaps.
pub const bitpack = encoding.bitpack;

/// A finite state transducer from byte strings to `u64`s, minimal and
/// built from keys in rising order: the term dictionary's and the external
/// ids' map.
pub const fst = encoding.fst;

/// A set of a segment's doc ids, one bit each: a deletion generation.
pub const bitmap = encoding.bitmap;
