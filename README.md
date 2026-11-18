# probe

probe is a full-text search library for Zig: an inverted index of immutable segments with
BM25 ranking; term, phrase and prefix queries; adds and deletes that a refresh makes
visible; and merges that run when the program asks for them. xenoglyph splits text into
words, and every file is written and committed through airlock, so a crash leaves the
last commit readable.

## Status

In development, and not yet released. [The design](docs/design.md) says how it is built. A
document type declares how its fields are indexed, and `Index(Doc)` writes, commits, merges
and searches it:

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const probe = @import("probe");

const Entry = struct {
    seq: u64,
    level: []const u8,
    message: []const u8,
    pub const probe = .{
        .id = .seq,
        .fields = .{
            .level = .{ .keyword = .{ .stored = true } },
            .message = .{ .text = .{ .positions = true, .analysis = .words_and_identifiers } },
        },
    };
};
const Index = probe.Index(Entry);

const w = try Index.openWriter(gpa, io, dir, .{});
defer w.deinit(io);
try w.add(io, .{ .seq = 1, .level = "ERR", .message = "segment merge failed in parseSpan" });
try w.add(io, .{ .seq = 2, .level = "INFO", .message = "segment merged" });
var done = try w.commit(io);
var generation: u64 = undefined;
done.take(&generation);

const r = try Index.openReader(gpa, io, dir, .{});
defer r.deinit();
// An identifier's parts find it, as a phrase of words does.
var q = try Index.Query.parse(gpa, .init("level:ERR \"parse span\""), .{});
defer q.deinit();
var hits = try r.search(io, &q, .{});
defer hits.deinit();
std.debug.assert(hits.hits.len == 1);
std.debug.assert(hits.hits[0].id.raw() == 1);
// The stored fields come back typed.
var arena: std.heap.ArenaAllocator = .init(gpa);
defer arena.deinit();
const stored = try r.stored(io, hits.hits[0], arena.allocator());
std.debug.assert(std.mem.eql(u8, stored.level, "ERR"));
```
<!-- END GENERATED -->

Built so far: the analysis of text into terms, the segment files, the writer with its commits
and tiered merges, snapshots, queries (terms, phrases with slop, prefixes, numeric ranges, and,
or, not and boosts, from the query language or built in code) ranked by BM25 with block-max
WAND, sorting by a numeric field, paging by cursor, and stored fields read back typed.

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
give every query the same best hits, bit for bit, as an exact reference that scores
each document by the definition, and run queries over segments with damaged bytes, each
answering within the segment or refusing it as corrupt. In every order within two
preemptions, a snapshot searched while the writer commits and merges answers as it did
before the writer began.

## Licence

MIT. See [LICENSE](LICENSE).
