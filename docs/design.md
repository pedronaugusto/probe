# Design

probe is full-text search for Zig: documents of a schema declared on a Zig type, an index of immutable
segments on disk, BM25 ranking with block-max WAND, and a query language for people beside the same
tree built in code. This describes the implementation in this repository; change it with the code.

## Scope

In:

- Text fields (analyzed, with positions and optionally byte offsets), keyword fields (exact terms),
  numeric fields (`u64`, `i64`, aegis instants: columns for range filters and sorting), an external id
  per document, optional stored fields.
- Analysis on xenoglyph: UAX #29 words, NFKC_Casefold, and an identifier stage for code and logs
  (`parseSpan` is `parse` and `span`, and also `parseSpan` whole). An identifier's parts take consecutive
  positions from the word's own, the whole word shares its first part's, and the next word follows the
  last part. A query's text goes through the same analysis, so `parse span` and `parseSpan` both find
  `parseSpan`.
- Queries: terms, phrases with slop, prefixes, `and`, `or`, `not`, field scoping, numeric ranges, `all`,
  boosts.
- Ranking: BM25 with `k1` and `b` per field, top-k by block-max WAND (disjunctions) and block-max
  conjunction, counting, sorting by a numeric field.
- Updates: add, delete by external id, update; `refresh` for visibility in this process, `commit` for
  durability; merges under a tiered policy, run by the program.

Out, by decision:

- Stemming and stop words: language-specific morphology; prefixes cover inflection for the consumers
  so far. An analysis stage when a consumer asks.
- Dictionary segmentation (Thai, Lao, Khmer, Myanmar, Chinese, Japanese): such text is indexed by UAX
  #29 words, code points for ideographs, and a query still finds it as a phrase.
- Fuzzy and regex queries: an automaton walked over the term dictionary, when a consumer asks.
- Highlighting, facets, aggregations, vectors, distribution.

## Index layout

**Segments.** An index is a directory of immutable segments and a manifest naming the live ones. A
writer buffers documents in memory and flushes them as a new segment; a delete marks a document in a
per-segment deletion bitmap, written as a new generation; a commit writes the new files, syncs them,
then replaces the manifest atomically (airlock). A reader opens one manifest and sees that snapshot
until it reopens. A merge writes a new segment from several and commits a manifest that swaps them.

**A segment is one file**, `<segment>.seg`, written once in one pass: a header with its format version,
its sections in a fixed order, then a table of each section's offset, length and CRC-32C, and a footer
holding the table's CRC-32C. One writer writes every segment, a flush's and a merge's. A deletion
generation is a file of its own, `<segment>.del.<gen>` (header, bitmap, CRC-32C), since it changes while
its segment does not. Segment numbers are never reused.

| Section | Holds |
|---|---|
| postings | per term, its doc ids in blocks of 128, delta-coded and bit-packed as SIMD-BP128 lays them (four lanes, one `@Vector(4, u32)`: a target with 128-bit vectors does them at once, and every target writes the same bytes), a skip entry per block with its last doc id and its impacts: the competitive (term frequency, length) pairs, or past 8 of them the block's largest frequency and smallest length; then the term's positions (and offsets) per document |
| store | stored fields in 16 KiB blocks compressed with warp's LZ4, then the blocks' table with a CRC-32C of its own |
| terms | per field, an FST from term bytes to the term's postings address and document frequency |
| lengths | each document's length per text field (`u32`) and the field totals |
| columns | numeric columns, bit-packed per block with each block's min and max |
| ids | external ids to doc ids (an FST), each re-added document paired with the one it replaced |

The manifest is JSON through strand, a few lines readable by hand. It records the schema (fields,
kinds, a numeric field's sign, the term length), so an index written with other fields is
`SchemaMismatch`, a healthy index refused, with a diagnostic naming the first difference. A text
field's `k1` and `b` are read when a query is scored, never stored, so changing them never refuses an
index.

**The writer lock** is std's advisory lock on a lock file in the index directory (`flock` on POSIX,
`LockFileEx` on Windows): the kernel releases it when the process dies, so a crashed writer never leaves
the index locked, and a second writer gets `Locked` at once. A writer's open removes the temporary files
a dead writer left.

