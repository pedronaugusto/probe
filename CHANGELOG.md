# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Schema.Of(Doc)`: a document type's fields as probe indexes them, read at compile time from its `pub const probe = .{ .id = ..., .fields = .{ ... } }`: each field `.text` (with `positions`, `offsets` and `analysis`), `.keyword` or `.numeric` (a `u64`, an `i64` or an aegis scalar of either), any of them `stored`; a declaration that cannot work does not compile, and says why. `Schema.columnValue` gives a numeric value as its column's `u64`, in order. `DocId` (a document's place in its segment, an aegis index), `Id(Doc)` (the program's id for a document, an aegis id of `u64`) and `Limits` (document bytes, term bytes, prefix expansions, query clauses and depth).

- `bitpack`: integers in blocks of 128 packed to the fewest bits that hold the block's largest (`bitsFor`, `pack`, `unpack`, `packedBytes`), in SIMD-BP128's layout of four interleaved lanes, little endian, so every target writes and reads the same bytes; and doc ids as gaps less one (`gaps`, `ungap`), `ungap` refusing gaps that pass the largest doc id with `error.Overflow`.
- `fst`: a minimal finite state transducer from byte strings to `u64`s, built from keys in strictly rising order (`Builder.add`, `error.NotRising` otherwise; `Builder.finish`), each node written once and shared by every key it serves; read with `Fst.parse`, `Fst.get` and `Fst.walk`, which gives the keys with a prefix in order, iteratively, within the caller's key buffer (`error.KeyTooLong` past it). Every node leads only to nodes written before it, so a walk over any bytes ends, and bytes that break a rule are `error.Corrupt`.
- Analysis of a text field (internal; the index reaches it): its words by UAX #29, the segments that hold a letter, a digit or a connector, each indexed as its NFKC_Casefold (xenoglyph); with `.words_and_identifiers`, an identifier also as its parts, cut at what lies between letters and digits and where the case turns (`parseSpan`, `max_record_bytes`, `std.mem.eql`, `HTTPServer`), at consecutive positions from its own, so a phrase of the parts finds it. A term longer than `Limits.term_bytes` is cut on a code point. The stages a field's `Analysis` names are composed at compile time. Depends on xenoglyph.
- `bitmap`: a set of a segment's doc ids, one bit each, as a deletion generation keeps them (`Bitmap` to write, started empty or from the generation before; `View.parse` to read, refusing bytes of another length or with a bit set past the segment's last doc).
