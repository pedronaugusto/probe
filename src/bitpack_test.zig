//! Blocks packed and unpacked: any block at any width it fits comes back
//! whole, the layout is SIMD-BP128's to the byte, any bytes read as a block
//! stay within their width, and doc ids come back from their gaps.
const std = @import("std");
const shakedown = @import("shakedown");
const bitpack = @import("probe.zig").bitpack;

const testing = std.testing;
const gen = shakedown.gen;
const block_len = bitpack.block_len;

/// A block whose largest integer needs about `width` bits: most draws
/// small, so narrow widths are met as often as wide ones.
fn drawBlock(s: *shakedown.Source, block: *[block_len]u32) void {
    const width = gen.intRange(s, u6, 0, 32);
    const top: u32 = if (width == 32) std.math.maxInt(u32) else (@as(u32, 1) << @intCast(width)) - 1;
    for (block) |*v| v.* = gen.intRange(s, u32, 0, top);
}

fn roundTrip(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var block: [block_len]u32 = undefined;
    drawBlock(s, &block);
    const least = bitpack.bitsFor(&block);
    // The fewest bits hold every integer, and one fewer would not.
    for (block) |v| try testing.expect(least == 32 or v < @as(u64, 1) << least);
    if (least > 0) try testing.expect(std.mem.max(u32, &block) >= @as(u64, 1) << (least - 1));
    const bits: bitpack.Bits = gen.intRange(s, bitpack.Bits, least, bitpack.max_bits);
    var out: [bitpack.max_block_bytes]u8 = @splat(0xAA);
    bitpack.pack(&block, bits, &out);
    // Nothing past the block's bytes is written.
    for (out[bitpack.packedBytes(bits)..]) |byte| try testing.expectEqual(@as(u8, 0xAA), byte);
    var back: [block_len]u32 = undefined;
    bitpack.unpack(out[0..bitpack.packedBytes(bits)], bits, &back);
    try testing.expectEqualSlices(u32, &block, &back);
}

test "any block packed to any width it fits unpacks to itself, in exactly bits * 16 bytes" {
    try shakedown.check(testing.allocator, {}, roundTrip, .{ .seed = 0x62697470, .cases = 4000 });
}

test "a block packed to 32 bits is its integers in order, little endian" {
    var block: [block_len]u32 = undefined;
    for (&block, 0..) |*v, i| v.* = @as(u32, @intCast(i)) *% 0x9E3779B9;
    var out: [bitpack.max_block_bytes]u8 = undefined;
    bitpack.pack(&block, 32, &out);
    for (block, 0..) |v, i| try testing.expectEqual(v, std.mem.readInt(u32, out[i * 4 ..][0..4], .little));
}

test "a block packed to one bit puts integer i in lane i % 4, each lane's bits lowest first" {
    var block: [block_len]u32 = @splat(0);
    // Lane 0's first integer and lane 1's last (block[1 + 4 * 31]).
    block[0] = 1;
    block[125] = 1;
    var out: [bitpack.max_block_bytes]u8 = undefined;
    bitpack.pack(&block, 1, &out);
    // One word a lane: lane 0's has bit 0, lane 1's bit 31.
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[0..4], .little));
    try testing.expectEqual(@as(u32, 1 << 31), std.mem.readInt(u32, out[4..8], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out[8..12], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out[12..16], .little));
}

test "a block of zeros packs to no bytes and unpacks from none" {
    const block: [block_len]u32 = @splat(0);
    try testing.expectEqual(@as(bitpack.Bits, 0), bitpack.bitsFor(&block));
    var back: [block_len]u32 = @splat(7);
    bitpack.unpack(&.{}, 0, &back);
    try testing.expectEqualSlices(u32, &block, &back);
}

fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const bits = gen.intRange(s, bitpack.Bits, 0, bitpack.max_bits);
    var bytes: [bitpack.max_block_bytes]u8 = undefined;
    for (bytes[0..bitpack.packedBytes(bits)]) |*b| b.* = gen.int(s, u8);
    var block: [block_len]u32 = undefined;
    bitpack.unpack(bytes[0..bitpack.packedBytes(bits)], bits, &block);
    try testing.expect(bitpack.bitsFor(&block) <= bits);
    // And packing what came out gives the bytes back.
    var again: [bitpack.max_block_bytes]u8 = undefined;
    bitpack.pack(&block, bits, &again);
    try testing.expectEqualSlices(u8, bytes[0..bitpack.packedBytes(bits)], again[0..bitpack.packedBytes(bits)]);
}

test "fuzz: any bytes unpack to a block within their width, which packs back to them" {
    try shakedown.check(testing.allocator, {}, anyBytes, .{ .seed = 0x66757a7a, .cases = 4000 });
}

fn gapsBack(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const n = gen.intRange(s, usize, 0, block_len);
    const after: ?u32 = if (gen.boolean(s)) gen.intRange(s, u32, 0, 1 << 20) else null;
    var docs: [block_len]u32 = undefined;
    var next: u64 = if (after) |a| @as(u64, a) + 1 else 0;
    var len: usize = 0;
    // Rising strictly: small steps mostly, a large one now and then.
    while (len < n) : (len += 1) {
        next += if (gen.intRange(s, u8, 0, 9) == 0) gen.intRange(s, u32, 0, 1 << 24) else gen.intRange(s, u32, 0, 3);
        if (next > std.math.maxInt(u32)) break;
        docs[len] = @intCast(next);
        next += 1;
    }
    var stored: [block_len]u32 = undefined;
    bitpack.gaps(docs[0..len], after, stored[0..len]);
    var back: [block_len]u32 = undefined;
    try bitpack.ungap(stored[0..len], after, back[0..len]);
    try testing.expectEqualSlices(u32, docs[0..len], back[0..len]);
}

test "doc ids come back from their gaps" {
    try shakedown.check(testing.allocator, {}, gapsBack, .{ .seed = 0x67617073, .cases = 2000 });
}

test "consecutive doc ids are gaps of zero, which pack to no bits" {
    var docs: [block_len]u32 = undefined;
    for (&docs, 0..) |*d, i| d.* = @intCast(1000 + i);
    var stored: [block_len]u32 = undefined;
    bitpack.gaps(&docs, 999, &stored);
    try testing.expectEqual(@as(bitpack.Bits, 0), bitpack.bitsFor(&stored));
}

test "gaps that pass the largest doc id are refused" {
    var out: [2]u32 = undefined;
    try testing.expectError(error.Overflow, bitpack.ungap(&.{ 5, std.math.maxInt(u32) }, null, &out));
    try testing.expectError(error.Overflow, bitpack.ungap(&.{std.math.maxInt(u32) - 1}, std.math.maxInt(u32) - 1, out[0..1]));
}