**Readers in this process and in others.** A reader opens every file its manifest names before it
answers anything and holds those handles until it closes, so an open snapshot never loses a file. The
writer deletes a file only when none of the last `keep_commits` commits (2 by default) names it; a reader
that still finds a file gone opens the newest manifest instead, up to `retries` times (`Busy` past
them). In one process the writer and its readers hold the same segments through `aegis.Shared`. On
Windows every open shares delete and the writer deletes with POSIX semantics, so a name goes at once
while open handles stay valid; on a volume without them the name stays until the last handle closes,
which is harmless since names are never reused.

## Queries

A query tree compiles to iterators over postings with `advance(target)`, passing blocks by their skip
entries. Conjunctions lead with the rarest term, a `not` checked last; phrases intersect, then check
positions; prefixes expand through each segment's FST up to `Limits.expansions` terms (more is
`TooManyTerms`, before any postings are read); numeric ranges skip column blocks by their min and max.
Deleted documents are dropped as hits are collected.

**Regex terms.** A `/pattern/` walks each segment's FST with spectra's stepping automaton: a branch whose
state is dead is passed over, and a term is taken where the state at its end is a match, up to
`Limits.expansions` terms like a prefix. When the automaton's store gives up, the walk prunes nothing
more and takes each term by a whole-term search, so the terms are always those the pattern matches
whole. On a text field the pattern's literals are folded as the field folds its terms (NFKC_Casefold,
which spectra's case-insensitive mode alone does not give: `ß` and `ss`, ligatures, fullwidth forms) and
it matches case-insensitive; on a keyword field it reads bytes as they are. A pattern is compiled once
per search, and one with a lookaround is refused where the terms can be longer than it can search.

**Scoring** is Lucene's. A term scores BM25 with `idf = ln(1 + (N - df + 0.5) / (df + 0.5))` and
`idf * f / (f + k1 * (1 - b + b * length / average))` (1.2 and 0.75 by default). A phrase matches its
terms in order within `slop` extra positions and scores with its terms' idfs summed and a sloppy
frequency, `1 / (1 + extra)` per match. Prefixes, ranges, `all` and a lone `not` score a constant 1 times
their boost; `and` and `or` sum their matching children. The statistics are the whole snapshot's, read
exactly from the segments, and count deleted documents until a merge drops them, so a merge can move
scores although no live document changed.

**Block-max bounds come from impacts at query time.** A block stores only its competitive pairs; a query
computes each block's bound from them with the snapshot's statistics, so the bound is exact for the
snapshot and WAND is an optimization, never an approximation. Bounds are computed in `f64` and raised
past every rounding the `f32` score can add. The block-max conjunction does the same under `and`: a
window from a document to the least last document of the blocks holding it is passed unscored when its
summed bounds do not beat the worst hit held.

**Scores and ties.** A score is an `f32` computed in a fixed order, so a query on a snapshot gives the
same bits on every target. The logarithm is probe's own, made of IEEE basic operations, since a C
library's `log` differs in its last bit between targets; it is within two units in the last place of the
platform's. Equal scores order by place in the snapshot (segment, then doc id), so a top-k is one
deterministic list and a `Cursor` resumes it exactly.

**Totals and pages.** `count_up_to` (1000) matches are counted exactly, past them the total is
`at_least`. `after` resumes from a `Cursor`; a cursor or hit of another snapshot is `StaleHit`, told by its
`SegmentRef`. `stored` returns `Index(Doc).Stored`, generated from `Doc`'s stored fields alone.

