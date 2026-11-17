# probe

probe is a full-text search library for Zig: an inverted index of immutable segments with
BM25 ranking; term, phrase and prefix queries; adds and deletes that a refresh makes
visible; and merges that run when the program asks for them. xenoglyph splits text into
words, and every file is written and committed through airlock, so a crash leaves the
last commit readable.

## Status

In development, and not yet released. What is built so far is the encoding layer: doc ids
as gaps, packed in blocks of 128 integers to the fewest bits that hold the block, in the
SIMD-BP128 layout, the same bytes on every target.

## Testing

Development runs through [bay](https://github.com/pedronaugusto/bay). `bay test` runs the
suite; its properties, run by [shakedown](https://github.com/pedronaugusto/shakedown),
pack and unpack any block at every width and read any bytes as a block within its bounds.

## Licence

MIT. See [LICENSE](LICENSE).
