# probe

probe is a full-text search library for Zig: an inverted index of immutable segments with
BM25 ranking; term, phrase and prefix queries; adds and deletes that a refresh makes
visible; and merges that run when the program asks for them. xenoglyph splits text into
words, and every file is written and committed through airlock, so a crash leaves the
last commit readable.

## Status

In development, and not yet released. What is built so far: the schema a document type
declares, the analysis of text into terms, the segment files, the writer with its commits
and tiered merges, snapshots, and queries run over a snapshot (terms, phrases with slop,
prefixes, numeric ranges, and, or, not and boosts). The query parser and the public `Index`
type come next.

## Scoring

Hits are ranked by BM25 as Lucene computes it, with `k1` and `b` set per text field in its
declaration (`.bm25 = .{ .k1 = 1.2, .b = 0.75 }` by default). These are read when a query is
scored and never stored, so changing them changes scores and nothing else. The statistics
are those of the whole snapshot, and as in Lucene a deleted document counts in them until a
merge drops it, so a score can move after a merge although no document changed. Prefixes,
numeric ranges and a match of every document score a constant 1, and a phrase scores by how many
times it occurs, a looser occurrence counting less. A score is an `f32` computed in a fixed
order from statistics rounded the same way on every target, so the same query on the same
snapshot ranks the same hits with the same scores everywhere; equal scores are ordered by
the hit's place in the snapshot.

## Testing

Development runs through [bay](https://github.com/pedronaugusto/bay). `bay test` runs the
suite; its properties, run by [shakedown](https://github.com/pedronaugusto/shakedown),
pack and unpack any block at every width and read any bytes as a block within its bounds,
and give every query the same best hits, bit for bit, as an exact reference that scores
each document by the definition.

## Licence

MIT. See [LICENSE](LICENSE).
