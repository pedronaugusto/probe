//! Integers in blocks of 128, each block packed to the fewest bits that
//! hold its largest, laid out as SIMD-BP128 lays them (Lemire and Boytsov,
//! "Decoding billions of integers per second through vectorization", 2015):
//! four lanes, integer `i` in lane `i % 4`; each lane's 32 integers packed
//! one after another into `bits` 32-bit words, lowest bits first; and word
//! `k` of the four lanes side by side, little endian. A block packed to
//! `bits` takes `bits * 16` bytes.
//!
//! The four lanes are one `@Vector(4, u32)`: a target with 128-bit vectors
//! does them at once, any other one after another, and every target writes
//! and reads the same bytes.
//!
//! A postings list stores its doc ids as gaps (`gaps`, `ungap`), each less
//! one, so a run of consecutive ids packs to no bits at all.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");

/// How many integers a block holds.
pub const block_len = 128;

/// The widest a block packs to.
pub const max_bits = 32;

/// A block's width: 0 to `max_bits`.
pub const Bits = std.math.IntFittingRange(0, max_bits);

/// The most bytes a block takes.
pub const max_block_bytes = max_bits * 16;

const lanes = 4;
const per_lane = block_len / lanes;
const Lane = @Vector(lanes, u32);
const Wide = @Vector(lanes, u64);

/// The bytes a block of width `bits` takes.
pub fn packedBytes(bits: Bits) usize {
    return @as(usize, bits) * 16;
}

/// The fewest bits that hold every integer of `block`: 0 for a block of
/// zeros.
pub fn bitsFor(block: *const [block_len]u32) Bits {
    var all: Lane = @splat(0);
    for (0..per_lane) |j| all |= laneAt(block, j);
    const any = @reduce(.Or, all);
    return @intCast(32 - @clz(any));
}

/// The lanes' `j`th integers: `block[4j]` to `block[4j + 3]`.
fn laneAt(block: *const [block_len]u32, j: usize) Lane {
    return block[j * lanes ..][0..lanes].*;
}

/// `block` packed to `bits` into the first `packedBytes(bits)` bytes of
/// `out`. Every integer of the block fits in `bits`.
pub fn pack(block: *const [block_len]u32, bits: Bits, out: *[max_block_bytes]u8) void {
    aegis.assert.invariant(bitsFor(block) <= bits, "a block is packed to at least the bits its largest integer needs");
    if (bits == 0) return;
    var acc: Wide = @splat(0);
    var held: u7 = 0;
    var word: usize = 0;
    for (0..per_lane) |j| {
        acc |= @as(Wide, laneAt(block, j)) << @splat(@as(u6, @intCast(held)));
        held += bits;
        if (held >= 32) {
            storeWord(out, word, @truncate(acc));
            word += 1;
            acc >>= @splat(32);
            held -= 32;
        }
    }
    aegis.assert.invariant(word == bits and held == 0, "a lane's 32 integers of `bits` each fill exactly `bits` words");
}

/// The block `bytes` holds, packed to `bits`: `bytes` is exactly
/// `packedBytes(bits)` long. Any bytes are some block, each integer less
/// than `2^bits`.
pub fn unpack(bytes: []const u8, bits: Bits, out: *[block_len]u32) void {
    aegis.assert.invariant(bytes.len == packedBytes(bits), "a packed block is `bits * 16` bytes");
    if (bits == 0) {
        out.* = @splat(0);
        return;
    }
    const mask: Wide = @splat((@as(u64, 1) << bits) - 1);
    var acc: Wide = @splat(0);
    var held: u7 = 0;
    var word: usize = 0;
    for (0..per_lane) |j| {
        if (held < bits) {
            acc |= @as(Wide, loadWord(bytes, word)) << @splat(@as(u6, @intCast(held)));
            word += 1;
            held += 32;
        }
        out[j * lanes ..][0..lanes].* = @as(Lane, @truncate(acc & mask));
        acc >>= @splat(bits);
        held -= bits;
    }
}

/// Word `k` of the four lanes into `out`, little endian.
fn storeWord(out: *[max_block_bytes]u8, k: usize, word: Lane) void {
    inline for (0..lanes) |l| std.mem.writeInt(u32, out[(k * lanes + l) * 4 ..][0..4], word[l], .little);
}

/// Word `k` of the four lanes from `bytes`.
fn loadWord(bytes: []const u8, k: usize) Lane {
    var word: Lane = undefined;
    inline for (0..lanes) |l| word[l] = std.mem.readInt(u32, bytes[(k * lanes + l) * 4 ..][0..4], .little);
    return word;
}

/// The gaps of `docs` into `out` (as long): each doc's distance from the
/// one before it, less one, the first's from `after` (less one), or the
/// first itself when nothing comes before it. `docs` rise strictly, the
/// first past `after`.
pub fn gaps(docs: []const u32, after: ?u32, out: []u32) void {
    aegis.assert.invariant(out.len == docs.len and docs.len <= block_len, "the gaps of at most a block, one each");
    var before = after;
    for (docs, out) |doc, *gap| {
        if (before) |b| {
            aegis.assert.invariant(doc > b, "doc ids rise strictly");
            gap.* = doc - b - 1;
        } else gap.* = doc;
        before = doc;
    }
}

/// The doc ids `stored` gaps give after `after` (`gaps`' inverse), or
/// `error.Overflow` when they pass the largest doc id: gaps read from a file
/// are the file's to say.
pub fn ungap(stored: []const u32, after: ?u32, out: []u32) error{Overflow}!void {
    aegis.assert.invariant(out.len == stored.len and stored.len <= block_len, "the doc ids of at most a block, one each");
    var before = after;
    for (stored, out) |gap, *doc| {
        doc.* = if (before) |b| try std.math.add(u32, b, try std.math.add(u32, gap, 1)) else gap;
        before = doc.*;
    }
}