**The query language.** Clauses side by side all match (`AND` says the same), `OR` binds looser, `NOT x`
or `-x` excludes, parentheses group. A word with no field searches the default fields, each through its
own analysis: one term, or when it splits, the phrase of its parts. `field:word`, `field:(...)`,
`"..."~slop`, `word*`, `/pattern/` with `\/` a slash, `field:[a TO b]` with `*` open, `field:5`, `*`, `^boost`, `\` escaping a byte. A
query that does not read fails with a `Problem` at its byte.

## Merges

The policy is Lucene's tiered one. A segment's size is its bytes in proportion to its live documents,
at least `floor_bytes` (2 MiB). Each tier may hold `segments_per_tier` (10) segments, a tier's size the
previous one's times the merge factor, up to `max_merged_bytes` (5 GiB); a segment past half the cap with
few enough deletes counts in no budget. A merge is due when the segments are more than the tiers allow or
their deletes pass `deletes_pct_allowed` (20%). The candidate with the lowest score wins: skew times
merged size to the power 0.05 times the squared ratio of live to total bytes. `mergeStep` makes one
merge a call; the program calls it on its own `Io`, as often as it wants. A merge reads each source in
order where it can, so the sections' CRC-32C ride its reads, and refuses to publish on a mismatch; it
streams the merged segment, holding the largest term's postings and what it builds in memory, never the
whole segment.

## Io, memory, cancellation

Every call that reads or writes takes `io` and is canceled at its reads and writes; a search also checks
for a cancel every 64 postings blocks, and a merge every MiB written. Files are read positionally, never
memory-mapped, so every wait is cancelable. There is no shared block cache: each iterator holds its
current block in a buffer of its own, so concurrent searches share nothing mutable and take no lock. The
sections read whole at open (terms, lengths, ids, columns) have their CRC-32C checked then; postings,
positions and stored blocks are read as needed, with structural checks on every read. One writer per
directory; any number of readers, each a snapshot. Merging is never a thread of probe's.

## Safety

Every file read is untrusted: headers, FST nodes, block lengths, bit widths, doc ids and positions are
checked as they are read, and a length a segment holds is bounded by the bytes after it; a violation is
`Corrupt`, naming the file. The FST walk is iterative. A `Hit` carries its `SegmentRef`, checked before
any read, so a doc id of one segment or snapshot never indexes another's. External ids are
`aegis.id.Id(Doc, u64)`. A document past `Limits.document_bytes` is `FieldTooLong` before analysis. Query
text is untrusted; the parser bounds clauses, depth and prefix expansions. `commit` and `mergeStep`
return `aegis.own.MustUse`.

## Proof

- **Ranking:** an exact BM25 reference in `src/testing/reference.zig` computes the same `f32` expression
  in the same order: every query's top hits (top 1000 among them) equal bit for bit in score and order,
  counts equal, scores within 1e-5 of BM25 in `f64`, over multi-segment snapshots with skewed statistics
  (averages differing tenfold, a term common in one segment and rare in the rest), segments added and
  merged between queries, and reopened snapshots. WAND and the block-max conjunction equal the exhaustive
  top-k bit for bit, pages after any hit too.
- **Crash:** every crash point of three commits, and of two commits and a merge, on shakedown's simulated
  disk with airlock's crash model, and every state the disk could come back in: a writer reopens the
  index, which holds exactly one commit's documents, no older than the last acknowledged, every file it
  names verifying, no temporary file left.
- **Faults:** every single fault (an error, a short write, a cancel) at every call of a commit and a merge,
  each run on a fresh simulation of one seed: the same holds once a writer reopens the index.
- **Concurrency:** searches beside a writer that commits and merges, removing the files the search
  reads, in every order within two preemptions: a snapshot's hits and count never change. Readers in
  other processes are covered by the retention above, not yet by a test with real processes.
- **Damage:** segments damaged many ways and every query run over them answer within the segment or
  `Corrupt`; the query parser reads any bytes as a tree within the limits or fails at a byte inside them,
  and any tree printed reads back as itself; the merge policy keeps segments within the tier budget and
  deletes within the allowance.

## Dependencies

xenoglyph (words, NFKC_Casefold, categories), airlock (atomic files, batches, the directory sync), warp
(CRC-32C, LZ4), strand (the manifest), spectra (regex term queries), aegis. A consumer
fetches those and nothing else: probe has no optional module.
