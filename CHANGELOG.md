# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `bitpack`: integers in blocks of 128 packed to the fewest bits that hold the block's largest (`bitsFor`, `pack`, `unpack`, `packedBytes`), in SIMD-BP128's layout of four interleaved lanes, little endian, so every target writes and reads the same bytes; and doc ids as gaps less one (`gaps`, `ungap`), `ungap` refusing gaps that pass the largest doc id with `error.Overflow`.
